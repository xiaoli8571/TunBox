/**
 * 设置持久化服务
 * 移植自 upstream: TunBox_Android/lib/services/settings_service.dart
 * - apiSecret：@ohos.security.asset（系统级加密存储，对应 Keystore AES-GCM / NativeApiSecretResolver）
 * - 连接快照：重启后恢复上次连接意图（对应 NativeConnectionSnapshotStore）
 */
import { preferences } from '@kit.ArkData';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { AppSettings, AppSettingsJson } from '../models/AppSettings';
import { AppLogger } from '../utils/AppLogger';
import { RawSubscriptionStore } from './RawSubscriptionStore';
import { NodeLatencyRecord, NodeSortModes, NodeSortSnapshot } from './NodeSortPersistence';

const TAG = 'SettingsService';
const PREF_NAME = 'tunbox_settings';
const KEY_SETTINGS = 'app_settings_json';
/**
 * 测速结论分片（字段级落盘）：只装**测速路径拥有**的字段
 * （latency / failKind / 手动顺序 / 批次时间戳）。
 * 只由 `nodeSortSnapshotWrite()` 写 —— 别的写者永远碰不到它。
 */
const KEY_NODE_SORT_LATENCY = 'node_sort_latency_json';
/**
 * 记账分片（字段级落盘）：只装**自动切换记账拥有**的字段（failCount / lastOk）。
 * 只由 `saveNodeSortStats()` 写。
 */
const KEY_NODE_SORT_STATS = 'node_sort_stats_json';
const ASSET_SERVICE = 'tunbox_service';
const ASSET_SECRET_KEY = 'api_secret';
const KEY_SNAPSHOT = 'connection_snapshot_json';
const KEY_DOH_PINS = 'doh_pins_json';
const KEY_ROUTING_SNAPSHOT = 'app_routing_snapshot_json';
// 2026-10-27：悬浮菜单启用。旧键（subscription_fab_x/y）是历史实验残留，
// 可能存着半屏坐标；换 v2 键让首次升级落到「右下角默认位」，之后拖过才恢复。
const KEY_SUBSCRIPTION_FAB_X = 'subscription_fab_v2_x';
const KEY_SUBSCRIPTION_FAB_Y = 'subscription_fab_v2_y';
/** 订阅页节点排布列数（1=单列 2=双列），用户手动切换后持久化 */
const KEY_NODE_COLUMNS = 'node_columns';

/** 连接快照（对应 NativeConnectionSnapshot：重启恢复连接意图） */
export class ConnectionSnapshot {
  desiredConnected: boolean = false;
  nodeName: string = '';
  savedAt: number = 0;
  /** 本次真实 VPN 会话开始时刻；旧快照缺少此字段时按 0 兼容。 */
  startedAt: number = 0;
  /**
   * 持久化连接相位：connecting | connected | disconnecting | disconnected | failed。
   * Extension 只把 desiredConnected=true 且 generation 匹配的 connecting/connected
   * 会话视为可恢复，避免旧异步结果或用户停止后的 timer 重新拉起 Core。
   */
  phase: string = 'disconnected';
  /**
   * 持久化会话代次。每次用户发起连接或主动停止时递增；Extension 的恢复、重建及
   * 异步完成回调必须同时校验 desiredConnected 和 generation，防止旧定时器在用户
   * 已停止后重新拉起 Core，也防止旧连接结果覆盖新会话状态。
   */
  sessionGeneration: number = 0;
}

/**
 * 应用分流三元组的**跨进程持久化副本**（mode / packagesJson / needsReview + 归属配置路径）。
 *
 * 存在的理由：VpnExtensionAbility 在 want.parameters 被系统丢弃时，靠 cacheDir 里的
 * vpn_start_params.json 回退，但那份文件只接受"3 分钟内、且 configPath 逐字相等"。
 * 进程被系统回收后由 OS 重新拉起扩展时往往已超过 3 分钟 → 扩展硬拒绝恢复，
 * 隧道再也起不来（用户表现为"连着连着就断了，之后再也连不上"）。
 *
 * 把同一份三元组也写进 preferences（同 App 同沙箱，扩展进程读得到），并附带
 * configPath：扩展据此可在文件之外找到**本次**会话的参数，仍然不猜任何默认值，
 * 防泄漏红线不变。
 */
export class AppRoutingSnapshot {
  appRoutingMode: string = '';
  appRoutingPackagesJson: string = '';
  appRoutingNeedsReview: boolean = false;
  /** 本次连接实际使用的配置文件路径：只有逐字相等才允许复用，防止串用别的会话 */
  configPath: string = '';
  ts: number = 0;
}

/**
 * 设置的**字段级写入**入口：mutator 拿到的是「刚从盘上读出来的最新设置」，
 * 在它上面改，改完立刻落盘。
 *
 * 返回值语义（2026-10-27 补）：
 *  · `void` / `true`  ⇒ 正常写盘；
 *  · 显式 `false`    ⇒ **本次不写**（mutator 判定「没什么可写」或「并发冲突，放弃」）。
 *   没有这个出口，页面级的并发三向比较只能「先 load 预检、再 patch 写」—— 预检与写入
 *   之间又有窗口，且冲突时仍白发一次整份写（把别人刚写的字段按同值重写一遍）。
 */
export type SettingsMutator = (settings: AppSettings) => boolean | void;

/** 测速结论分片里的单条记录（只有测速路径拥有的字段） */
class NodeSortLatencyEntry {
  name: string = '';
  latency: number = -2;
  failKind: string = '';
}

/** 测速结论分片（latency / failKind / 手动顺序 / 批次时间戳） */
class NodeSortLatencyShard {
  testedAt: number = 0;
  mode: string = NodeSortModes.DEFAULT;
  order: string[] = [];
  records: NodeSortLatencyEntry[] = [];
}

/** 记账分片里的单条记录（只有自动切换记账拥有的字段） */
class NodeSortStatsEntry {
  name: string = '';
  failCount: number = 0;
  lastOk: boolean = false;
}

/** 记账分片（failCount / lastOk） */
class NodeSortStatsShard {
  records: NodeSortStatsEntry[] = [];
}

/** 两个分片的容器（读一次盘拿全） */
class NodeSortShards {
  latency: NodeSortLatencyShard = new NodeSortLatencyShard();
  stats: NodeSortStatsShard = new NodeSortStatsShard();
}

export class SettingsService {
  private static store: preferences.Preferences | null = null;
  /**
   * 进程内设置缓存（2026-10-27 写放大整治）：
   * 读走缓存、写走「内存 → 合并 → 防抖落盘」，避免"每个动作都读盘 + 每个动作都 flush"。
   * 不变量：`cache` 永远等于「最新意图」，`pending` 是尚未落盘的那一份。
   */
  private static cache: AppSettings | null = null;
  private static pending: AppSettings | null = null;
  private static flushTimer: number = -1;
  /** 防抖窗口：UI 连点/批量开关只落一次盘；进后台/退出前由 flushNow 强制刷。 */
  private static readonly FLUSH_DELAY_MS: number = 300;
  /** 本进程内「双轨 provider」开关的上一次生效值：用于识别开关变化并同步落盘仓闸门 */
  private static lastRawProviderFlag: boolean = false;

  static async init(context: Context): Promise<void> {
    SettingsService.store = await preferences.getPreferences(context, PREF_NAME);
  }

  /** 同步读缓存（仅 UI 展示用；未经 init 时返回 null，调用方必须回退）。 */
  static peek(): AppSettings | null {
    const c = SettingsService.cache;
    return c === null ? null : AppSettings.fromJson(c.toJson());
  }

  static async load(): Promise<AppSettings> {
    if (SettingsService.store === null) {
      throw new Error('设置服务尚未初始化，已拒绝使用默认应用分流');
    }
    const cached = SettingsService.cache;
    if (cached !== null) {
      const settings = AppSettings.fromJson(cached.toJson());
      settings.nodeSortSnapshot = await SettingsService.loadNodeSortSnapshot();
      SettingsService.syncRawProviderGate(settings.useRawProviderConfig);
      return settings;
    }
    const raw = await SettingsService.store.get(KEY_SETTINGS, '') as string;
    if (raw.length === 0) {
      SettingsService.cache = new AppSettings();
      return new AppSettings();
    }
    try {
      const j = JSON.parse(raw) as AppSettingsJson;
      if (j === null || typeof j !== 'object' || Array.isArray(j)) {
        throw new Error('设置格式无效');
      }
      const settings = AppSettings.fromJson(j);
      // 测速快照**不再**以整单 JSON 里的 nodeSortSnapshot 字段为真源：
      // 它被拆成两个「字段级」分片（测速结论 / 记账），各自只有一个写者。
      // 这里给调用方的仍是**合并视图**（旧形状），所以所有既有读点零改动。
      settings.nodeSortSnapshot = await SettingsService.loadNodeSortSnapshot();
      // 双轨开关是全局闸门：任何一次加载都把持久化值同步给落盘仓，
      // 持久化为关闭 → 顺带清掉历史落盘原文（含进程被杀后残留）。
      SettingsService.syncRawProviderGate(settings.useRawProviderConfig);
      const cacheable = AppSettings.fromJson(settings.toJson());
      cacheable.nodeSortSnapshot = '';
      SettingsService.cache = cacheable;
      return settings;
    } catch (e) {
      // 损坏数据不等同首次安装：保持需要确认，禁止退回 all 自动接管。
      const invalid = new AppSettings();
      invalid.appRoutingMode = '';
      invalid.appRoutingNeedsReview = true;
      SettingsService.cache = AppSettings.fromJson(invalid.toJson());
      return invalid;
    }
  }

  static async save(settings: AppSettings): Promise<void> {
    if (SettingsService.store === null) {
      throw new Error('设置服务尚未初始化，未保存配置');
    }
    // 保存前经 fromJson(toJson()) 归一化：非法值夹取、缺字段补默认，
    // 保证「保存两次 = 同一 JSON」（幂等），且不回写脏值。
    const normalized = AppSettings.fromJson(settings.toJson());
    // 整单 JSON **不再携带测速快照**：快照已拆成两个字段级分片（见
    // KEY_NODE_SORT_LATENCY / KEY_NODE_SORT_STATS）。留着它就等于留了第二份
    // 真源 —— 整单覆盖会把另一个写者的分片盖回旧值（审计 F2 的根因）。
    const stored = normalized.toJson();
    stored.nodeSortSnapshot = '';
    // 内存即真源：先更新缓存与待落盘快照，再由防抖刷盘（同一次 tick 的多次保存合并为一次写）。
    SettingsService.cache = AppSettings.fromJson(stored);
    SettingsService.pending = AppSettings.fromJson(stored);
    SettingsService.scheduleFlush();
    SettingsService.syncRawProviderGate(normalized.useRawProviderConfig);
    // 快照按「谁拥有哪个字段」分别路由：测速结论只在新批次出现时写，
    // 记账只写**相对盘上发生变化**的节点。两者互不覆盖。
    await SettingsService.routeSnapshotWrite(normalized.nodeSortSnapshot);
  }

  /**
   * 字段级写入的**单一入口**：读-改-写在同一次串行操作内完成。
   *
   * mutator 拿到的是**刚从盘上读出来的最新设置**，因此它只改自己关心的字段，
   * 不会把别的写者刚写进去的字段盖回旧值（审计 F2）。
   */
  static async patchSettings(mutator: SettingsMutator): Promise<void> {
    const task = SettingsService.writeChain.then(async (): Promise<void> => {
      const current = await SettingsService.load();
      const verdict = mutator(current);
      // 显式 false = 本次放弃写入（并发冲突 / 无变更）。绝不能退化成「写回原值」：
      // 白发一次整份写既浪费落盘，也会把别处刚写好的字段按本进程的内存形态重写一遍。
      if (verdict === false) {
        return;
      }
      await SettingsService.save(current);
    });
    SettingsService.writeChain = task.then((): void => {}, (): void => {});
    return task;
  }

  /** 设置写入的串行链：避免两个写者同时读-改-写互相穿插 */
  private static writeChain: Promise<void> = Promise.resolve();

  private static scheduleFlush(): void {
    if (SettingsService.flushTimer >= 0) { return; }
    SettingsService.flushTimer = setTimeout((): void => {
      SettingsService.flushTimer = -1;
      SettingsService.flushNow().catch((e: Error): void => {
        AppLogger.warn('SettingsService', `settings flush failed: ${AppLogger.errText(e)}`);
      });
    }, SettingsService.FLUSH_DELAY_MS);
  }

  /**
   * 立即落盘。关键点（进后台 / 退出 / 连接成功）必须显式调用，
   * 保证防抖窗口内不丢用户意图。
   */
  static async flushNow(): Promise<void> {
    if (SettingsService.flushTimer >= 0) {
      clearTimeout(SettingsService.flushTimer);
      SettingsService.flushTimer = -1;
    }
    const p = SettingsService.pending;
    if (p === null || SettingsService.store === null) { return; }
    SettingsService.pending = null;
    await SettingsService.store.put(KEY_SETTINGS, JSON.stringify(p.toJson()));
    await SettingsService.store.flush();
  }

  /**
   * 测速快照**单独写**（字段级写入口，导出让测速路径直接调用）。
   *
   * 只写「测速结论」分片（latency / failKind / 手动顺序），
   * **绝不碰记账分片** —— 记账（failCount / lastOk）属于自动切换那条线，
   * 测速批次无权改它；反之记账那条线也碰不到测速结论。
   * 这条「字段级 + 单一写者」的边界，就是审计 F2 要求的
   * 「后写者把先写者的字段盖回旧值」的根治点。
   */
  static async nodeSortSnapshotWrite(text: string): Promise<void> {
    const shard = new NodeSortLatencyShard();
    const snap = NodeSortSnapshot.fromJsonText(text);
    if (snap !== null) {
      shard.testedAt = snap.testedAt;
      shard.mode = NodeSortModes.normalize(snap.mode);
      shard.order = snap.order.slice();
      for (const r of snap.records) {
        const entry = new NodeSortLatencyEntry();
        entry.name = r.name;
        entry.latency = r.latency;
        entry.failKind = r.failKind;
        shard.records.push(entry);
      }
    }
    await SettingsService.putShard(KEY_NODE_SORT_LATENCY, JSON.stringify(shard));
  }

  /**
   * 记账路径的**单一写入口**（只写记账分片）。
   * 绝不碰测速结论分片 —— 一次连接失败不是测速结论。
   */
  static async saveNodeSortStats(text: string): Promise<void> {
    const shard = new NodeSortStatsShard();
    const snap = NodeSortSnapshot.fromJsonText(text);
    if (snap !== null) {
      for (const r of snap.records) {
        const entry = new NodeSortStatsEntry();
        entry.name = r.name;
        entry.failCount = r.failCount;
        entry.lastOk = r.lastOk;
        shard.records.push(entry);
      }
    }
    await SettingsService.putShard(KEY_NODE_SORT_STATS, JSON.stringify(shard));
  }

  /**
   * 测速快照的**合并视图**（旧形状的 JSON 文本）—— 所有既有读点零改动。
   *
   * 合并规则：测速结论取自「测速结论分片」，记账取自「记账分片」，
   * 同一个节点的两半拼成一条记录。
   */
  static async loadNodeSortSnapshot(): Promise<string> {
    const shards = await SettingsService.readShards();
    if (shards.latency.records.length > 0 || shards.stats.records.length > 0) {
      return SettingsService.mergeShards(shards);
    }
    // 旧装机：整单 JSON 里还留着 nodeSortSnapshot → 迁移一次到分片 key。
    // 迁移后整单里的那份不再被信任（否则它又是一份真源）。
    const legacy = await SettingsService.readLegacySnapshotField();
    if (legacy.length === 0) {
      return '';
    }
    await SettingsService.nodeSortSnapshotWrite(legacy);
    await SettingsService.saveNodeSortStats(legacy);
    return legacy;
  }

  /**
   * 测速地址的**单一真源在测速内核**（`commons/latency/LatencyProbe.effectiveTestUrl`）。
   *
   * ⚠ 这里**刻意不再提供**一份实现：前台批（节点页）、后台批（静默批次）、
   * 生成器 smart 组三处各写一份 URL 口径必然漂移（审计 F12）——
   * 同一份「用户填的 http 到底保不保留」的规则在三处各解释一次，早晚解释不一致。
   * 统一去 LatencyProbe 取；等它成为唯一真源后，删掉旧调用点即可。
   */

  /** 读两个分片（一次读盘拿全） */
  private static async readShards(): Promise<NodeSortShards> {
    const shards = new NodeSortShards();
    if (SettingsService.store === null) {
      return shards;
    }
    const rawLatency = await SettingsService.store.get(KEY_NODE_SORT_LATENCY, '') as string;
    if (rawLatency.length > 0) {
      try {
        const j = JSON.parse(rawLatency) as NodeSortLatencyShard;
        if (j !== null && typeof j === 'object') {
          shards.latency.testedAt = typeof j.testedAt === 'number' ? j.testedAt : 0;
          shards.latency.mode = NodeSortModes.normalize(j.mode);
          if (Array.isArray(j.order)) {
            for (const n of j.order) {
              if (typeof n === 'string' && n.length > 0) {
                shards.latency.order.push(n);
              }
            }
          }
          if (Array.isArray(j.records)) {
            for (const r of j.records) {
              if (r === null || r === undefined || typeof r.name !== 'string' || r.name.length === 0) {
                continue;
              }
              const entry = new NodeSortLatencyEntry();
              entry.name = r.name;
              entry.latency = typeof r.latency === 'number' && Number.isFinite(r.latency) ? r.latency : -2;
              entry.failKind = typeof r.failKind === 'string' && r.failKind.length <= 32 ? r.failKind : '';
              shards.latency.records.push(entry);
            }
          }
        }
      } catch (e) {
        AppLogger.warn(TAG, `node sort latency shard is corrupt: ${AppLogger.errText(e)}`);
      }
    }
    const rawStats = await SettingsService.store.get(KEY_NODE_SORT_STATS, '') as string;
    if (rawStats.length > 0) {
      try {
        const j = JSON.parse(rawStats) as NodeSortStatsShard;
        if (j !== null && typeof j === 'object' && Array.isArray(j.records)) {
          for (const r of j.records) {
            if (r === null || r === undefined || typeof r.name !== 'string' || r.name.length === 0) {
              continue;
            }
            const entry = new NodeSortStatsEntry();
            entry.name = r.name;
            entry.failCount = typeof r.failCount === 'number' && r.failCount >= 0 ? Math.floor(r.failCount) : 0;
            entry.lastOk = r.lastOk === true;
            shards.stats.records.push(entry);
          }
        }
      } catch (e) {
        AppLogger.warn(TAG, `node sort stats shard is corrupt: ${AppLogger.errText(e)}`);
      }
    }
    return shards;
  }

  /** 两个分片 → 旧形状的快照 JSON（读点零改动） */
  private static mergeShards(shards: NodeSortShards): string {
    const snap = new NodeSortSnapshot();
    snap.testedAt = shards.latency.testedAt;
    snap.mode = shards.latency.mode;
    snap.order = shards.latency.order.slice();
    const statsByName = new Map<string, NodeSortStatsEntry>();
    for (const s of shards.stats.records) {
      statsByName.set(s.name, s);
    }
    const seen = new Set<string>();
    for (const l of shards.latency.records) {
      seen.add(l.name);
      const rec = new NodeLatencyRecord();
      rec.name = l.name;
      rec.latency = l.latency;
      rec.failKind = l.failKind;
      const st = statsByName.get(l.name);
      if (st !== undefined) {
        rec.failCount = st.failCount;
        rec.lastOk = st.lastOk;
      }
      snap.records.push(rec);
    }
    // 只有记账、没有测速结论的节点也要出现在视图里（记账先于测速发生）。
    for (const s of shards.stats.records) {
      if (seen.has(s.name)) {
        continue;
      }
      const rec = new NodeLatencyRecord();
      rec.name = s.name;
      rec.latency = -2;
      rec.failKind = '';
      rec.failCount = s.failCount;
      rec.lastOk = s.lastOk;
      snap.records.push(rec);
    }
    return snap.toJsonText();
  }

  /**
   * 路由快照**单独写**（字段级写入口，导出让外部写者直接调用）。
   *
   * 用途：自动切换记账那条线（ConnectionOrchestrator）把「一次连接失败」写进
   * 快照时，**只调这一个入口**，不再把整份快照塞回 AppSettings 再整单覆盖 ——
   * 整单覆盖会把测速路径刚写进去的新结论整片盖掉（审计 F2/F4）。
   *
   * 分派规则（按字段所有权）：
   *  - 测速结论（latency / failKind）：只有携带的批次**比盘上更新**才写；
   *  - 记账（failCount / lastOk）：只写**相对盘上真的变了**的节点。
   * 两类字段各有各的主人，互不覆盖。
   */
  static async routeSnapshotWrite(carriedText: string): Promise<void> {
    if (carriedText.length === 0) {
      return;
    }
    const carried = NodeSortSnapshot.fromJsonText(carriedText);
    if (carried === null) {
      return;
    }
    const shards = await SettingsService.readShards();
    if (carried.testedAt > shards.latency.testedAt) {
      const shard = new NodeSortLatencyShard();
      shard.testedAt = carried.testedAt;
      shard.mode = NodeSortModes.normalize(carried.mode);
      shard.order = carried.order.slice();
      for (const r of carried.records) {
        const entry = new NodeSortLatencyEntry();
        entry.name = r.name;
        entry.latency = r.latency;
        entry.failKind = r.failKind;
        shard.records.push(entry);
      }
      await SettingsService.putShard(KEY_NODE_SORT_LATENCY, JSON.stringify(shard));
    }
    const changed = SettingsService.changedStatsEntries(shards.stats, carried);
    if (changed.length > 0) {
      for (const entry of changed) {
        let replaced = false;
        for (const cur of shards.stats.records) {
          if (cur.name === entry.name) {
            cur.failCount = entry.failCount;
            cur.lastOk = entry.lastOk;
            replaced = true;
            break;
          }
        }
        if (!replaced) {
          shards.stats.records.push(entry);
        }
      }
      await SettingsService.putShard(KEY_NODE_SORT_STATS, JSON.stringify(shards.stats));
    }
  }

  /** 记账分片里「相对盘上真的变了」的条目 */
  private static changedStatsEntries(current: NodeSortStatsShard, carried: NodeSortSnapshot): NodeSortStatsEntry[] {
    const out: NodeSortStatsEntry[] = [];
    for (const r of carried.records) {
      const entry = new NodeSortStatsEntry();
      entry.name = r.name;
      entry.failCount = r.failCount;
      entry.lastOk = r.lastOk;
      let found = false;
      for (const cur of current.records) {
        if (cur.name === r.name) {
          found = true;
          if (cur.failCount !== r.failCount || cur.lastOk !== r.lastOk) {
            out.push(entry);
          }
          break;
        }
      }
      if (!found) {
        // 新出现的节点：只有真的记了东西才写（failCount=0 且从未成功 = 无信息）。
        if (r.failCount > 0 || r.lastOk) {
          out.push(entry);
        }
      }
    }
    return out;
  }

  /** 读整单 JSON 里那个**已废弃**的 nodeSortSnapshot 字段（只用于旧装机迁移） */
  private static async readLegacySnapshotField(): Promise<string> {
    if (SettingsService.store === null) {
      return '';
    }
    const raw = await SettingsService.store.get(KEY_SETTINGS, '') as string;
    if (raw.length === 0) {
      return '';
    }
    try {
      const j = JSON.parse(raw) as AppSettingsJson;
      if (j === null || typeof j !== 'object') {
        return '';
      }
      return typeof j.nodeSortSnapshot === 'string' ? j.nodeSortSnapshot : '';
    } catch (e) {
      return '';
    }
  }

  /** 写一个分片 key */
  private static async putShard(key: string, value: string): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(key, value);
    await SettingsService.store.flush();
  }

  /**
   * 双轨开关的一键切换（设置页/诊断面板调用）：写盘 + 同步落盘仓闸门。
   * 关闭时落盘原文会被删除（凭据不再需要即删干净），返回删除的文件数。
   */
  static async setUseRawProviderConfig(value: boolean): Promise<number> {
    // 字段级写入：只改 useRawProviderConfig 一个字段。
    // 这里从前拿整份 load() 快照再 save(整份)，在“用户在设置页切开关”与“页面/后台同时写节点或网站规则”
    // 相邻时会互相覆盖（审计 F2）；单一入口 + 写锁内判断才是唯一可靠的做法。
    await SettingsService.patchSettings((current: AppSettings): boolean => {
      if (current.useRawProviderConfig === value) {
        return false;
      }
      current.useRawProviderConfig = value;
      return true;
    });
    const removed = RawSubscriptionStore.setEnabled(value);
    AppLogger.info(TAG, `useRawProviderConfig=${value} (raw files removed=${removed})`);
    return removed;
  }

  /**
   * 闸门同步：开启/关闭都只设置标记，**任何分支都不删落盘原文**。
   *
   * 2026-10-22：原文文件同时是「节点定义原文透传」的数据源，与 provider 开关解耦。
   * 之前关闭 provider 会 removeAll() ⇒ 每次冷启动白删一遍、随后又联网补拉，
   * 离线/订阅过期时原文透传直接退化成解析发射（真机日志：
   * `purged 4 raw subscription file(s): raw provider disabled` 之后紧接 backfill）。
   * 要清磁盘只有两个显式入口：删除订阅（remove + drop）与诊断面板的 purgeRawProviders()。
   */
  private static syncRawProviderGate(enabled: boolean): void {
    RawSubscriptionStore.setEnabled(enabled, false);
    SettingsService.lastRawProviderFlag = enabled;
  }

  /** apiSecret 只允许存入系统加密 AssetStore，禁止降级到明文 Preferences。 */
  static async setApiSecret(secret: string): Promise<void> {
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.SECRET, stringToUint8(secret));
    attr.set(asset.Tag.ALIAS, stringToUint8(ASSET_SECRET_KEY));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    // remove 只带 ALIAS：携带 SECRET 等多余 tag 的 remove 在部分版本会参数校验失败且异常被吞，
    // 导致旧值残留、下一次 add 抛 already exists（与 CredentialStore.writeAsset 同口径修复）。
    const removeAttr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    removeAttr.set(asset.Tag.ALIAS, stringToUint8(ASSET_SECRET_KEY));
    try {
      await asset.remove(removeAttr);
    } catch (e) {
      // 首次写入前不存在属正常
    }
    await asset.add(attr);

    // 清除旧版本可能遗留的明文回退值。
    if (SettingsService.store !== null) {
      try {
        await SettingsService.store.delete('api_secret_fallback');
        await SettingsService.store.flush();
      } catch (cleanupError) {
        AppLogger.warn(TAG, `failed to remove legacy api secret fallback: ${AppLogger.errText(cleanupError)}`);
      }
    }
    AppLogger.info(TAG, 'apiSecret stored in asset store');
  }

  static async getApiSecret(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, stringToUint8(ASSET_SECRET_KEY));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: asset.AssetMap[] = await asset.query(query);
      if (results.length === 0) {
        return '';
      }
      const secretVal = results[0].get(asset.Tag.SECRET);
      if (secretVal !== undefined && secretVal instanceof Uint8Array) {
        return uint8ToString(secretVal as Uint8Array);
      }
      return '';
    } catch (e) {
      AppLogger.warn(TAG, `asset store query failed: ${AppLogger.errText(e)}`);
      return '';
    }
  }

  // 本进程快照提交串行化；不是跨进程 CAS，跨进程权威仍由 Extension 生命周期负责。
  private static snapshotWrites: Promise<void> = Promise.resolve();

  /** 仅更新仍属同代、仍有连接意图的运行快照，不重置 phase/generation。 */
  static patchActiveSnapshot(generation: number, nodeName: string, startedAt: number,
    connected: boolean = false): Promise<boolean> {
    const task = SettingsService.snapshotWrites.then(async (): Promise<boolean> => {
      const snap = await SettingsService.loadSnapshot();
      if (snap.sessionGeneration !== generation || !snap.desiredConnected
        || !['connecting', 'connected', 'recovering'].includes(snap.phase)) {
        return false;
      }
      snap.nodeName = nodeName;
      snap.startedAt = startedAt;
      snap.savedAt = Date.now();
      if (connected) { snap.phase = 'connected'; }
      await SettingsService.writeSnapshot(snap);
      return true;
    });
    SettingsService.snapshotWrites = task.then((): void => {}, (): void => {});
    return task;
  }

  /** 连接快照读写（重启恢复） */
  static saveSnapshot(snap: ConnectionSnapshot): Promise<void> {
    const task = SettingsService.snapshotWrites.then((): Promise<void> => SettingsService.writeSnapshot(snap));
    SettingsService.snapshotWrites = task.then((): void => {}, (): void => {});
    return task;
  }

  private static async writeSnapshot(snap: ConnectionSnapshot): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(KEY_SNAPSHOT, JSON.stringify(snap));
    await SettingsService.store.flush();
  }

  static async loadSnapshot(): Promise<ConnectionSnapshot> {
    const snap = new ConnectionSnapshot();
    if (SettingsService.store === null) {
      return snap;
    }
    const raw = await SettingsService.store.get(KEY_SNAPSHOT, '') as string;
    if (raw.length === 0) {
      return snap;
    }
    try {
      const j = JSON.parse(raw) as ConnectionSnapshot;
      snap.desiredConnected = j.desiredConnected;
      snap.nodeName = j.nodeName;
      snap.savedAt = j.savedAt;
      snap.startedAt = typeof j.startedAt === 'number' && j.startedAt > 0 ? j.startedAt : 0;
      // 兼容旧快照：没有 phase 时由 desiredConnected 推导等价相位。
      snap.phase = typeof j.phase === 'string' && j.phase.length > 0
        ? j.phase : (snap.desiredConnected ? 'connected' : 'disconnected');
      // 旧版本快照没有会话代次，按 0 兼容；非法值同样归零，避免陈旧异步任务
      // 利用异常 generation 绕过用户主动停止门禁。
      snap.sessionGeneration = typeof j.sessionGeneration === 'number' && j.sessionGeneration >= 0
        ? Math.floor(j.sessionGeneration) : 0;
    } catch (e) {
      // 快照损坏则视为空
    }
    return snap;
  }

  /**
   * DoH 防投毒固定解析结果的**跨进程持久化缓存**。
   *
   * 动机：DoH 预解析原本只有进程内 Map，应用每次被回收/冷启动都要重新走一遍 DoH
   * （并发 16、预算 6s），这段时间隧道还没建 —— 直接表现为"每次连接都要多等几秒"。
   * 落盘后冷启动可零网络命中，只有真正过期的条目才在后台刷新。
   *
   * 存储格式为 `Record<domain, "ip|timestampMs">`，用扁平字符串规避 ArkTS 严格模式下
   * 的嵌套 JSON 反序列化问题。
   */
  static async loadDohPins(): Promise<Record<string, string>> {
    const empty: Record<string, string> = {};
    if (SettingsService.store === null) {
      return empty;
    }
    try {
      const raw = await SettingsService.store.get(KEY_DOH_PINS, '') as string;
      if (raw.length === 0) {
        return empty;
      }
      const parsed = JSON.parse(raw) as Record<string, string>;
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return empty;
      }
      return parsed;
    } catch (e) {
      // 缓存损坏 = 当作没有缓存：宁可慢一次，也不给内核写错的 hosts
      return empty;
    }
  }

  static async saveDohPins(pins: Record<string, string>): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    try {
      await SettingsService.store.put(KEY_DOH_PINS, JSON.stringify(pins));
      await SettingsService.store.flush();
    } catch (e) {
      AppLogger.warn(TAG, `save doh pins failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 应用分流快照读写（扩展进程被杀后重启时的第三道恢复来源） */
  static async saveAppRoutingSnapshot(snap: AppRoutingSnapshot): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    try {
      await SettingsService.store.put(KEY_ROUTING_SNAPSHOT, JSON.stringify(snap));
      await SettingsService.store.flush();
    } catch (e) {
      AppLogger.warn(TAG, `save app routing snapshot failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 读不到/脏数据一律返回 null（调用方据此维持拒绝，绝不回退默认值）。 */
  static async loadAppRoutingSnapshot(): Promise<AppRoutingSnapshot | null> {
    const snap = new AppRoutingSnapshot();
    if (SettingsService.store === null) {
      return null;
    }
    try {
      const raw = await SettingsService.store.get(KEY_ROUTING_SNAPSHOT, '') as string;
      if (raw.length === 0) {
        return null;
      }
      const j = JSON.parse(raw) as AppRoutingSnapshot;
      if (j === null || typeof j !== 'object') {
        return null;
      }
      if (typeof j.appRoutingMode !== 'string' || typeof j.appRoutingPackagesJson !== 'string'
        || typeof j.appRoutingNeedsReview !== 'boolean' || typeof j.configPath !== 'string'
        || typeof j.ts !== 'number') {
        return null;
      }
      snap.appRoutingMode = j.appRoutingMode;
      snap.appRoutingPackagesJson = j.appRoutingPackagesJson;
      snap.appRoutingNeedsReview = j.appRoutingNeedsReview;
      snap.configPath = j.configPath;
      snap.ts = j.ts;
      return snap;
    } catch (e) {
      return null;
    }
  }

  static async loadSubscriptionFabPosition(): Promise<number[]> {
    if (SettingsService.store === null) {
      return [-1, -1];
    }
    const x = await SettingsService.store.get(KEY_SUBSCRIPTION_FAB_X, -1) as number;
    const y = await SettingsService.store.get(KEY_SUBSCRIPTION_FAB_Y, -1) as number;
    return [x, y];
  }

  static async saveSubscriptionFabPosition(x: number, y: number): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(KEY_SUBSCRIPTION_FAB_X, x);
    await SettingsService.store.put(KEY_SUBSCRIPTION_FAB_Y, y);
    await SettingsService.store.flush();
  }

  static async loadNodeColumns(): Promise<number> {
    if (SettingsService.store === null) {
      return 1;
    }
    const n = await SettingsService.store.get(KEY_NODE_COLUMNS, 1) as number;
    return n === 2 ? 2 : 1;
  }

  static async saveNodeColumns(n: number): Promise<void> {
    if (SettingsService.store === null) {
      return;
    }
    await SettingsService.store.put(KEY_NODE_COLUMNS, n === 2 ? 2 : 1);
    await SettingsService.store.flush();
  }
}

function stringToUint8(s: string): Uint8Array {
  if (typeof s !== 'string') {
    s = s === null || s === undefined ? '' : String(s);
  }
  try {
    // 用最稳定的 encode() 而非较新的单参 encodeInto() 重载，且保证恒返回 Uint8Array
    const out = util.TextEncoder.create('utf-8').encode(s);
    if (out instanceof Uint8Array) {
      return out;
    }
  } catch (e) {
    // 落入兜底
  }
  return new Uint8Array(0);
}

function uint8ToString(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}
