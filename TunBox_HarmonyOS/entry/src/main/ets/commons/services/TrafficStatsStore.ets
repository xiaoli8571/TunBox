/**
 * 数据页流量统计存储（对齐 ClashPlus 1.2.7 `_LifetimeTraffic` / `DailyTrafficStore`）
 *
 * ## 口径（与 ClashPlus 一致）
 * - **累计（lifetime）**：跨会话累加的上下行总字节，落盘在 SharedPreferences；
 *   每月「清零日」00:00（本地时区）自动归零。
 * - **按日（daily）**：以本地自然日为桶累加，与累计**同源**（同一次增量同时写入两处），
 *   供按月系列图使用。
 * - **本次连接（session）**：进程内计数，断开后不清零（ClashPlus 语义是同一次会话
 *   增量并入累计后仍保留当日会话值；这里在「断开」时把 session 归零由调用方决定，
 *   默认保留到下次连接开始）。
 *
 * ClashPlus 实测口径：`lifetime_traffic_up` / `lifetime_traffic_down`（prefs）、
 * `daily_traffic_by_ymd_v1`（prefs，`{ "YYYY-MM-DD": {u,d} }`）、清零日 `trafficResetDay`（1–28）。
 * 鸿蒙侧以独立 preferences 文件 `tunbox_traffic_stats` 承载，字段名保持同义。
 */
import { preferences } from '@kit.ArkData';
import { AppLogger } from '../utils/AppLogger';
import { UnifiedScheduler } from './UnifiedScheduler';
import { ConnectionOrchestrator } from './ConnectionOrchestrator';

const TAG = 'TrafficStatsStore';
const PREF_NAME = 'tunbox_traffic_stats';

/** 单日桶 */
export class DailyBucket {
  up: number = 0;
  down: number = 0;
}

/** 按日序列中的一项（供图表直接消费） */
export class DailyPoint {
  dayKey: string = '';
  up: number = 0;
  down: number = 0;
}

/** 数据页读取用的快照（一次性取全，避免 UI 侧多次跨模块调用） */
export class TrafficStatsView {
  /** 累计上行字节 */
  lifetimeUp: number = 0;
  /** 累计下行字节 */
  lifetimeDown: number = 0;
  /** 本次会话上行字节 */
  sessionUp: number = 0;
  /** 本次会话下行字节 */
  sessionDown: number = 0;
  /** 本次会话峰值上行（B/s） */
  peakUp: number = 0;
  /** 本次会话峰值下行（B/s） */
  peakDown: number = 0;
  /** 本次会话平均上行（B/s） */
  avgUp: number = 0;
  /** 本次会话平均下行（B/s） */
  avgDown: number = 0;
  /** 每月清零日（1–28） */
  resetDay: number = 1;
  /** 当日（本地自然日）上行 / 下行 */
  todayUp: number = 0;
  todayDown: number = 0;
  /** 当月按日序列（按日期升序，最多 31 项） */
  month: DailyPoint[] = [];
}

/** 每日桶的 JSON 形态（持久化用，键短以省空间） */
class DailyBucketJson {
  u: number = 0;
  d: number = 0;
}

export class TrafficStatsStore {
  private static store: preferences.Preferences | null = null;
  private static inited: boolean = false;

  private static lifetimeUp: number = 0;
  private static lifetimeDown: number = 0;
  private static resetDay: number = 1;
  /** 上次执行清零的月份标记 'YYYY-MM' */
  private static lastResetMonth: string = '';
  /** 按日桶：dayKey('YYYY-MM-DD') → DailyBucket */
  private static daily: Map<string, DailyBucket> = new Map<string, DailyBucket>();

  // 本次会话（进程内，不落盘）
  private static sessionUp: number = 0;
  private static sessionDown: number = 0;
  private static peakUp: number = 0;
  private static peakDown: number = 0;
  private static sessionSamples: number = 0;
  private static sessionUpSum: number = 0;
  private static sessionDownSum: number = 0;

  private static readonly KEY_LIFETIME_UP: string = 'lifetime_traffic_up';
  private static readonly KEY_LIFETIME_DOWN: string = 'lifetime_traffic_down';
  private static readonly KEY_RESET_DAY: string = 'traffic_reset_day';
  private static readonly KEY_LAST_RESET_MONTH: string = 'traffic_last_reset_month';
  private static readonly KEY_DAILY: string = 'daily_traffic_by_ymd_v1';

  // ── 记账调度（App 级，独立于任何页面是否可见）──
  private static accountingToken: number = -1;
  private static lastUpBytes: number = -1;
  private static lastDownBytes: number = -1;

  /**
   * 启动每秒记账。
   *
   * 为什么要独立于页面：ClashPlus 的累计/按日是在控制器层累加的，**不依赖数据页
   * 是否被打开**；本工程页签是懒挂载的（MainPage.visible 懒创建），如果把记账写在
   * StatsPage 的定时器里，用户不进数据页就永远不会计数 —— 累计值会是假的。
   * 因此由 App 侧（HomePage.bootstrap，主页始终挂载）启动一次全局记账 tick。
   */
  static startAccounting(): void {
    if (TrafficStatsStore.accountingToken >= 0) {
      return;
    }
    TrafficStatsStore.accountingToken = UnifiedScheduler.every((): void => {
      TrafficStatsStore.accountingTick();
    }, 1000);
    AppLogger.info(TAG, 'accounting started');
  }

  static stopAccounting(): void {
    if (TrafficStatsStore.accountingToken >= 0) {
      UnifiedScheduler.clear(TrafficStatsStore.accountingToken);
      TrafficStatsStore.accountingToken = -1;
    }
  }

  /** 每秒：把内核累计计数器的增量写进 累计/按日/本次会话，并采样瞬时速率 */
  private static accountingTick(): void {
    const orch: ConnectionOrchestrator = ConnectionOrchestrator.instance();
    const upBytes: number = orch.traffic.uploadBytes;
    const downBytes: number = orch.traffic.downloadBytes;
    if (TrafficStatsStore.lastUpBytes < 0 || upBytes < TrafficStatsStore.lastUpBytes) {
      // 首次采样 / 内核计数器归零（重连）：只重建基线，不产生假增量
      TrafficStatsStore.lastUpBytes = upBytes;
      TrafficStatsStore.lastDownBytes = downBytes;
    } else {
      const dUp: number = upBytes - TrafficStatsStore.lastUpBytes;
      const dDown: number = downBytes - TrafficStatsStore.lastDownBytes;
      TrafficStatsStore.lastUpBytes = upBytes;
      TrafficStatsStore.lastDownBytes = downBytes;
      TrafficStatsStore.addDelta(dUp, dDown);
    }
    TrafficStatsStore.sampleSpeed(orch.traffic.uploadSpeed, orch.traffic.downloadSpeed);
  }

  /** 会话起点清零记账基线（新建隧道时调用，避免跨会话增量被算到新会话） */
  static resetAccountingBaseline(): void {
    TrafficStatsStore.lastUpBytes = -1;
    TrafficStatsStore.lastDownBytes = -1;
  }

  static async init(context: Context): Promise<void> {
    if (TrafficStatsStore.inited) {
      return;
    }
    try {
      TrafficStatsStore.store = await preferences.getPreferences(context, PREF_NAME);
      const p: preferences.Preferences = TrafficStatsStore.store;
      TrafficStatsStore.lifetimeUp = await p.get(TrafficStatsStore.KEY_LIFETIME_UP, 0) as number;
      TrafficStatsStore.lifetimeDown = await p.get(TrafficStatsStore.KEY_LIFETIME_DOWN, 0) as number;
      TrafficStatsStore.resetDay = await p.get(TrafficStatsStore.KEY_RESET_DAY, 1) as number;
      TrafficStatsStore.lastResetMonth =
        await p.get(TrafficStatsStore.KEY_LAST_RESET_MONTH, '') as string;
      const raw: string = await p.get(TrafficStatsStore.KEY_DAILY, '{}') as string;
      TrafficStatsStore.daily = TrafficStatsStore.decodeDaily(raw);
      TrafficStatsStore.inited = true;
      TrafficStatsStore.normalizeResetDay();
      await TrafficStatsStore.applyMonthlyResetIfDue();
      AppLogger.info(TAG, `init lifetime=${TrafficStatsStore.lifetimeUp}/${TrafficStatsStore.lifetimeDown} `
        + `resetDay=${TrafficStatsStore.resetDay} days=${TrafficStatsStore.daily.size}`);
    } catch (e) {
      AppLogger.warn(TAG, `init failed: ${AppLogger.errText(e)}`);
      TrafficStatsStore.inited = true;
    }
  }

  /** 清零日必须落在 1–28（与 ClashPlus 一致：避免不同月份天数差异带来的歧义） */
  private static normalizeResetDay(): void {
    const d: number = Math.floor(TrafficStatsStore.resetDay);
    if (!Number.isFinite(d) || d < 1) {
      TrafficStatsStore.resetDay = 1;
    } else if (d > 28) {
      TrafficStatsStore.resetDay = 28;
    } else {
      TrafficStatsStore.resetDay = d;
    }
  }

  /** 'YYYY-MM-DD' / 'YYYY-MM'（本地时区，与「按本地自然日累加」口径一致） */
  static dayKey(ts: number = Date.now()): string {
    const d: Date = new Date(ts);
    const m: string = `${d.getMonth() + 1}`.padStart(2, '0');
    const day: string = `${d.getDate()}`.padStart(2, '0');
    return `${d.getFullYear()}-${m}-${day}`;
  }

  private static monthKey(ts: number = Date.now()): string {
    return TrafficStatsStore.dayKey(ts).substring(0, 7);
  }

  private static decodeDaily(raw: string): Map<string, DailyBucket> {
    const out: Map<string, DailyBucket> = new Map<string, DailyBucket>();
    if (raw.length === 0) {
      return out;
    }
    try {
      const obj: Record<string, DailyBucketJson> = JSON.parse(raw) as Record<string, DailyBucketJson>;
      const keys: string[] = Object.keys(obj);
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        const v: DailyBucketJson = obj[k];
        if (v === undefined || v === null) {
          continue;
        }
        const bucket: DailyBucket = new DailyBucket();
        bucket.up = typeof v.u === 'number' ? v.u : 0;
        bucket.down = typeof v.d === 'number' ? v.d : 0;
        out.set(k, bucket);
      }
    } catch (e) {
      AppLogger.warn(TAG, `decode daily failed: ${AppLogger.errText(e)}`);
    }
    return out;
  }

  private static encodeDaily(): string {
    const out: Record<string, DailyBucketJson> = {};
    TrafficStatsStore.daily.forEach((v: DailyBucket, k: string): void => {
      const j: DailyBucketJson = new DailyBucketJson();
      j.u = v.up;
      j.d = v.down;
      out[k] = j;
    });
    return JSON.stringify(out);
  }

  /**
   * 每月清零：到「清零日」且本月还没清过，就把累计上下行归零。
   *
   * 判定用「今天 >= 清零日」而不是「等于清零日」：设备可能整月关机，
   * 等到下次打开时已经过了那天，此时必须补清（与 ClashPlus 同一语义）。
   */
  static async applyMonthlyResetIfDue(): Promise<void> {
    TrafficStatsStore.normalizeResetDay();
    const now: Date = new Date();
    const month: string = TrafficStatsStore.monthKey(now.getTime());
    const dayOfMonth: number = now.getDate();
    if (TrafficStatsStore.lastResetMonth === month) {
      return;
    }
    if (dayOfMonth < TrafficStatsStore.resetDay) {
      return;
    }
    const had: number = TrafficStatsStore.lifetimeUp + TrafficStatsStore.lifetimeDown;
    TrafficStatsStore.lifetimeUp = 0;
    TrafficStatsStore.lifetimeDown = 0;
    TrafficStatsStore.lastResetMonth = month;
    await TrafficStatsStore.persist(true);
    AppLogger.info(TAG, `monthly reset applied for ${month} (cleared ${had} bytes)`);
  }

  /** 累加一次增量（字节）。同一次增量同时进「累计」「当日」「本次会话」。 */
  static addDelta(upDelta: number, downDelta: number): void {
    const up: number = Number.isFinite(upDelta) && upDelta > 0 ? Math.floor(upDelta) : 0;
    const down: number = Number.isFinite(downDelta) && downDelta > 0 ? Math.floor(downDelta) : 0;
    if (up === 0 && down === 0) {
      return;
    }
    TrafficStatsStore.lifetimeUp += up;
    TrafficStatsStore.lifetimeDown += down;
    TrafficStatsStore.sessionUp += up;
    TrafficStatsStore.sessionDown += down;
    const key: string = TrafficStatsStore.dayKey();
    let bucket: DailyBucket | undefined = TrafficStatsStore.daily.get(key);
    if (bucket === undefined) {
      bucket = new DailyBucket();
      TrafficStatsStore.daily.set(key, bucket);
    }
    bucket.up += up;
    bucket.down += down;
  }

  /** 记录一次瞬时速率采样（B/s），用于峰值与平均 */
  static sampleSpeed(upBps: number, downBps: number): void {
    const u: number = Number.isFinite(upBps) && upBps > 0 ? upBps : 0;
    const d: number = Number.isFinite(downBps) && downBps > 0 ? downBps : 0;
    if (u > TrafficStatsStore.peakUp) {
      TrafficStatsStore.peakUp = u;
    }
    if (d > TrafficStatsStore.peakDown) {
      TrafficStatsStore.peakDown = d;
    }
    TrafficStatsStore.sessionUpSum += u;
    TrafficStatsStore.sessionDownSum += d;
    TrafficStatsStore.sessionSamples += 1;
  }

  /** 会话复位（每次新建隧道时调用，与 ClashPlus「本次连接」语义一致） */
  static resetSession(): void {
    TrafficStatsStore.sessionUp = 0;
    TrafficStatsStore.sessionDown = 0;
    TrafficStatsStore.peakUp = 0;
    TrafficStatsStore.peakDown = 0;
    TrafficStatsStore.sessionSamples = 0;
    TrafficStatsStore.sessionUpSum = 0;
    TrafficStatsStore.sessionDownSum = 0;
  }

  /** 立即落盘（调用点：每秒记账 tick、清零、切后台） */
  static async persist(force: boolean = false): Promise<void> {
    const p: preferences.Preferences | null = TrafficStatsStore.store;
    if (p === null) {
      return;
    }
    try {
      await p.put(TrafficStatsStore.KEY_LIFETIME_UP, TrafficStatsStore.lifetimeUp);
      await p.put(TrafficStatsStore.KEY_LIFETIME_DOWN, TrafficStatsStore.lifetimeDown);
      await p.put(TrafficStatsStore.KEY_RESET_DAY, TrafficStatsStore.resetDay);
      await p.put(TrafficStatsStore.KEY_LAST_RESET_MONTH, TrafficStatsStore.lastResetMonth);
      await p.put(TrafficStatsStore.KEY_DAILY, TrafficStatsStore.encodeDaily());
      if (force) {
        await p.flush();
        return;
      }
      await p.flush();
    } catch (e) {
      AppLogger.warn(TAG, `persist failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 设置每月清零日（1–28），并立刻按新规则判定是否需要清零 */
  static async setResetDay(day: number): Promise<void> {
    TrafficStatsStore.resetDay = day;
    TrafficStatsStore.normalizeResetDay();
    await TrafficStatsStore.applyMonthlyResetIfDue();
    await TrafficStatsStore.persist(true);
  }

  static resetDayValue(): number {
    return TrafficStatsStore.resetDay;
  }

  /** 当月按日序列（升序），供按月柱状/折线图消费 */
  static monthSeries(ts: number = Date.now()): DailyPoint[] {
    const prefix: string = TrafficStatsStore.monthKey(ts).concat('-');
    const keys: string[] = [];
    TrafficStatsStore.daily.forEach((_v: DailyBucket, k: string): void => {
      if (k.startsWith(prefix)) {
        keys.push(k);
      }
    });
    keys.sort((a: string, b: string): number => a.localeCompare(b));
    const out: DailyPoint[] = [];
    for (let i = 0; i < keys.length; i++) {
      const b: DailyBucket | undefined = TrafficStatsStore.daily.get(keys[i]);
      if (b === undefined) {
        continue;
      }
      const item: DailyPoint = new DailyPoint();
      item.dayKey = keys[i];
      item.up = b.up;
      item.down = b.down;
      out.push(item);
    }
    return out;
  }

  /** 读快照（UI 直接用，纯内存、零 IO） */
  static view(): TrafficStatsView {
    const v: TrafficStatsView = new TrafficStatsView();
    v.lifetimeUp = TrafficStatsStore.lifetimeUp;
    v.lifetimeDown = TrafficStatsStore.lifetimeDown;
    v.sessionUp = TrafficStatsStore.sessionUp;
    v.sessionDown = TrafficStatsStore.sessionDown;
    v.peakUp = TrafficStatsStore.peakUp;
    v.peakDown = TrafficStatsStore.peakDown;
    v.resetDay = TrafficStatsStore.resetDay;
    const n: number = TrafficStatsStore.sessionSamples;
    v.avgUp = n > 0 ? TrafficStatsStore.sessionUpSum / n : 0;
    v.avgDown = n > 0 ? TrafficStatsStore.sessionDownSum / n : 0;
    const bucket: DailyBucket | undefined = TrafficStatsStore.daily.get(TrafficStatsStore.dayKey());
    v.todayUp = bucket === undefined ? 0 : bucket.up;
    v.todayDown = bucket === undefined ? 0 : bucket.down;
    v.month = TrafficStatsStore.monthSeries();
    return v;
  }

  /** 有按日数据（ClashPlus：「还没有按日数据」空态） */
  static hasDailyData(): boolean {
    return TrafficStatsStore.daily.size > 0;
  }
}
