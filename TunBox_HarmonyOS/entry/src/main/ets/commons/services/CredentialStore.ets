/**
 * 节点/订阅敏感凭据安全存储（HarmonyOS AssetStore 封装）
 * 先例：SettingsService.setApiSecret/getApiSecret（@kit.AssetStoreKit）
 *
 * 设计要点
 * 1) 元数据留在 preferences，凭据单独进 AssetStore，键空间与明文完全分离。
 * 2) alias 稳定：节点 "tunbox_node|<nodeId>|<field>"，订阅 "tunbox_sub|<subId>|headerValue"。
 *    nodeId = SubscriptionService.nodeKey（subscriptionId|server|port|原名），跨刷新稳定。
 * 3) 读取回退：Asset 中不存在时由调用方传入 fallback（历史明文 / 一次性 rawUri），
 *    且不因读取失败而抛错（返回 fallback）。
 * 4) 一次性迁移：canonicalize() 回读校验成功后才通知调用方清除明文；失败保留明文并记录。
 * 5) 幂等：迁移标记 "migration_v1_done" 只影响是否重复清除明文，
 *    而加密写入本身是 SET 语义（remove 成功/失败均 add），重复启动或重复迁移不产生脏数据。
 */
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { ProxyNode } from '../models/ProxyNode';

export const CRED_PREF_NAME = 'tunbox_credentials';

/**
 * 节点凭据字段（全部只允许存 AssetStore）。
 *
 * rawTemplate 不在此列（2026-10 真机日志：130 节点订阅页加载 4s，canonicalize
 * 待确认字段 [rawTemplate=124] 全部命中它）。理由：
 *  1) 它由 YamlMerger.buildRawTemplate 构造，构造期就剔除全部凭据键
 *     （uuid/password/protocol-param/obfs-param/obfs-password），本来就不敏感；
 *  2) nodesToJson 从不清空它 —— 它**一直明文存在 preferences 里**，同时写进
 *     AssetStore 只是白费 124 个别名 + 124 次逐条读取，还拖慢每次启动；
 *  3) 它可到 8192 字符，一旦超过 900 字节就触发分片（512 字符/片 ≈ 16 次写 + 16 次读）。
 * 若未来确认它可能内嵌凭据，再把 rawTemplate 整体放回此列表即可。
 */
export const NODE_CRED_FIELDS: string[] = [
  'password', 'uuid', 'protocolParam', 'obfsParam', 'extraOpts', 'rawUri'
];
/** 订阅凭据字段（自定义请求头，等价于订阅鉴权 token） */
export const SUB_CRED_FIELD = 'headerValue';

export const MIGRATION_FLAG_KEY = 'migration_v1_done';

const ASSET_SERVICE = 'tunbox_service';
const NODE_ALIAS_PREFIX = 'tunbox_node';
const SUB_ALIAS_PREFIX = 'tunbox_sub';
/** 探测 alias 的一个不可能与真实凭据重名的哨兵键（用于判断 AssetStore 是否可用） */
const PROBE_ALIAS = 'tunbox_probe';
/** 迁移/落盘统计（不含任何凭据值，可安全记录日志） */
export class CredentialMigrationReport {
  migratedNodes: number = 0;
  migratedFields: number = 0;
  migratedSubscriptions: number = 0;
  /** 本次新增（Asset 中原本不存在）的项 */
  addedNew: number = 0;
  /** 回读校验失败项：其明文必须保留 */
  failed: number = 0;
  /** 已存在且回读一致，可安全清除明文 */
  alreadyStored: number = 0;
  /**
   * 加密层整体不可用（probe 失败）。此时 failed 仍为 0（没有任何一次写入被尝试），
   * 调用方绝不能把「0 失败」当成「凭据已安全入库」——否则首启会清掉全部明文凭据，
   * 导致重启后 password/uuid 永久缺失、节点在生成配置阶段被整批丢弃（漏洞 A）。
   */
  storeUnavailable: boolean = false;
  /** 失败明细（nodeId|field），用于决定哪些节点仍需保留明文回退源 */
  private failedKeys: Set<string> = new Set<string>();
  /** 已回读校验成功的明细（nodeId|field）：只有这些字段允许清除明文 */
  private storedKeys: Set<string> = new Set<string>();

  markFailed(ownerId: string, field: string): void {
    this.failedKeys.add(`${ownerId}|${field}`);
  }

  markStored(ownerId: string, field: string): void {
    this.storedKeys.add(`${ownerId}|${field}`);
  }

  /** 该字段是否已确认存在于加密层（写入 + 回读校验通过/原值一致） */
  fieldStored(ownerId: string, field: string): boolean {
    return this.storedKeys.has(`${ownerId}|${field}`);
  }

  /** 该节点的该字段是否迁移失败（失败 → 不得清除明文） */
  fieldFailed(nodeId: string, field: string): boolean {
    return this.failedKeys.has(`${nodeId}|${field}`);
  }

  /** 节点是否有任意字段失败 */
  nodeHasFailure(nodeId: string): boolean {
    for (const k of this.failedKeys) {
      if (k.startsWith(`${nodeId}|`)) {
        return true;
      }
    }
    return false;
  }
}

/** 节点凭据三态（Asset 优先，缺失回退一次性 rawUri） */
export class NodeCredentialValues {
  password: string = '';
  uuid: string = '';
  protocolParam: string = '';
  obfsParam: string = '';
  extraOpts: string = '';
  rawTemplate: string = '';
  rawUri: string = '';
}

/** 单条凭据读取结果：found=false 表示 Asset 中没有（调用方应回退） */
class CredentialRead {
  found: boolean = false;
  value: string = '';
}

export class CredentialStore {
  private static available: boolean = false;
  /** 用于幂等与"首次启动"判定：在写入任何 Asset 项之前读取 */
  private static flagPresentOnEntry: boolean = false;
  private static probed: boolean = false;

  /**
   * 大字段分片长度（字符）。必须让 UTF-8 编码后的字节数远离 SDK 的 SECRET 上限：
   * 单字符最多 3 字节（BMP）或 4 字节（增补平面，本字段值以 ASCII 为主），
   * 取 512 字符 → 最坏约 2KB，仍留有余量；相比原先的 200 字符把 IPC 次数压到 1/2.5。
   */
  private static readonly CHUNK_CHARS: number = 512;

  /** AI-7：为指定的 alias 集合生成透明读回缓存，测试可在构造前替换（wiring point） */
  static makeCache(): Map<string, string> {
    return new Map<string, string>();
  }

  /** 构造仅含 ALIAS 的 remove 参数：remove 携带 SECRET 等多余 tag 在部分版本会参数校验失败且异常被吞，导致旧值残留 */
  private static removeAttrOf(alias: string): asset.AssetMap {
    const removeAttr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    removeAttr.set(asset.Tag.ALIAS, stringToUint8(alias));
    return removeAttr;
  }

  /** 探测 AssetStore 可用性（只写一个哨兵 alias，不影响真实凭据） */
  static async probe(): Promise<boolean> {
    if (CredentialStore.probed) {
      return CredentialStore.available;
    }
    CredentialStore.probed = true;
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.ALIAS, stringToUint8(PROBE_ALIAS));
    attr.set(asset.Tag.SECRET, stringToUint8('1'));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    const removeAttr = CredentialStore.removeAttrOf(PROBE_ALIAS);
    try {
      // 哨兵自愈：上次运行中途被杀或清理失败会留下哨兵，本次 add 会抛 "The asset already exists."。
      // 该错误曾把「实际可用」的 AssetStore 误判为不可用 → 导入时全部节点凭据保存失败（保存失败 N）。
      const existing = await CredentialStore.readAsset(PROBE_ALIAS);
      if (existing.found && existing.value === '1') {
        // 残留哨兵能完整读回，本身即证明 AssetStore 可用
        CredentialStore.available = true;
        try {
          await asset.remove(removeAttr);
        } catch (e) {
          // 清理失败不影响可用性结论；下次 probe 会再次自愈
        }
      } else {
        try {
          await asset.remove(removeAttr);
        } catch (e) {
          // 哨兵不存在属正常
        }
        try {
          await asset.add(attr);
        } catch (addErr) {
          // already-exists 兜底：清掉残留后重试一次
          await asset.remove(removeAttr);
          await asset.add(attr);
        }
        const read = await CredentialStore.readAsset(PROBE_ALIAS);
        CredentialStore.available = read.found && read.value === '1';
        try {
          await asset.remove(removeAttr);
        } catch (e) {
          // 探测项清除失败无影响（值恒为 '1'，非凭据；下次 probe 先自愈）
        }
      }
    } catch (e) {
      CredentialStore.available = false;
      AppLoggerSafe(`credential store probe failed: ${errText(e)}`);
    }
    if (!CredentialStore.available) {
      AppLoggerSafe('asset store unavailable: credentials will NOT be persisted in plaintext');
    }
    return CredentialStore.available;
  }

  /**
   * 迁移标记读取。必须在任何 Asset 写入之前调用，用于判定"首次启动"，
   * 否则下一次运行时写入会与本次写入不可区分（幂等检测失效）。
   */
  static async loadMigrationFlag(): Promise<void> {
    // 迁移标记的读写必须落在**同一个**存储里。历史 bug：写入方 markMigrationDone
    // 用 preferences（credStore.put），这里却从 Asset 读 —— 永远读不到，导致
    // isFirstRun() 恒为 true → sealPlaintext（130 节点循环）**每次启动都重跑**。
    // 统一从 Asset 读：写入方也改用 writeAsset（见 markMigrationFlagInAsset），
    // 跨进程一致，且天然随"清理数据"一起清除。
    const read = await CredentialStore.readAsset(MIGRATION_FLAG_KEY);
    CredentialStore.flagPresentOnEntry = read.found;
  }

  static isFirstRun(): boolean {
    return !CredentialStore.flagPresentOnEntry;
  }

  /** 迁移标记写入（与 loadMigrationFlag 同一存储：Asset） */
  static async markMigrationFlagInAsset(): Promise<void> {
    try {
      await CredentialStore.writeAsset(MIGRATION_FLAG_KEY, '1');
    } catch (e) {
      // 写失败则下次仍会重跑迁移：幂等、安全，只是慢一次
      AppLoggerSafe(`migration flag write failed: ${errText(e)}`);
    }
  }

  /**
   * 一次性迁移核心：把节点/订阅凭据（加密写入 + 回读校验）规范化到 AssetStore。
   * 返回报告；调用方仅在 failed === 0 时清除明文 preferences。
   * 参数 quickExit：当 Asset 中该 alias 已存在且值一致时跳过（幂等快速路径）。
   *
   * 性能关键：整个流程只做「1 次全量读 + 仅缺失项写入 + 1 次批量回读」，
   * 绝不逐字段读回（70 节点 × 4 字段的逐条 IPC 曾把每次 init 拖到数秒）。
   */
  static async canonicalize(nodes: ProxyNode[], subscriptions: SubscriptionCredentialSource[],
    quickExit: boolean): Promise<CredentialMigrationReport> {
    const report = new CredentialMigrationReport();
    if (!CredentialStore.probed) {
      await CredentialStore.probe();
    }
    if (!CredentialStore.available) {
      // Asset 完全不可用：绝不写明文，也不清明文，交由调用方记录。
      // 显式标记 storeUnavailable：调用方不得把 failed===0 当成「已安全入库」。
      report.storeUnavailable = true;
      AppLoggerSafe('asset store unavailable: credential migration skipped (plaintext preserved)');
      return report;
    }

    const pending: PendingCredentialWrite[] = [];
    // Never count a process-local cache hit as an Asset read-back confirmation.
    const planField = (ownerId: string, field: string, value: string, alias: string): boolean => {
      // 空值不入库也不计数（空凭据无意义，且部分固件对空 SECRET 拒绝）
      if (value.length === 0) {
        return true;
      }
      const item = new PendingCredentialWrite();
      item.ownerId = ownerId;
      item.field = field;
      item.alias = alias;
      item.value = value;
      pending.push(item);
      report.migratedFields += 1;
      return true;
    };

    for (const n of nodes) {
      const nodeId: string = nodeCredentialId(n);
      if (nodeId.length === 0) {
        continue;
      }
      // 模型字段理论恒为 string，此处防御性收敛，防止历史数据/解析异常引入非 string 值
      // rawTemplate 刻意不在此列：构造期已剔除凭据键（见 NODE_CRED_FIELDS 注释），
      // 且一直明文存于 preferences（nodesToJson 不清它）——写进 AssetStore 只是白费
      // 别名与逐条 IPC（真机实测：130 节点 = 124 个多余的 rawTemplate 别名）。
      const values: string[] = [
        typeof n.password === 'string' ? n.password : '',
        typeof n.uuid === 'string' ? n.uuid : '',
        typeof n.protocolParam === 'string' ? n.protocolParam : '',
        typeof n.obfsParam === 'string' ? n.obfsParam : '',
        n.extraOpts ?? '', n.rawUri ?? ''
      ];
      for (let i = 0; i < NODE_CRED_FIELDS.length; i++) {
        planField(nodeId, NODE_CRED_FIELDS[i], values[i], nodeAlias(nodeId, NODE_CRED_FIELDS[i]));
      }
    }

    for (const s of subscriptions) {
      if (s.id.length === 0 || s.headerValue.length === 0) {
        continue;
      }
      planField(s.id, SUB_CRED_FIELD, s.headerValue, subAlias(s.id));
    }

    // 一次批量读（1 次 IPC）作为"已入库"的权威判据。
    //
    // 性能红线（2026-10 线上回归）：此前这里对**每个字段**串行做
    // read → 可能 write → read，70 节点 × 7 字段 ≈ 500~1000 次串行 IPC，
    // 而 canonicalize 跑在 doInit() 里、订阅列表渲染**之前** ——
    // 用户看到的就是"订阅页要等很久才出来"。
    //
    // 关键澄清：批量 asset.query 是**真实的 Asset 读取**，不是进程内缓存，
    // 因此把它当作入库确认并不违反"绝不把缓存命中当成入库确认"这条安全要求；
    // 真正不能信的是 aliasCache（进程内）。批量查询不可用时（batchQueryUsable
    // !== true）自动降级为逐条精确读，安全语义不变、只是慢路径。
    const bulk = await CredentialStore.loadAllCredentials();
    const bulkAuthoritative = CredentialStore.batchQueryUsable === true;

    const needIo: PendingCredentialWrite[] = [];
    for (const item of pending) {
      // 本进程内已对**同一别名同一值**做过真实 Asset 精确读/写入回读确认：
      // 直接复用那次确认，不再产生 IPC（重复 persist 的整批逐条读就此消失）。
      if (CredentialStore.confirmedInProcess.get(item.alias) === item.value) {
        report.markStored(item.ownerId, item.field);
        report.alreadyStored += 1;
        continue;
      }
      const existing = bulk.get(item.alias);
      if (bulkAuthoritative && existing !== undefined && existing === item.value) {
        // 真实批量读已确认原值一致 → 无需任何逐条 IPC
        report.markStored(item.ownerId, item.field);
        report.alreadyStored += 1;
        CredentialStore.confirmedInProcess.set(item.alias, item.value);
        continue;
      }
      needIo.push(item);
    }

    // 仅对**新增/变更/无法批量确认**的项做精确读写校验；有界并发而非串行。
    // 并发度（2026-10-16 真机回归）：批量查询不可用的固件上每次 asset IPC 实测
    // ~56ms，127 节点一轮"删订阅/刷新"要把全部字段过一遍 needIo —— 并发 8 时
    // 4.5s 起（这正是"删订阅/进订阅页很慢"的主因），提到 24 后墙钟时间约 1/3。
    const CONFIRM_CONCURRENCY = 24;
    for (let i = 0; i < needIo.length; i += CONFIRM_CONCURRENCY) {
      const slice = needIo.slice(i, i + CONFIRM_CONCURRENCY);
      await Promise.all(slice.map(async (item: PendingCredentialWrite): Promise<void> => {
        try {
          let current: string | undefined = undefined;
          if (bulkAuthoritative) {
            current = bulk.get(item.alias);
          } else {
            // 批量查询不可信 → 必须精确读一次（慢路径，仅这类固件走到）
            const read = await CredentialStore.readAsset(item.alias);
            current = read.found ? read.value : undefined;
          }
          if (current !== item.value) {
            await CredentialStore.writeAsset(item.alias, item.value);
            // 写入之后必须精确回读确认，才允许清明文
            const verified = await CredentialStore.readAsset(item.alias);
            if (!verified.found || verified.value !== item.value) {
              throw new Error('asset read-back mismatch');
            }
          }
          // current === item.value 时**不再补一次回读**：上面那次 readAsset 本身就是
          // Asset 真读（不是进程内缓存命中），已经满足"入库确认"的安全要求。
          // 旧实现在这条路上白白多花一倍 IPC —— 批量查询不可用的固件上，
          // 127 节点的一轮落盘要 2×127 次读，是"删订阅慢"的另一半原因。
          report.markStored(item.ownerId, item.field);
          if (current === item.value) {
            report.alreadyStored += 1;
          } else {
            report.addedNew += 1;
          }
          // 记录本进程内的"真读确认"：后续 persist 不再为这个字段花 IPC。
          CredentialStore.confirmedInProcess.set(item.alias, item.value);
          CredentialStore.cachePut(item.alias, item.value);
        } catch (e) {
          report.failed++;
          report.markFailed(item.ownerId, item.field);
          CredentialStore.confirmedInProcess.delete(item.alias);
          CredentialStore.cacheDelete(item.alias);
          AppLoggerSafe(`credential confirmation failed (field=${item.field})`);
        }
      }));
    }
    // 汇总节点级成败：无任何字段失败的节点才算迁移完成
    const failedNodes = new Set<string>();
    for (const n of nodes) {
      for (const f of NODE_CRED_FIELDS) {
        if (report.fieldFailed(nodeCredentialId(n), f)) {
          failedNodes.add(nodeCredentialId(n));
          break;
        }
      }
    }
    for (const n of nodes) {
      const nodeId: string = nodeCredentialId(n);
      if (nodeId.length === 0) {
        continue;
      }
      if (!failedNodes.has(nodeId)) {
        report.migratedNodes += 1;
      }
    }

    for (const s of subscriptions) {
      if (s.id.length === 0 || s.headerValue.length === 0) {
        continue;
      }
      if (!report.fieldFailed(s.id, SUB_CRED_FIELD)) {
        report.migratedSubscriptions += 1;
      }
    }
    // 分字段计数（真机排查用）：加载慢时据此判断是哪个字段把 IPC 次数放大。
    // 只计数、绝不输出任何凭据值。
    const byField = new Map<string, number>();
    for (const item of pending) {
      byField.set(item.field, (byField.get(item.field) ?? 0) + 1);
    }
    const fieldSummary: string[] = [];
    for (const key of byField.keys()) {
      fieldSummary.push(`${key}=${byField.get(key) ?? 0}`);
    }
    AppLoggerSafe(`credential canonicalize: total=${pending.length} confirmed=${report.alreadyStored}`
      + ` wrote=${report.addedNew} failed=${report.failed}`
      + ` bulk=${CredentialStore.batchQueryUsable === true ? 'ok' : 'slow'}`
      + ` [${fieldSummary.join(' ')}]`);
    return report;
  }

  /**
   * 固件能力探测与会话级别名缓存。
   * 部分固件不支持 ReturnType.ALL + SECRET 批量查询（恒报 Batch secret query
   * is not supported）→ 重启后由 hydrateKnownAliases 逐条 ALIAS 回填。
   * 没有本缓存时，每次刷新都会把全部凭据判为「未存储」而整批 remove+add 重写
   * （数百次 IPC，整应用被拖慢）；有了它，未变化的凭据直接跳过读写。
   *
   * 安全约束（2026-10-07 评审修复）：持久化只允许落**别名标记**（哪些 alias
   * 已封存），绝不落凭据值 —— 历史版本把 alias→值 的明文 JSON 写进 preferences
   * （sealed_alias_cache_json），与「凭据只进 AssetStore」的设计红线冲突；
   * 新格式为纯字符串数组，旧格式读取时丢弃值并由调用方立即重写净化。
   */
  private static batchQueryUsable: boolean | null = null;
  private static aliasCache: Map<string, string> = new Map<string, string>();
  /** 会话级全量凭据缓存 + 单飞：避免逐节点调用 nodeCredentials 时重复全表查询 */
  private static bulkCache: Map<string, string> | null = null;
  private static bulkFlight: Promise<Map<string, string>> | null = null;
  /** 已知已封存别名（跨重启的标记集；值一律从 AssetStore 回读，绝不持久化值） */
  private static knownAliases: Set<string> = new Set<string>();
  /** 本进程是否已完成逐条回填（仅批量查询不可用的固件需要） */
  private static aliasHydrated: boolean = false;

  /**
   * 回填作用域（2026-10-16 真机回归修复）。
   *
   * 批量查询不可用的固件上，回填成本 = 逐条 Asset IPC × knownAliases 总数，而
   * knownAliases 是**历史累积**的：真机实测 634 条里当前活跃的只有约 130 条，
   * 其余是历史导入/已删订阅/改过名节点的孤儿别名 —— 冷启动 4.5s 全部由这些
   * 无用的读构成（`[perf] stage1 migration done at +4504ms`）。
   *
   * 调用方（SubscriptionService.doInit）在回填前把"当前还活着的节点/订阅"的
   * 候选别名放进作用域，回填只真读这一部分。null = 不限制（向后兼容）。
   * 纯读侧收窄：绝不删除 Asset 里的任何东西，作用域外的别名仍留在 knownAliases，
   * 被真正用到时由 nodeCredentials 的逐条兜底真读回填（见 pickOrRead）。
   */
  private static hydrateScope: Set<string> | null = null;

  /**
   * 本进程内经**真实 Asset 读 / 写入回读**确认过的值（alias → value）。
   *
   * 与 aliasCache 的本质区别：aliasCache 允许从磁盘别名标记恢复（值未经验证），
   * 这里只由 canonicalize 的精确读、以及写入后的回读成功路径写入。因此命中
   * 等价于"本进程刚刚真读过且一致"，可以直接当作入库确认 —— 同一进程内的重复
   * persist（删订阅 / 刷新订阅 / 改节点）不必再把全部字段重新过一遍逐条 IPC。
   * 安全语义不变：清明文的前提依然是"有真实 Asset 读确认"，只是复用本进程内
   * 已经做过的那次确认。
   */
  private static confirmedInProcess: Map<string, string> = new Map<string, string>();

  /** 设定回填作用域（null = 不限制）。仅影响"启动回填读哪些别名"，不影响写入。 */
  static setHydrateScope(aliases: string[] | null): void {
    CredentialStore.hydrateScope = aliases === null ? null : new Set<string>(aliases);
  }

  /** 维护会话缓存与标记集（所有写路径统一走这里） */
  private static cachePut(alias: string, value: string): void {
    CredentialStore.aliasCache.set(alias, value);
    CredentialStore.knownAliases.add(alias);
    // 全量缓存里可能有该 alias 的旧值：写入后必须失效，否则后续调用
    // （canonicalize / nodeCredentials）会读到本次写入之前的陈旧值。
    if (CredentialStore.bulkCache !== null) {
      CredentialStore.bulkCache.set(alias, value);
    }
  }

  private static cacheDelete(alias: string): void {
    CredentialStore.aliasCache.delete(alias);
    CredentialStore.knownAliases.delete(alias);
    if (CredentialStore.bulkCache !== null) {
      CredentialStore.bulkCache.delete(alias);
    }
  }

  /**
   * 会话缓存持久化(导出)：只导出**别名标记**（JSON 字符串数组），绝不导出值。
   * 仅当本固件批量查询确认为不可用时才需要持久化（导入端据此推断固件能力）；
   * 批量查询可用的固件返回空表，值重启后由一次批量查询恢复。
   * 由 SubscriptionService 在凭据写盘后调用保存。
   */
  static exportAliasCache(): string {
    // 只在**批量查询确认不可用**时才持久化别名标记。
    //
    // 这个前置条件不能省（2026-10 性能回归）：导入端 importAliasCache 会据
    // "存在标记"反推 `batchQueryUsable = false`。若无条件写出全部别名，那么
    // 下一次启动就会把**本来支持批量查询**的固件误判为不支持 → 走
    // hydrateKnownAliases 逐条读（130 节点 ≈ 347 次 IPC，实测约 2.5s），
    // 且同时让 canonicalize 失去批量快路径。表现为"订阅页要等 3~4 秒"。
    // 批量可用的固件返回空表：值重启后由一次批量查询恢复，无需标记。
    if (CredentialStore.batchQueryUsable !== false) {
      return '[]';
    }
    const aliases: string[] = [];
    for (const alias of CredentialStore.knownAliases) {
      aliases.push(alias);
    }
    return JSON.stringify(aliases);
  }

  /**
   * 会话缓存持久化(导入)：恢复已封存**别名标记**；兼容旧格式 [[alias, value], ...]
   * —— 旧的明文值一律丢弃（由调用方立即以新格式重写该键完成净化）。
   */
  static importAliasCache(json: string): void {
    if (json.length === 0) {
      return;
    }
    try {
      const parsed = JSON.parse(json) as Object[];
      if (!Array.isArray(parsed)) {
        return;
      }
      CredentialStore.aliasCache.clear();
      CredentialStore.knownAliases.clear();
      CredentialStore.aliasHydrated = false;
      let count = 0;
      for (const item of parsed) {
        if (typeof item === 'string') {
          CredentialStore.knownAliases.add(item as string);
          count += 1;
        } else if (Array.isArray(item) && (item as Object[]).length === 2
          && typeof (item as Object[])[0] === 'string') {
          // 旧格式（含明文值）：只保留别名，值丢弃
          CredentialStore.knownAliases.add((item as Object[])[0] as string);
          count += 1;
        }
      }
      if (count > 0 && CredentialStore.batchQueryUsable === null) {
        // 有持久化标记 ⇒ 该固件**可能**批量查询不可用。这只是"待验证的怀疑"，
        // 绝不能当成定论：真正支持批量查询的固件也会因为历史版本无条件写出
        // 标记而落到这里。能力必须由**真实查询结果**决定（loadAllCredentials
        // 成功时会把 batchQueryUsable 置为 true，从而自愈历史上的误判）。
        CredentialStore.batchQueryUsable = false;
      }
    } catch (e) {
      // 缓存损坏按空处理，绝不让恢复故障打断启动
    }
  }

  /**
   * 逐条回填已知别名的值（仅批量查询不可用的固件；每进程一次；分片并发）。
   * 值只驻留内存与 AssetStore —— 回填过程本身不写任何持久化。
   */
  private static async hydrateKnownAliases(): Promise<void> {
    if (CredentialStore.aliasHydrated) {
      return;
    }
    CredentialStore.aliasHydrated = true;
    const missing: string[] = [];
    for (const alias of CredentialStore.knownAliases) {
      if (CredentialStore.aliasCache.has(alias)) {
        continue;
      }
      // 回填作用域：只真读"当前还活着的节点/订阅"的候选别名。作用域外的是
      // 历史孤儿别名（已删订阅 / 改名节点 / 旧导入），读它们纯属浪费 ——
      // 真机实测 634 条里活跃只有约 130 条，这一条就是冷启动 4.5s 的根源。
      // 绝不删除：孤儿别名仍留在 knownAliases，被用到时由 pickOrRead 逐条回填。
      if (CredentialStore.hydrateScope !== null && !CredentialStore.hydrateScope.has(alias)) {
        continue;
      }
      missing.push(alias);
    }
    // 并发度：24（同 canonicalize 的 CONFIRM_CONCURRENCY；本固件每次 asset IPC
    // ~56ms，634 别名并发 8 时 4.5s —— 冷启动 stage1 的全部耗时都在这里）
    const CHUNK = 24;
    for (let i = 0; i < missing.length; i += CHUNK) {
      const slice = missing.slice(i, i + CHUNK);
      let reads: CredentialRead[] = [];
      try {
        reads = await Promise.all(slice.map((alias: string): Promise<CredentialRead> =>
          CredentialStore.readAsset(alias)));
      } catch (e) {
        continue; // 本片失败按缺失处理，不打断启动
      }
      for (let j = 0; j < slice.length; j++) {
        if (j < reads.length && reads[j].found && reads[j].value.length > 0) {
          CredentialStore.aliasCache.set(slice[j], reads[j].value);
        }
      }
    }
    AppLoggerSafe(`alias cache hydrated from asset store (${missing.length} alias(es)`
      + `, known ${CredentialStore.knownAliases.size}`
      + `, scope ${CredentialStore.hydrateScope === null ? 'all' : `${CredentialStore.hydrateScope.size}`})`);
  }

  /** 仅节点凭据的规范化入口（ManualNodeStore 等只有节点的调用方使用） */
  static async canonicalizeNodes(nodes: ProxyNode[], quickExit: boolean): Promise<CredentialMigrationReport> {
    return CredentialStore.canonicalize(nodes, [], quickExit);
  }

  /**
   * Asset 单条 SECRET 有长度上限，大字段用"分片 + 清单"存储。
   *
   * 性能（2026-10 回归修复）：原实现按 **200 字符**分片，且每片写完立即
   * 串行回读 —— 8192 字符的 rawTemplate 要 41 次写 + 41 次读（约 82 次 IPC），
   * 乘以节点数后是订阅页加载慢的主因之一。现改为：
   *   1) 分片放大到 CHUNK_CHARS（仍远低于 SDK 上限，留足编码余量）；
   *   2) 写入用有界并发；
   *   3) 回读校验改为**批量一次**（loadAllCredentials 真读），而不是逐片串行。
   * 安全语义不变：清单（NXCHUNK1 指针）只在全部分片确认可读后才发布。
   */
  private static async writeAsset(alias: string, value: string): Promise<void> {
    if (stringToUint8(value).length <= 900 && !value.startsWith('NXCHUNK1:')) {
      await CredentialStore.writeAssetDirect(alias, value);
      return;
    }
    const generation = util.generateRandomUUID();
    const count = Math.ceil(value.length / CredentialStore.CHUNK_CHARS);
    if (count > 4096) {
      throw new Error('credential exceeds secure storage size limit');
    }
    // 分片并发写（有界），避免 41 片串行各付一次 IPC 往返
    const CHUNK_CONCURRENCY = 8;
    for (let base = 0; base < count; base += CHUNK_CONCURRENCY) {
      const writes: Promise<void>[] = [];
      for (let i = base; i < Math.min(base + CHUNK_CONCURRENCY, count); i++) {
        // JSON encodes isolated surrogate halves losslessly across chunk boundaries.
        const chunk = JSON.stringify(
          value.substring(i * CredentialStore.CHUNK_CHARS, (i + 1) * CredentialStore.CHUNK_CHARS));
        writes.push(CredentialStore.writeAssetDirect(`nxchunk|${generation}|${i}`, chunk));
      }
      await Promise.all(writes);
    }
    // 全部分片写完后逐片回读确认（有界并发，不是逐片串行）；确认通过才发布清单，
    // 否则坏数据永远不会成为当前代（旧代保持可读）。
    const VERIFY_CONCURRENCY = 8;
    for (let base = 0; base < count; base += VERIFY_CONCURRENCY) {
      const checks: Promise<void>[] = [];
      for (let i = base; i < Math.min(base + VERIFY_CONCURRENCY, count); i++) {
        const key = `nxchunk|${generation}|${i}`;
        checks.push(CredentialStore.readAssetDirect(key).then((read: CredentialRead): void => {
          if (!read.found) {
            throw new Error('credential chunk confirmation failed');
          }
        }));
      }
      await Promise.all(checks);
    }
    await CredentialStore.writeAssetDirect(alias, `NXCHUNK1:${generation}:${count}`);
  }

  private static async writeAssetDirect(alias: string, value: string): Promise<void> {
    const attr: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attr.set(asset.Tag.SECRET, stringToUint8(value));
    attr.set(asset.Tag.ALIAS, stringToUint8(alias));
    attr.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    try {
      await asset.add(attr);
    } catch (e) {
      // SDK 24000003 = already exists（重复写入）。绝不为写入而先删旧值：
      // 删和写之间崩溃会直接丢掉最后一份可用凭据。
      // ArkTS 限制：不得用交叉类型/任意类型 throw，故按 Record 取 code 并抛 Error。
      const err = e as Record<string, Object>;
      if (err.code !== 24000003) {
        throw new Error(`asset add failed: ${errText(e)}`);
      }
      const update: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      update.set(asset.Tag.SECRET, stringToUint8(value));
      await asset.update(CredentialStore.removeAttrOf(alias), update);
    }
  }
  /**
   * 单次 asset.query 取回本应用全部凭据（alias → 值）。
   * 批量回填/迁移的唯一读取入口：把 N×M 次逐条 IPC 压成 1 次。
   * 查询异常时返回已收集部分（可能为空 Map），调用方按缺失处理。
   */
  static async loadAllCredentials(): Promise<Map<string, string>> {
    // 注意：**不要**在 batchQueryUsable === false 时直接 return。
    //
    // 历史实现这么做，导致"批量不可用"这个结论一旦被（可能错误地）推断出来
    // 就永久固化：既不再重试，也让 canonicalize 失去批量快路径。2026-10 的
    // 订阅页变慢正是这样形成的（无条件写出的别名标记 → 误判 → 347 次逐条 IPC）。
    //
    // 正确语义：批量查询**每次都真试一次**（1 次 IPC，成本极低），以真实结果
    // 决定能力；失败/空表时才回落到会话缓存，从而可以自愈历史误判。
    //
    // 会话缓存 + 单飞：本方法被 sealPlaintext **逐节点**调用（130 节点 = 130 次），
    // 原先每次都发起一整次全表 asset.query ≈ 数秒 —— 订阅页加载慢的第二个根因。
    // 首个调用真正执行查询并缓存结果；后续调用直接命中缓存（零 IPC）。
    if (CredentialStore.bulkCache !== null) {
      return CredentialStore.bulkCache;
    }
    if (CredentialStore.bulkFlight !== null) {
      return CredentialStore.bulkFlight;
    }
    const flight = CredentialStore.doLoadAllCredentials();
    CredentialStore.bulkFlight = flight;
    try {
      return await flight;
    } finally {
      CredentialStore.bulkFlight = null;
    }
  }

  private static async doLoadAllCredentials(): Promise<Map<string, string>> {
    const out = new Map<string, string>();
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: asset.AssetMap[] = await asset.query(query);
      // 普通项直接入表；chunked 项（NXCHUNK1 指针）单独并发展开 ——
      // 原先在同一个 for 里逐项 await readAsset，分片项多时形成串行长链。
      const chunked: string[] = [];
      for (const m of results) {
        const aliasVal = m.get(asset.Tag.ALIAS);
        const secretVal = m.get(asset.Tag.SECRET);
        if (aliasVal !== undefined && aliasVal instanceof Uint8Array
          && secretVal !== undefined && secretVal instanceof Uint8Array) {
          const alias = uint8ToString(aliasVal as Uint8Array);
          if (alias.startsWith('nxchunk|')) { continue; }
          const value = uint8ToString(secretVal as Uint8Array);
          if (value.startsWith('NXCHUNK1:')) {
            chunked.push(alias);
          } else { out.set(alias, value); }
        }
      }
      if (chunked.length > 0) {
        const EXPAND_CONCURRENCY = 24;
        for (let base = 0; base < chunked.length; base += EXPAND_CONCURRENCY) {
          const slice = chunked.slice(base, base + EXPAND_CONCURRENCY);
          const expanded = await Promise.all(slice.map((alias: string): Promise<CredentialRead> =>
            CredentialStore.readAsset(alias)));
          for (let j = 0; j < slice.length; j++) {
            if (expanded[j].found) { out.set(slice[j], expanded[j].value); }
          }
        }
      }
      if (out.size === 0 && results.length === 0) {
        // 空表：**只有**在"已知存在凭据"时才可判定批量查询不可用。
        // 全新安装（还没有任何凭据）同样是空表，此时绝不能据此断定固件不支持
        // —— 否则一装即误判，之后永远走逐条慢路径。
        const expectData = CredentialStore.knownAliases.size > 0;
        if (expectData) {
          CredentialStore.batchQueryUsable = false;
          for (const pair of CredentialStore.aliasCache) {
            out.set(pair[0], pair[1]);
          }
          await CredentialStore.hydrateKnownAliases();
          for (const pair of CredentialStore.aliasCache) {
            out.set(pair[0], pair[1]);
          }
        } else {
          // 无数据可期待：视为批量查询可用（能力待下次有数据时再确认）
          CredentialStore.batchQueryUsable = true;
        }
      } else {
        // 真实取到了数据 ⇒ 批量查询**确实可用**，这也是历史误判的自愈点
        CredentialStore.batchQueryUsable = true;
        for (const pair of out) {
          CredentialStore.cachePut(pair[0], pair[1]);
        }
        // 填充会话级缓存：后续逐节点调用 nodeCredentials 零 IPC
        CredentialStore.bulkCache = out;
      }
    } catch (e) {
      // 批量查询抛错（该固件确实不支持 ReturnType.ALL + SECRET）：标记不可用，
      // 并用逐条 ALIAS 回填兜底（每进程一次），绝不让读取故障打断启动。
      // 这条路径必须自己 hydrate —— 早先靠顶部的提前 return 保证，而那个提前
      // return 已移除（它正是"一次误判永久固化"的根源）。
      CredentialStore.batchQueryUsable = false;
      for (const pair of CredentialStore.aliasCache) {
        out.set(pair[0], pair[1]);
      }
      await CredentialStore.hydrateKnownAliases();
      for (const pair of CredentialStore.aliasCache) {
        out.set(pair[0], pair[1]);
      }
    }
    return out;
  }

  /**
   * 从预加载的全量凭据表解析节点凭据（同步、零 IPC）。
   * 与 nodeCredentials 同语义，供 initNodes 等批量场景一次加载全部后逐节点取值。
   */
  static nodeCredentialsFromCache(cache: Map<string, string>, nodeId: string,
    fallback: NodeCredentialValues): NodeCredentialValues {
    const out = new NodeCredentialValues();
    out.password = fallback.password;
    out.uuid = fallback.uuid;
    out.protocolParam = fallback.protocolParam;
    out.obfsParam = fallback.obfsParam;
    out.extraOpts = fallback.extraOpts;
    out.rawTemplate = fallback.rawTemplate;
    out.rawUri = fallback.rawUri;
    if (nodeId.length === 0) {
      return out;
    }
    for (let i = 0; i < NODE_CRED_FIELDS.length; i++) {
      const field: string = NODE_CRED_FIELDS[i];
      const stored = cache.get(nodeAlias(nodeId, field));
      if (stored !== undefined && stored.length > 0) {
        if (field === 'password') {
          out.password = stored;
        } else if (field === 'uuid') {
          out.uuid = stored;
        } else if (field === 'protocolParam') {
          out.protocolParam = stored;
        } else if (field === 'obfsParam') {
          out.obfsParam = stored;
        } else if (field === 'extraOpts') {
          out.extraOpts = stored;
        } else if (field === 'rawTemplate') {
          out.rawTemplate = stored;
        } else if (field === 'rawUri') {
          out.rawUri = stored;
        }
      }
    }
    return out;
  }

  private static async readAsset(alias: string): Promise<CredentialRead> {
    const raw = await CredentialStore.readAssetDirect(alias);
    if (!raw.found || !raw.value.startsWith('NXCHUNK1:')) {
      return raw;
    }
    const result = new CredentialRead();
    const parts = raw.value.split(':');
    const count = Number(parts[2]);
    if (parts.length !== 3 || !/^[a-fA-F0-9-]{36}$/.test(parts[1])
      || !Number.isInteger(count) || count < 1 || count > 4096) {
      return result;
    }
    let value = '';
    try {
      // 分片回读用有界并发（原先逐片串行：8192 字符要 16~41 次串行 IPC，
      // 这是订阅页加载慢的直接原因之一）。按索引回填保证顺序不变。
      const parts_: string[] = new Array<string>(count).fill('');
      const READ_CONCURRENCY = 8;
      for (let base = 0; base < count; base += READ_CONCURRENCY) {
        const tasks: Promise<void>[] = [];
        for (let i = base; i < Math.min(base + READ_CONCURRENCY, count); i++) {
          const idx = i;
          tasks.push(CredentialStore.readAssetDirect(`nxchunk|${parts[1]}|${idx}`)
            .then((chunk: CredentialRead): void => {
              if (!chunk.found) {
                throw new Error('chunk missing');
              }
              const text = JSON.parse(chunk.value) as Object;
              if (typeof text !== 'string') {
                throw new Error('chunk decode failed');
              }
              parts_[idx] = text as string;
            }));
        }
        await Promise.all(tasks);
      }
      value = parts_.join('');
    } catch (e) { return result; }
    result.found = true;
    result.value = value;
    return result;
  }

  private static async readAssetDirect(alias: string): Promise<CredentialRead> {
    const out = new CredentialRead();
    try {
      const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
      query.set(asset.Tag.ALIAS, stringToUint8(alias));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const results: asset.AssetMap[] = await asset.query(query);
      if (results.length === 0) {
        return out;
      }
      const secretVal = results[0].get(asset.Tag.SECRET);
      if (secretVal !== undefined && secretVal instanceof Uint8Array) {
        out.found = true;
        out.value = uint8ToString(secretVal as Uint8Array);
      }
      return out;
    } catch (e) {
      // 读取失败按缺失处理（Asset 不可用时由调用方回退一次性来源）
      return out;
    }
  }

  /**
   * 批量透明读取某节点的凭据（连接配置生成/节点列表走这里）。
   * fallback 为一次性来源（rawUri，绝不落盘）。单次 asset.query 取回整个 alias 集合。
   */
  static async nodeCredentials(nodeId: string, fallback: NodeCredentialValues): Promise<NodeCredentialValues> {
    const out = new NodeCredentialValues();
    out.password = fallback.password;
    out.uuid = fallback.uuid;
    out.protocolParam = fallback.protocolParam;
    out.obfsParam = fallback.obfsParam;
    out.extraOpts = fallback.extraOpts;
    out.rawTemplate = fallback.rawTemplate;
    out.rawUri = fallback.rawUri;
    if (nodeId.length === 0) {
      return out;
    }
    if (!CredentialStore.probed) {
      await CredentialStore.probe();
    }
    if (!CredentialStore.available) {
      return out;
    }
    try {
      // 必须复用会话级批量缓存：本方法被 sealPlaintext **逐节点**调用（130 节点
      // = 130 次）。原先每次都发起一整次全表 asset.query（每把 347 条密钥拖回
      // 内存）→ 130 次全表查询 ≈ 数秒，这正是"订阅页加载 3~4 秒"的第二个根因。
      // loadAllCredentials 内部已做单飞与缓存，稳态零额外 IPC。
      const cache = await CredentialStore.loadAllCredentials();
      out.password = await CredentialStore.pickOrRead(cache, nodeAlias(nodeId, 'password'), out.password);
      out.uuid = await CredentialStore.pickOrRead(cache, nodeAlias(nodeId, 'uuid'), out.uuid);
      out.protocolParam = await CredentialStore.pickOrRead(cache, nodeAlias(nodeId, 'protocolParam'),
        out.protocolParam);
      out.obfsParam = await CredentialStore.pickOrRead(cache, nodeAlias(nodeId, 'obfsParam'), out.obfsParam);
      out.extraOpts = await CredentialStore.pickOrRead(cache, nodeAlias(nodeId, 'extraOpts'), out.extraOpts);
      out.rawTemplate = await CredentialStore.pickOrRead(cache, nodeAlias(nodeId, 'rawTemplate'),
        out.rawTemplate);
      out.rawUri = await CredentialStore.pickOrRead(cache, nodeAlias(nodeId, 'rawUri'), out.rawUri);
      return out;
    } catch (e) {
      // 读取异常：整体回退一次性来源，绝不让连接因加密层故障而失败
      return out;
    }
  }

  /**
   * 缓存未命中时的逐条真读兜底（配合回填作用域）。
   *
   * 作用域收窄后，理论上会有少量"活跃但没进作用域"的别名（如调用方在 init 之后
   * 才加载的节点）不在 aliasCache 里 —— 绝不能因此把凭据判为缺失：只要别名标记
   * 说它存在（knownAliases），就真读一次 Asset 并回填缓存。有这条兜底，作用域
   * 收窄是安全的：漏掉的最多多花 1 次 IPC，而不是凭据静默丢失。
   */
  private static async pickOrRead(cache: Map<string, string>, alias: string,
    fallback: string): Promise<string> {
    const cached = cache.get(alias);
    if (cached !== undefined && cached.length > 0) {
      return cached;
    }
    if (!CredentialStore.knownAliases.has(alias)) {
      return fallback;
    }
    try {
      const read = await CredentialStore.readAsset(alias);
      if (read.found && read.value.length > 0) {
        CredentialStore.cachePut(alias, read.value);
        return read.value;
      }
    } catch (e) {
      // 真读失败按缺失处理，调用方回退一次性来源
    }
    return fallback;
  }

  /** 订阅凭据透明读取：Asset 优先，缺失返回 fallback（一次性来源） */
  static async subscriptionCredential(subscriptionId: string, fallback: string): Promise<string> {
    if (subscriptionId.length === 0) {
      return fallback;
    }
    const read = await CredentialStore.readAsset(subAlias(subscriptionId));
    return read.found ? read.value : fallback;
  }

  /** preferences 中是否还残留明文凭据键（迁移后应为 0） */
  static plaintextFieldKeys(): string[] {
    const out: string[] = [];
    for (const f of NODE_CRED_FIELDS) {
      out.push(f);
    }
    out.push(SUB_CRED_FIELD);
    return out;
  }

  /** Asset 不可用时的显式记录（调用方在报错路径使用） */
  static logAssetUnavailable(path: string): void {
    AppLoggerSafe(`asset store unavailable at ${path}: plaintext kept, plaintext credentials not persisted`);
  }
}

/** 批量迁移中待写入的凭据项（只含定位信息，不含多余派生数据） */
class PendingCredentialWrite {
  ownerId: string = '';
  field: string = '';
  alias: string = '';
  value: string = '';
}

/** 订阅凭据来源（避免与偏好模型耦合） */
export class SubscriptionCredentialSource {
  id: string = '';
  headerValue: string = '';
}

/**
 * 节点凭据 alias 的稳定 ID。
 * 用 SubscriptionService.nodeKey 同源信息（订阅|服务器|端口|原名），
 * 跨订阅刷新/节点重排/去重改名保持不变；节点直链导入用 rawUri 兜底。
 */
export function nodeCredentialId(n: ProxyNode): string {
  const base: string = baseNodeName(n.name);
  if (n.subscriptionId.length > 0 && n.server.length > 0 && n.port > 0) {
    return `${n.subscriptionId}|${n.server}|${n.port}|${base}`;
  }
  return n.rawUri;
}

/**
 * 与 SubscriptionService.baseName 同源：去掉去重后缀，还原节点原始名。
 * 两种历史形态都要剥：" #2"（SubscriptionService.ensureUniqueNames 旧形态）
 * 与 " (2)"（YamlMerger.uniqueProxyName 形态，现已统一为该形态）。
 * 只剥其一会让「改名后的节点」与加密层 alias/隐藏清单失配 —— 表现为凭据回填失败
 * （生成配置时整条丢成空行）或已删节点刷新后复活。
 */
export function baseNodeName(name: string): string {
  let out = name;
  let changed = true;
  while (changed) {
    changed = false;
    const next = out.replace(/\s#\d+$/, '').replace(/\s\(\d+\)$/, '');
    if (next !== out) {
      out = next;
      changed = true;
    }
  }
  return out;
}

export function nodeAlias(nodeId: string, field: string): string {
  return `${NODE_ALIAS_PREFIX}|${nodeId}|${field}`;
}

export function subAlias(subscriptionId: string): string {
  return `${SUB_ALIAS_PREFIX}|${subscriptionId}|${SUB_CRED_FIELD}`;
}

/** 日志兜底：避免本模块反向依赖 AppLogger（防止循环引用） */
let logger: ((msg: string) => void) | null = null;

export function setCredentialLogger(fn: (msg: string) => void): void {
  logger = fn;
}

function AppLoggerSafe(msg: string): void {
  if (logger !== null) {
    logger(`[CredentialStore] ${msg}`);
  }
}

/**
 * 错误 → 文本：系统 API 抛出的多是 BusinessError 形态普通对象（{code, message}），
 * 沿用 Error 实例判断会退化成 [object Object]。本模块刻意不依赖 AppLogger（防循环
 * 引用），语义与 AppLogger.errText 保持对齐（消息 + 非零 code + 占位兜底）。
 */
function errText(e: Object): string {
  if (e === null || e === undefined) {
    return '未知错误（错误对象为空）';
  }
  const biz = e as Record<string, Object>;
  const msgVal = biz.message;
  const codeVal = biz.code;
  const msg: string = (typeof msgVal === 'string') ? msgVal as string : '';
  const code: number = (typeof codeVal === 'number') ? codeVal as number : 0;
  if (msg.length > 0) {
    return code !== 0 ? `code=${code} ${msg}` : msg;
  }
  if (code !== 0) {
    return `code=${code}`;
  }
  const text = String(e);
  return (text.length === 0 || text === '[object Object]') ? '未知错误（错误对象不含文本或代码）' : text;
}

function stringToUint8(s: string): Uint8Array {
  if (typeof s !== 'string') {
    // 防御：asset SECRET 要求 napi_object（Uint8Array），绝不能把 undefined 等原始值传进去
    s = s === null || s === undefined ? '' : String(s);
  }
  try {
    // 用最稳定的 encode()（API 8 起可用）而非较新的单参 encodeInto() 重载
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
