/**
 * 测速结论的**单一真源**（进程内 + 落盘 + 渲染）。
 *
 * ## 为什么要有这个模块（2026-10-20 审计 F2/F4/F13）
 *
 *  - **F2/F4：整单覆盖会丢更新。**
 *    旧实现把「最近一次测速结果」整个序列化进 `AppSettings.nodeSortSnapshot`，
 *    任何一次写都是**整单覆盖**：写测速延迟时会把自动切换记账刚写进去的
 *    `failCount/lastOk` 一起盖掉（两个写者、两个内存副本 → 后写者赢）。
 *    这里改成**字段级落盘**：每个 (节点, 字段) 一个独立的存储槽，
 *    写 `delayMs` 绝不会碰到同一节点的 `failKind/testedAt`，更不会碰到别的节点。
 *
 *  - **旧快照不许盖掉进程内的新结论。**
 *    冷启动恢复时，落盘快照可能比进程内的新结论旧（测速刚跑完、快照还没写回）。
 *    旧实现无条件覆盖 → 新结论被旧快照抹掉。这里 `restore()` 只在
 *    「进程内**没有**记录」或「落盘记录**更新**（testedAt 更大）」时才覆盖。
 *
 *  - **F13：三套渲染各说各话。**
 *    「live（进程内）/ 落盘 / 恢复」三处各有一套文案与颜色逻辑，
 *    同一个 failKind 在不同页面显示不一样。这里合成**一张表**
 *    （{@link LatencyStore.describe}），三处都从它出。
 *
 * ## 判定 vs 非判定
 *
 * 「非判定失败」= 这次失败**不构成**「节点通不通」的结论
 * （通道坏了 / 排队没拨号 / 整批没测完 / 认不出来）。
 * 这类失败**不产生节点结论**：既不写进程内结论，也不写落盘，
 * 节点保持上一次的有效结论（沿用上次结论），不会因为「我们自己的问题」变红。
 * 判定表唯一真源在 {@link LatencyProbeKind.isVerdictKind}。
 */
import { preferences } from '@kit.ArkData';
import { AppLogger } from '../utils/AppLogger';
// 分类表 + 判定表住在**零 import** 的 LatencyKinds.ets（唯一真源；
// services/pages 侧都能安全值依赖 ⇒ Node 扁平暂存闸门能跑）。
import { LatencyProbeKind } from './LatencyKinds';

const TAG: string = 'LatencyStore';

/** 落盘字段名（**字段级写**：一个字段一个槽，互不覆盖） */
export class LatencyStoreField {
  /** 延迟毫秒 */
  static readonly DELAY_MS: string = 'delayMs';
  /** 失败分类 */
  static readonly FAIL_KIND: string = 'failKind';
  /** 真实测速时间戳（ms） */
  static readonly TESTED_AT: string = 'testedAt';
}

/** 一条测速结论（进程内与落盘共用同一形状） */
export class LatencyVerdict {
  /** 节点名 */
  name: string = '';
  /** 延迟毫秒；>=1 = 实测；-1 = 失败；-2 = 未测 */
  delayMs: number = -2;
  /** 失败分类（LatencyProbeKind.*；'' = 无失败/实测成功） */
  failKind: string = LatencyProbeKind.NONE;
  /** 真实测速时间戳（ms）；0 = 未知 */
  testedAt: number = 0;
}

/** 渲染视图（live / 落盘 / 恢复三套渲染合成的**一张表**的输出） */
export class LatencyVerdictView {
  /** 状态词（实测为空串，由 UI 自行拼延迟；失败/未测给中文词） */
  text: string = '';
  /** 展示级别：none（灰）/ ok（绿）/ warn（黄）/ bad（红） */
  level: string = 'none';
  /** 是否构成节点结论（决定要不要写结论、要不要参与排序） */
  isVerdict: boolean = false;
  /** 是否陈旧（超过 TTL；UI 应灰显但保留） */
  stale: boolean = false;
  /** 延迟文本（如 '123ms'；无则空串） */
  delayText: string = '';
}

/** 展示级别取值 */
export class LatencyViewLevel {
  static readonly NONE: string = 'none';
  static readonly OK: string = 'ok';
  static readonly WARN: string = 'warn';
  static readonly BAD: string = 'bad';
}

/**
 * 某个失败分类的计数（组级聚合用）。
 *
 * `kind` 取值：`''` = 测通；`'untested'` = 没有结论（从未测 / 非判定失败）；
 * 其余 = 具体失败分类（`dns_unresolved` / `network_unreachable` / `timeout` / …）。
 */
export class LatencyKindCount {
  kind: string = '';
  count: number = 0;
  /** 占本批节点的比例（0~1） */
  ratio: number = 0;
}

/**
 * 组级汇总（一条组级诊断，而不是 N 条同色红条）。
 */
export class LatencyGroupSummary {
  /** 参与统计的节点数 */
  total: number = 0;
  /** 测通数 */
  okCount: number = 0;
  /** 没有结论的节点数（从未测 / 非判定失败） */
  untestedCount: number = 0;
  /** 判定类失败总数 */
  failedCount: number = 0;
  /** 分类计数（按数量降序） */
  counts: LatencyKindCount[] = [];
  /** 主导失败分类（'' = 没有失败） */
  dominantKind: string = '';
  /** 是否「整组同因全败」 */
  isUniformFailure: boolean = false;
  /** 组级结论文案（空串 = 没有失败） */
  conclusion: string = '';
}

/**
 * 落盘后端（可注入 → 可单测；生产用 {@link PreferencesLatencyPersistence}）。
 *
 * 契约：**字段级写**。`saveField(name, field, value)` 只允许动
 * 「这个节点的**这一个字段**」，不得整单覆盖。
 */
export interface LatencyPersistence {
  /** 读某节点的落盘记录（没有则 null） */
  loadNode(name: string): Promise<LatencyVerdict | null>;
  /** **字段级**写：只动这个节点的这一个字段 */
  saveField(name: string, field: string, value: string): Promise<void>;
  /** 已落盘的节点名列表 */
  listNodes(): Promise<string[]>;
  /**
   * 落盘（把内存里的写入刷到磁盘）。
   *
   * 单独一个接口方法：字段级写**不**各自 flush（一次 persist 三个字段 → 三次磁盘写，
   * 200 个节点就是 600 次，落盘会把主线程拖住）；由 {@link LatencyStore.persist}
   * 在写完全部字段后统一 flush 一次。
   */
  flush(): Promise<void>;
}

/** 内存后端（单测 / 无持久化场景的兜底） */
export class MemoryLatencyPersistence implements LatencyPersistence {
  private static slots: Map<string, Map<string, string>> = new Map<string, Map<string, string>>();

  /** 清空（单测用） */
  static reset(): void {
    MemoryLatencyPersistence.slots = new Map<string, Map<string, string>>();
    MemoryLatencyPersistence.writeCount = 0;
    MemoryLatencyPersistence.flushCount = 0;
  }

  /** 某个节点某个字段的当前值（单测/诊断用） */
  static valueOf(name: string, field: string): string {
    const fields = MemoryLatencyPersistence.slots.get(name);
    if (fields === undefined) {
      return '';
    }
    const v = fields.get(field);
    return v === undefined ? '' : v;
  }

  /** 某个节点当前有哪些字段槽（单测用：断言「没有整单 blob 槽」） */
  static slotsOf(name: string): string[] {
    const out: string[] = [];
    const fields = MemoryLatencyPersistence.slots.get(name);
    if (fields === undefined) {
      return out;
    }
    fields.forEach((_v: string, field: string): void => {
      out.push(field);
    });
    return out;
  }

  async loadNode(name: string): Promise<LatencyVerdict | null> {
    const fields = MemoryLatencyPersistence.slots.get(name);
    if (fields === undefined) {
      return null;
    }
    const rec = new LatencyVerdict();
    rec.name = name;
    rec.delayMs = LatencyStore.parseNumber(MemoryLatencyPersistence.valueOf(name, LatencyStoreField.DELAY_MS), -2);
    rec.failKind = MemoryLatencyPersistence.valueOf(name, LatencyStoreField.FAIL_KIND);
    rec.testedAt = LatencyStore.parseNumber(MemoryLatencyPersistence.valueOf(name, LatencyStoreField.TESTED_AT), 0);
    return rec;
  }

  async saveField(name: string, field: string, value: string): Promise<void> {
    let fields = MemoryLatencyPersistence.slots.get(name);
    if (fields === undefined) {
      fields = new Map<string, string>();
      MemoryLatencyPersistence.slots.set(name, fields);
    }
    // 只写这一个字段 —— 其余字段原样保留（这就是「字段级写」）。
    fields.set(field, value);
    MemoryLatencyPersistence.writeCount++;
  }

  async listNodes(): Promise<string[]> {
    const out: string[] = [];
    MemoryLatencyPersistence.slots.forEach((_fields: Map<string, string>, name: string): void => {
      out.push(name);
    });
    return out;
  }

  async flush(): Promise<void> {
    MemoryLatencyPersistence.flushCount++;
  }

  /** flush 次数（单测用：断言 persist 只 flush 一次） */
  static flushCount = 0;

  /** 字段级写次数（单测用：断言「只写一个字段」与「聚合不落盘」） */
  static writeCount = 0;

  /** 清空 flush 计数（单测用） */
  static resetFlushCount(): void {
    MemoryLatencyPersistence.flushCount = 0;
  }
}

/**
 * 生产落盘后端（ArkData preferences）。
 *
 * **一个 (节点, 字段) 一个 key** —— 于是：
 *  - 写 `delayMs` 不会碰到同一节点的 `failKind/testedAt`；
 *  - 写节点 A 不会碰到节点 B；
 *  - 不存在「整单覆盖」这条路径。
 */
export class PreferencesLatencyPersistence implements LatencyPersistence {
  private static store: preferences.Preferences | null = null;
  /** preferences 文件名（与 AppSettings 分开，避免互相整单覆盖） */
  static readonly PREF_NAME: string = 'TunBoxLatencyV2';
  /** key 前缀 */
  static readonly KEY_PREFIX: string = 'lv2_';

  /** 初始化（应用启动时调用一次） */
  static async init(context: Context): Promise<void> {
    PreferencesLatencyPersistence.store = await preferences.getPreferences(context, PreferencesLatencyPersistence.PREF_NAME);
  }

  /** key 构造：节点名做 URL 编码（节点名可能带 emoji/空格/斜杠） */
  static key(name: string, field: string): string {
    return `${PreferencesLatencyPersistence.KEY_PREFIX}${encodeURIComponent(name)}_${field}`;
  }

  /** 从 key 反解节点名（decode 失败返回空串） */
  static nameOfKey(key: string): string {
    if (!key.startsWith(PreferencesLatencyPersistence.KEY_PREFIX)) {
      return '';
    }
    const rest = key.substring(PreferencesLatencyPersistence.KEY_PREFIX.length);
    const cut = rest.lastIndexOf('_');
    if (cut <= 0) {
      return '';
    }
    try {
      return decodeURIComponent(rest.substring(0, cut));
    } catch (e) {
      return '';
    }
  }

  private static async ready(): Promise<preferences.Preferences | null> {
    return PreferencesLatencyPersistence.store;
  }

  async loadNode(name: string): Promise<LatencyVerdict | null> {
    const store = await PreferencesLatencyPersistence.ready();
    if (store === null) {
      return null;
    }
    try {
      const delayRaw = await store.get(PreferencesLatencyPersistence.key(name, LatencyStoreField.DELAY_MS), '-2') as string;
      const kindRaw = await store.get(PreferencesLatencyPersistence.key(name, LatencyStoreField.FAIL_KIND), '') as string;
      const atRaw = await store.get(PreferencesLatencyPersistence.key(name, LatencyStoreField.TESTED_AT), '0') as string;
      if (delayRaw === '-2' && kindRaw.length === 0 && atRaw === '0') {
        return null;
      }
      const rec = new LatencyVerdict();
      rec.name = name;
      rec.delayMs = LatencyStore.parseNumber(delayRaw, -2);
      rec.failKind = kindRaw;
      rec.testedAt = LatencyStore.parseNumber(atRaw, 0);
      return rec;
    } catch (e) {
      AppLogger.warn(TAG, `load latency record failed: ${AppLogger.errText(e)}`);
      return null;
    }
  }

  async saveField(name: string, field: string, value: string): Promise<void> {
    const store = await PreferencesLatencyPersistence.ready();
    if (store === null) {
      return;
    }
    try {
      await store.put(PreferencesLatencyPersistence.key(name, field), value);
    } catch (e) {
      AppLogger.warn(TAG, `save latency field failed: ${AppLogger.errText(e)}`);
    }
  }

  async flush(): Promise<void> {
    const store = await PreferencesLatencyPersistence.ready();
    if (store === null) {
      return;
    }
    try {
      await store.flush();
    } catch (e) {
      AppLogger.warn(TAG, `flush latency records failed: ${AppLogger.errText(e)}`);
    }
  }

  async listNodes(): Promise<string[]> {
    const store = await PreferencesLatencyPersistence.ready();
    if (store === null) {
      return [];
    }
    try {
      const all = await store.getAll();
      const out: string[] = [];
      for (const key of Object.keys(all)) {
        const name = PreferencesLatencyPersistence.nameOfKey(key);
        if (name.length > 0 && out.indexOf(name) < 0) {
          out.push(name);
        }
      }
      return out;
    } catch (e) {
      AppLogger.warn(TAG, `list latency records failed: ${AppLogger.errText(e)}`);
      return [];
    }
  }
}

/**
 * 测速结论单一真源。
 *
 * 用法：
 *  1. 探测出结果 → {@link LatencyStore.applyProbeResult}（非判定失败自动被丢弃）；
 *  2. 需要落盘 → {@link LatencyStore.persist}（**字段级**写）；
 *  3. 冷启动恢复 → {@link LatencyStore.restoreAll}（旧快照不会盖掉更新的结论）；
 *  4. 渲染 → {@link LatencyStore.describe}（live/落盘/恢复共用同一张表）。
 */
export class LatencyStore {
  /** 进程内结论（**单一真源**：UI 读这里，不读别处） */
  private static live: Map<string, LatencyVerdict> = new Map<string, LatencyVerdict>();
  /** 落盘后端（可注入） */
  private static backend: LatencyPersistence = new MemoryLatencyPersistence();

  /**
   * 结论的 TTL：超过即视为陈旧（UI 灰显但保留）。
   *
   * ⚠ **转调别名**：阈值本体只有一份，在零 import 的内核分类表
   * （{@link LatencyProbeKind.STALE_MS}）—— 这里**不再**留第二份字面量。
   */
  static readonly STALE_MS: number = LatencyProbeKind.STALE_MS;
  /** 聚合用的「测通」桶（kind = ''） */
  static readonly KIND_OK: string = '';
  /** 聚合用的「没有结论」桶 */
  static readonly KIND_UNTESTED: string = 'untested';

  /** 注入落盘后端（生产用 preferences；单测用内存版） */
  static setBackend(backend: LatencyPersistence): void {
    LatencyStore.backend = backend;
  }

  /** 当前后端（诊断用） */
  static backendRef(): LatencyPersistence {
    return LatencyStore.backend;
  }

  /** 清空进程内结论（单测用） */
  static clear(): void {
    LatencyStore.live = new Map<string, LatencyVerdict>();
  }

  /** 读某节点的结论（没有则 null） */
  static recordFor(name: string): LatencyVerdict | null {
    const v = LatencyStore.live.get(name);
    return v === undefined ? null : v;
  }

  /** 结论是否构成节点结论（判定表唯一真源在 LatencyKinds） */
  static isVerdictKind(kind: string): boolean {
    return LatencyProbeKind.isVerdictKind(kind);
  }

  /**
   * 记一条探测结果。
   *
   * @return true = 产生了节点结论（已写进进程内）；false = **非判定失败**，未落结论。
   */
  static applyProbeResult(name: string, delayMs: number, failKind: string, testedAt: number): boolean {
    if (!LatencyStore.isVerdictKind(failKind)) {
      // 非判定失败：绝不产生节点结论（保留上一次有效结论）。
      return false;
    }
    const rec = new LatencyVerdict();
    rec.name = name;
    rec.delayMs = delayMs;
    rec.failKind = failKind;
    rec.testedAt = testedAt;
    LatencyStore.live.set(name, rec);
    return true;
  }

  /**
   * **字段级**落盘：把进程内结论逐字段写下去。
   *
   * 绝不整单覆盖：每个字段一个独立槽（见 {@link LatencyPersistence.saveField}）。
   * 写完全部字段后**统一 flush 一次**（字段级写不各自 flush）。
   */
  static async persist(name: string): Promise<void> {
    const rec = LatencyStore.live.get(name);
    if (rec === undefined) {
      return;
    }
    await LatencyStore.backend.saveField(name, LatencyStoreField.DELAY_MS, String(rec.delayMs));
    await LatencyStore.backend.saveField(name, LatencyStoreField.FAIL_KIND, rec.failKind);
    await LatencyStore.backend.saveField(name, LatencyStoreField.TESTED_AT, String(rec.testedAt));
    await LatencyStore.backend.flush();
  }

  /** 批量落盘（逐节点逐字段；不吞异常，失败会记日志） */
  static async persistAll(names: string[]): Promise<void> {
    for (const name of names) {
      await LatencyStore.persist(name);
    }
  }

  /**
   * 恢复一条落盘结论。
   *
   * @return true = 已写进进程内；false = **拒绝覆盖**（进程内已有更新结论，或
   *         落盘这条是非判定失败）。
   */
  static restore(name: string, persisted: LatencyVerdict): boolean {
    const existing = LatencyStore.live.get(name);
    if (existing !== undefined && persisted.testedAt <= existing.testedAt) {
      // 旧快照（或同刻快照）**不许**盖掉进程内的结论。
      return false;
    }
    if (!LatencyStore.isVerdictKind(persisted.failKind)) {
      // 非判定失败不产生节点结论：沿用上一次有效结论。
      return false;
    }
    const rec = new LatencyVerdict();
    rec.name = name;
    rec.delayMs = persisted.delayMs;
    rec.failKind = persisted.failKind;
    rec.testedAt = persisted.testedAt;
    LatencyStore.live.set(name, rec);
    return true;
  }

  /** 冷启动恢复：把落盘结论读回来（遵守 restore 的「不覆盖更新结论」规则） */
  static async restoreAll(): Promise<number> {
    const names = await LatencyStore.backend.listNodes();
    let restored = 0;
    for (const name of names) {
      const rec = await LatencyStore.backend.loadNode(name);
      if (rec !== null && LatencyStore.restore(name, rec)) {
        restored++;
      }
    }
    return restored;
  }

  /**
   * **渲染表**（live / 落盘 / 恢复三套渲染合成这一张表）。
   *
   * 同一个 failKind 在任何来源都得到同一个文案与级别 —— F13 的根治点。
   */
  static describe(failKind: string, delayMs: number, testedAt: number, nowMs: number): LatencyVerdictView {
    const view = new LatencyVerdictView();
    // 旧版测速把非超时失败写成表外字面量 'failed'（2026-10-22 修复前），
    // 那批结论可能还在落盘快照里。认成「拨号失败」，避免升级后旧快照继续显示 `--`。
    const kind: string = failKind === 'failed' ? LatencyProbeKind.NETWORK_UNREACHABLE : failKind;
    view.isVerdict = LatencyStore.isVerdictKind(kind);
    if (kind.length === 0 && delayMs >= 1) {
      view.text = '';
      view.level = LatencyViewLevel.OK;
      view.delayText = `${delayMs}ms`;
    } else if (kind === LatencyProbeKind.TIMEOUT) {
      view.text = '超时';
      view.level = LatencyViewLevel.BAD;
    } else if (kind === LatencyProbeKind.NETWORK_UNREACHABLE) {
      // 「拨号失败」= 内核已经 dial 过这个节点但没拨通（有 dial 证据）。
      // ⚠ 不用「网络不可达」——那是用户点名过的糊弄说法（把三类失败压成一句）；
      // 也绝不能出现「域名」（域名问题有独立分类 dns_unresolved）。
      view.text = '拨号失败';
      view.level = LatencyViewLevel.BAD;
    } else if (failKind === LatencyProbeKind.DNS_UNRESOLVED) {
      // 域名解析不出来（2026-10-20 真机：四解析器全 NXDOMAIN）——
      // 与「网络不可达」**严格分开**：这多半是机场域名已下线，不是出口不通。
      view.text = '域名无法解析（节点域名可能已下线）';
      view.level = LatencyViewLevel.BAD;
    } else if (failKind === LatencyProbeKind.SWITCH_FAILED) {
      // 配置类结论：节点没进内核表 ≠ 节点坏 → 黄色「未生效」，不是红色失败。
      view.text = '未生效';
      view.level = LatencyViewLevel.WARN;
    } else if (failKind === LatencyProbeKind.CORE_NOT_READY) {
      // 通道坏了 → 不是节点的问题 → 灰「未测」，绝不红。
      view.text = '未测';
      view.level = LatencyViewLevel.NONE;
    } else if (failKind === LatencyProbeKind.QUEUE_TIMEOUT) {
      view.text = '排队超时';
      view.level = LatencyViewLevel.NONE;
    } else if (failKind === LatencyProbeKind.PORT_ONLY) {
      view.text = '≈';
      view.level = LatencyViewLevel.WARN;
    } else if (failKind === LatencyProbeKind.UNSUPPORTED) {
      view.text = '不支持';
      view.level = LatencyViewLevel.NONE;
    } else if (failKind === LatencyProbeKind.CANCELLED) {
      view.text = '已取消';
      view.level = LatencyViewLevel.NONE;
    } else if (failKind === LatencyProbeKind.UNTESTED) {
      view.text = '--';
      view.level = LatencyViewLevel.NONE;
    } else {
      // 未知/空分类：既不红也不绿 —— 没有信息就别下结论。
      view.text = '--';
      view.level = LatencyViewLevel.NONE;
    }
    // 陈旧判定（**唯一**真源在零 import 的内核分类表 LatencyProbeKind.isStale）：
    //  - 有时间戳：超 TTL ⇒ 陈旧（灰显「·旧」）；
    //  - 年龄未知（testedAt<=0）：**失败结论**算陈旧（冷启动假红防线），
    //    有值但年龄未知不算（无法判断，不标「旧」）。
    const isFailureConclusion = failKind.length > 0 && view.isVerdict;
    if (LatencyProbeKind.isStale(testedAt, nowMs, isFailureConclusion)) {
      view.stale = true;
    }
    return view;
  }

  /** 解析数字（容错） */
  static parseNumber(raw: string, fallback: number): number {
    if (raw.length === 0) {
      return fallback;
    }
    const n = Number(raw);
    if (!Number.isFinite(n)) {
      return fallback;
    }
    return n;
  }

  // ── 组级聚合（只读、不落盘）────────────────────────────────────────────
  //
  // 需求（2026-10-20 lead）：整组节点同因全败时，UI 要能给出**一条组级结论**
  // （例：「34/34 节点域名无法解析，疑似机场域名下线」），
  // 而不是 34 条同色红条 ⇒ 渲染层需要「按 failKind 统计 + 占比」的数据。

  /**
   * 按失败分类统计一批节点（**只读**：不落盘、不改进程内结论）。
   *
   * @param names 节点名列表
   * @return 计数列表（按数量降序；`kind` 为 '' 表示测通，`'untested'` 表示没有结论）
   */
  static aggregateByKind(names: string[]): LatencyKindCount[] {
    const buckets = new Map<string, number>();
    buckets.set(LatencyStore.KIND_OK, 0);
    buckets.set(LatencyStore.KIND_UNTESTED, 0);
    let total = 0;
    for (const name of names) {
      total++;
      const rec = LatencyStore.recordFor(name);
      let kind = LatencyStore.KIND_UNTESTED;
      if (rec !== null) {
        kind = rec.failKind.length === 0 ? LatencyStore.KIND_OK : rec.failKind;
      }
      const prev = buckets.get(kind);
      buckets.set(kind, prev === undefined ? 1 : prev + 1);
    }
    const out: LatencyKindCount[] = [];
    buckets.forEach((count: number, kind: string): void => {
      const item = new LatencyKindCount();
      item.kind = kind;
      item.count = count;
      item.ratio = total > 0 ? count / total : 0;
      out.push(item);
    });
    out.sort((a: LatencyKindCount, b: LatencyKindCount): number => {
      if (b.count !== a.count) {
        return b.count - a.count;
      }
      return LatencyStore.kindPriority(a.kind) - LatencyStore.kindPriority(b.kind);
    });
    return out;
  }

  /**
   * 组级汇总（一次给全：计数 + 占比 + 主导分类 + **一条组级结论**）。
   *
   * 只读：不动进程内结论、不落盘。
   */
  static summarize(names: string[]): LatencyGroupSummary {
    const summary = new LatencyGroupSummary();
    summary.total = names.length;
    summary.counts = LatencyStore.aggregateByKind(names);
    for (const item of summary.counts) {
      if (item.kind === LatencyStore.KIND_OK) {
        summary.okCount = item.count;
      } else if (item.kind === LatencyStore.KIND_UNTESTED) {
        summary.untestedCount = item.count;
      } else {
        summary.failedCount += item.count;
      }
    }
    // 主导失败分类（数量最多；并列时按固定优先级）
    let best: string = '';
    let bestCount = 0;
    for (const item of summary.counts) {
      if (item.kind === LatencyStore.KIND_OK || item.kind === LatencyStore.KIND_UNTESTED) {
        continue;
      }
      if (item.count > bestCount
        || (item.count === bestCount && LatencyStore.kindPriority(item.kind) < LatencyStore.kindPriority(best))) {
        best = item.kind;
        bestCount = item.count;
      }
    }
    summary.dominantKind = best;
    // 「整组同因全败」= 所有失败都是同一个分类
    summary.isUniformFailure = summary.failedCount > 0 && bestCount === summary.failedCount;
    if (summary.failedCount === 0) {
      summary.conclusion = '';
    } else if (summary.isUniformFailure) {
      summary.conclusion = LatencyStore.groupConclusion(best, bestCount, summary.total);
    } else {
      summary.conclusion = LatencyStore.mixedConclusion(summary);
    }
    return summary;
  }

  /**
   * 组级结论文案（同一 kind 的整组失败 → 一句话）。
   *
   * 例：dns_unresolved ⇒「34/34 节点域名无法解析，疑似机场域名下线」。
   */
  static groupConclusion(kind: string, count: number, total: number): string {
    const head = `${count}/${total}`;
    if (kind === LatencyProbeKind.DNS_UNRESOLVED) {
      return `${head} 节点域名无法解析，疑似机场域名下线，请联系机场换线路或更换订阅`;
    }
    if (kind === LatencyProbeKind.NETWORK_UNREACHABLE) {
      return `${head} 节点拨号失败（出口或节点本身不可达）`;
    }
    if (kind === LatencyProbeKind.TIMEOUT) {
      return `${head} 节点超时`;
    }
    if (kind === LatencyProbeKind.SWITCH_FAILED) {
      return `${head} 节点未在内核生效（配置未同步）`;
    }
    return `${head} 节点失败（${kind}）`;
  }

  /** 分类统计的展示优先级（并列时用；数字越小越靠前） */
  private static kindPriority(kind: string): number {
    if (kind === LatencyProbeKind.DNS_UNRESOLVED) {
      return 0;
    }
    if (kind === LatencyProbeKind.NETWORK_UNREACHABLE) {
      return 1;
    }
    if (kind === LatencyProbeKind.TIMEOUT) {
      return 2;
    }
    if (kind === LatencyProbeKind.SWITCH_FAILED) {
      return 3;
    }
    if (kind === LatencyStore.KIND_OK) {
      return 8;
    }
    return 9;
  }

  /** 失败分类分散时的组级文案（不硬套单一原因） */
  private static mixedConclusion(summary: LatencyGroupSummary): string {
    const parts: string[] = [];
    for (const item of summary.counts) {
      if (item.kind === LatencyStore.KIND_OK || item.kind === LatencyStore.KIND_UNTESTED) {
        continue;
      }
      parts.push(`${item.kind} ${item.count}`);
    }
    return `失败分类分散（${parts.join('、')}）`;
  }
}
