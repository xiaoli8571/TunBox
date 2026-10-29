/**
 * 订阅自动刷新调度器（对齐 iOS 阵营 Shadowrocket/Stash/Loon 的 6 小时自动更新）。
 *
 * 为什么需要：AppSettings.autoUpdateSubscription 只是一个持久化开关（AppSettings.ets:55/140/222/287），
 * 此前**没有任何调度器消费该字段** —— 用户打开「自动更新订阅」后，只有手动进订阅页点刷新才会更新，
 * 节点池会随机场更新逐渐失效（节点下线、端口变更），表现为「过几天节点全超时」。
 *
 * 双轨触发（HarmonyOS 与 iOS NEOnDemand/后台刷新的对位实现）：
 * 1. WorkScheduler 延迟任务（workscheduler/SubscriptionWorkAbility.ets）：进程不在时由系统
 *    按内存/功耗统一调度拉起，isPersisted=true 保证重启后任务仍在；repeatCycleTime=4h
 *    （API 下限 20min），到期时只刷新「真正过期」的订阅（lastFetchedAt 距今 > STALE_MS）。
 * 2. 前台兜底（EntryAbility.onCreate/onForeground → maybeRunExpiredRefresh）：
 *    WorkScheduler 的实际触发时机受系统调度影响（可能延迟数小时），应用回到前台时
 *    立刻补一次过期检查，保证用户看到的节点池总是新的。
 *
 * 复用约束（与订阅页「全部刷新」完全一致，不新增任何写路径）：
 * - 刷新只走 SubscriptionService.refreshSubscriptionsConcurrently（prepare 并发 + apply
 *   串行的既有语义，见 ConcurrentRefresh.ets 顶部注释），解析/落盘/限流/诊断零改动；
 * - 只刷新 lastFetchedAt 过期的订阅（304/ETag 条件请求照常生效，未变更是零成本）；
 * - 全局单航班（running 静态闸门）：WorkScheduler 触发与前台兜底并发到达时只跑一批；
 * - 后台触发（WorkScheduler 扩展进程）不带 UI 进度，结果只写日志与订阅状态落盘。
 */
import { workScheduler } from '@kit.BackgroundTasksKit';
import { SettingsService } from './SettingsService';
import {
  SubscriptionService
} from './SubscriptionService';
import {
  RefreshBatchProgress, RefreshItemOutcome, RefreshBatchSummary
} from './ConcurrentRefresh';
import { isEphemeralHost, EPHEMERAL_SUBSCRIPTION_REFRESH_MS } from './SubscriptionFetchPolicy';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'SubscriptionUpdateScheduler';

/** 订阅过期阈值（6 小时，对齐 Stash/Loon 推荐的 Update Interval）。
 *  2026-10-29：这是**默认值**。用户在「编辑订阅」里改的间隔会覆盖它，见 `staleThresholdMs()`。 */
export const SUBSCRIPTION_STALE_MS: number = 6 * 60 * 60 * 1000;

/** 允许的自定义间隔边界（分钟）：15 分钟~7 天，超出即视为非法输入，回落默认 6h */
export const MIN_UPDATE_INTERVAL_MINUTES: number = 15;
export const MAX_UPDATE_INTERVAL_MINUTES: number = 7 * 24 * 60;

/**
 * 把用户配置的「自动更新间隔（分钟）」换算成过期阈值（ms）。
 *
 * 为什么要这个函数：`SUBSCRIPTION_STALE_MS` 一直是常量，编辑弹窗里的间隔也是硬编码
 * 字符串 —— 用户改成 30 分钟也完全没作用。现在统一从这里取，调度器与 UI 同源。
 * 非法值（非数字 / 越界 / 0）→ 回落 6h，避免存成 0 之后「每次都判定过期」疯狂拉取。
 */
export function staleThresholdMs(minutes: number): number {
  if (typeof minutes !== 'number' || !Number.isFinite(minutes)) {
    return SUBSCRIPTION_STALE_MS;
  }
  const m: number = Math.floor(minutes);
  if (m < MIN_UPDATE_INTERVAL_MINUTES || m > MAX_UPDATE_INTERVAL_MINUTES) {
    return SUBSCRIPTION_STALE_MS;
  }
  return m * 60 * 1000;
}

/**
 * WorkScheduler 周期：4 小时轮询一次「是否有过期订阅」。
 * API 约束：repeatCycleTime 下限 20min；比 STALE_MS 短的轮询只是多几次空检查
 * （无过期订阅时不发任何网络请求），换来更贴近 6h 的真实刷新间隔。
 */
const WORK_REPEAT_MS: number = 4 * 60 * 60 * 1000;

/** WorkScheduler 任务 id（应用内唯一；stopWork/查询都用它） */
const WORK_ID: number = 20260101;

/** 前台兜底节流：同一进程存活期内至少间隔 5 分钟才再查一次（防每次切页面都查） */
const FOREGROUND_THROTTLE_MS: number = 5 * 60 * 1000;

/** 过期订阅扫描结果（maybeRunExpiredRefresh 的返回，诊断/测试用） */
export class StaleScanResult {
  /** 扫描时订阅总数（不含 local:// 伪订阅） */
  total: number = 0;
  /** 过期（lastFetchedAt 距今 > 阈值）的订阅数 */
  stale: number = 0;
  /** 本次实际触发的刷新条数（0 = 无过期或已有批次在跑） */
  launched: number = 0;
  /** 未触发原因（日志用） */
  skippedReason: string = '';

  static none(reason: string): StaleScanResult {
    const r = new StaleScanResult();
    r.skippedReason = reason;
    return r;
  }
}

export class SubscriptionUpdateScheduler {
  private static shared: SubscriptionUpdateScheduler | null = null;

  static instance(): SubscriptionUpdateScheduler {
    if (SubscriptionUpdateScheduler.shared === null) {
      SubscriptionUpdateScheduler.shared = new SubscriptionUpdateScheduler();
    }
    return SubscriptionUpdateScheduler.shared;
  }

  private constructor() {
  }

  /** WorkScheduler 任务是否已注册（进程内幂等闸门；isPersisted 任务重启后系统自动恢复） */
  private workRegistered: boolean = false;
  /** 单航班闸门：任何时刻最多一个刷新批次在跑（WorkScheduler 与前台兜底共用） */
  private static running: boolean = false;
  /** 前台兜底上次运行时刻（0 = 从未） */
  private lastForegroundRunAt: number = 0;

  /**
   * 应用启动入口（EntryAbility.onCreate 调用）：
   * 1) 注册 WorkScheduler 周期任务（幂等；失败只降级为前台兜底，不影响主流程）；
   * 2) 立刻做一次过期检查（冷启动兜底，节流不适用首次）。
   */
  onAppStart(context: Context): void {
    this.ensureWorkScheduled();
    this.maybeRunExpiredRefresh(context, true)
      .catch((e: Object): void => {
        AppLogger.warn(TAG, `cold-start stale check failed: ${AppLogger.errText(e)}`);
      });
  }

  /**
   * 回前台入口（EntryAbility.onForeground 调用）：节流后的过期检查。
   * WorkScheduler 触发时机受系统调度影响，前台兜底保证「用户打开应用时节点池是新的」。
   */
  onForeground(context: Context): void {
    this.maybeRunExpiredRefresh(context, false)
      .catch((e: Object): void => {
        AppLogger.warn(TAG, `foreground stale check failed: ${AppLogger.errText(e)}`);
      });
  }

  /** 注册 WorkScheduler 周期任务（幂等；重复注册会被 startWork 覆盖同 id 任务）。 */
  ensureWorkScheduled(): void {
    if (this.workRegistered) {
      return;
    }
    try {
      const info: workScheduler.WorkInfo = {
        workId: WORK_ID,
        // bundleName/abilityName 为 WorkInfo 必填字段：系统据它找到
        // workscheduler/SubscriptionWorkAbility 回调（onWorkStart/onWorkStop）
        bundleName: 'com.tunbox.client',
        abilityName: 'SubscriptionWorkAbility',
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
        isRepeat: true,
        isPersisted: true,
        repeatCycleTime: WORK_REPEAT_MS,
        isDeepIdle: false
      };
      workScheduler.startWork(info);
      this.workRegistered = true;
      AppLogger.info(TAG, `work scheduled: id=${WORK_ID} repeat=${WORK_REPEAT_MS}ms`);
    } catch (e) {
      // 注册失败（如系统服务未就绪）只降级为前台兜底：下一次 onAppStart 会再试
      AppLogger.warn(TAG, `startWork failed (fallback to foreground check): ${AppLogger.errText(e)}`);
    }
  }

  /**
   * 过期检查（唯一公开的刷新入口；WorkScheduler 扩展与前台兜底共用）：
   * autoUpdateSubscription 关闭 → 跳过；无过期订阅 → 跳过；已有批次 → 跳过。
   * 刷新走既有 refreshSubscriptionsConcurrently（并发拉取 + 串行落盘，语义零改动）。
   */
  async maybeRunExpiredRefresh(context: Context, force: boolean): Promise<StaleScanResult> {
    // 闸门必须**同步 check-and-set**：下面 load/init 两个 await 之间若只检查不置位，
    // WorkScheduler 批次与冷启动 onAppStart(force=true) 会双双通过检查 → 两个批次并发
    // → prefetchCache 被后者清空、apply 跨批次交错（正是 ConcurrentRefresh 明文禁止的
    // 非重入写路径）。先占坑；整个方法体包 try/finally，任何提前返回或异常都释放闸门，
    // 避免一次 load() reject 让 running 卡死、后续批次永远 'batch already running'。
    if (SubscriptionUpdateScheduler.running) {
      return StaleScanResult.none('batch already running');
    }
    SubscriptionUpdateScheduler.running = true;
    try {
      if (!force && Date.now() - this.lastForegroundRunAt < FOREGROUND_THROTTLE_MS) {
        return StaleScanResult.none('throttled');
      }
      this.lastForegroundRunAt = Date.now();
      const settings = await SettingsService.load();
      if (!settings.autoUpdateSubscription) {
        return StaleScanResult.none('autoUpdateSubscription disabled');
      }
      const subs = SubscriptionService.instance();
      await subs.init(context);
    const now = Date.now();
    // 阈值来自用户设置（2026-10-29）：以前这里是常量 6h，改设置完全不生效
    const configuredStaleMs: number = staleThresholdMs(settings.subscriptionUpdateIntervalMinutes);
    const staleIds: string[] = [];
    let total = 0;
    let ephemeralCount = 0;
    for (const s of subs.subscriptions) {
      if (s.url.startsWith('local://')) {
        continue; // 本地 YAML 伪订阅无远端可更新
      }
      if (s.legacyFormat) {
        // 旧格式（非 Clash）订阅已停止刷新：节点照常可用，但不再自动拉取，
        // 否则每次扫描都会重新报一次「不是 Clash 配置」。
        continue;
      }
      total = total + 1;
      // 易变域名订阅（加固③）：节点 server 命中 trycloudflare 等临时隧道域名时，
      // 隧道域名轮换后旧节点全部超时，刷新间隔压到 6h（EPHEMERAL_SUBSCRIPTION_REFRESH_MS，
      // 与全局阈值同值 → 当前行为等价；全局阈值将来调大时易变订阅仍保持 6h）。
      // 其它订阅的刷新行为不变（仍按 SUBSCRIPTION_STALE_MS）。
      let ephemeral = false;
      for (const n of subs.nodes) {
        if (n.subscriptionId === s.id && isEphemeralHost(n.server)) {
          ephemeral = true;
          break;
        }
      }
      if (ephemeral) {
        ephemeralCount = ephemeralCount + 1;
      }
      const staleMs = ephemeral
        ? Math.min(configuredStaleMs, EPHEMERAL_SUBSCRIPTION_REFRESH_MS)
        : configuredStaleMs;
      if (s.lastFetchedAt <= 0 || now - s.lastFetchedAt > staleMs) {
        staleIds.push(s.id);
      }
    }
    if (ephemeralCount > 0) {
      AppLogger.info(TAG, `ephemeral-domain subscriptions: ${ephemeralCount}/${total} (refresh <= 6h)`);
    }
    if (staleIds.length === 0) {
      return StaleScanResult.none('no stale subscription');
    }
    AppLogger.info(TAG, `auto refresh start: ${staleIds.length}/${total} stale`);
    const summary: RefreshBatchSummary = await subs.refreshSubscriptionsConcurrently(
      staleIds, 2,
      (progress: RefreshBatchProgress, item: RefreshItemOutcome): void => {
        // 后台批次不带 UI：每条完成只写日志（订阅状态/lastFetchedAt 由既有路径落盘）
        AppLogger.info(TAG, `auto refresh item ${item.id}: ok=${item.ok} `
          + `nodes=${item.nodeCount} ${item.advice.length > 0 ? item.advice : item.message}`);
      },
      (): boolean => false // 无用户中止来源；批次自跑到底
    );
    AppLogger.info(TAG, `auto refresh done: ok=${summary.okCount} fail=${summary.failCount} `
      + `nodes=${summary.nodeCount}`);
    const r = new StaleScanResult();
    r.total = total;
    r.stale = staleIds.length;
    r.launched = staleIds.length;
    return r;
    } finally {
      SubscriptionUpdateScheduler.running = false;
    }
  }

  /** WorkScheduler 任务 id（SubscriptionWorkAbility 收尾 stopWork 用） */
  static workId(): number {
    return WORK_ID;
  }
}
