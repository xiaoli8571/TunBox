/**
 * 原始订阅落盘仓 —— 「双轨」架构的 provider 路径（实验特性，默认关闭）
 *
 * 背景：本应用用自研 YAML 子集解析器把订阅内容拆成节点对象，再自己拼回 Mihomo 配置；
 * 解析覆盖不到的地方就会「列表有、内核无」。双轨做法是把**订阅原文**按订阅 id 落盘到
 * 应用私有目录，并在生成的配置里以 `proxy-providers: {type: file}` 交给内核自己解析，
 * 从而与 Mihomo / Clash Verge 等客户端 100% 对齐。解析链保持不动，仍负责列表/测速/诊断。
 *
 * 安全模型（与 AssetStore 封存凭据的策略并存，不破坏它）：
 * 1) 只写应用私有目录（cacheDir/raw_subscriptions），目录 0700、文件 0600（尽可能收紧）；
 * 2) 文件名只含订阅 id（不含订阅名/URL 明文）：raw_<safeId>.yaml；
 * 3) 原文含全部明文凭据，因此必须在「不再需要」时删干净：删除订阅、关闭开关（含启动时
 *    发现持久化为关闭）、孤儿文件（订阅已不存在）都会清理；诊断面板另有手动清理入口；
 * 4) 写入失败绝不抛出、绝不影响原有导入流程（调用方降级为仅解析链并记诊断）。
 *
 * provider `path` 语义（真机无法验证，按最保守可用方式实现，并可一键切换）：
 * - 内核初始化时 HomeDir 被硬编码为 /data/storage/el2/base/haps/entry/cache，
 *   即应用 cacheDir（见 entry/src/main/cpp/tunbox_core_napi.cpp loadCore()）。
 *   Mihomo 对 provider path 的既有约定是「相对路径按 HomeDir 解析、绝对路径原样使用」，
 *   本项目现有配置里的 rule-provider 也已经在用 `path: ./ruleset/xxx.mrs`。
 * - 因此默认选 'relative'（./raw_subscriptions/raw_<id>.yaml）：不依赖 UI 进程与
 *   VPN 扩展进程看到的 cacheDir 字符串完全一致，风险最小。
 * - 若真机复测发现内核只认绝对路径，把下面的 RAW_PROVIDER_PATH_MODE 改成 'absolute'
 *   即可（一行常量，无需改调用方）。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppLogger } from '../utils/AppLogger';
import { ensurePrivateDir, chmodPrivate, privateFs } from './PrivateFileStore';
import { ConfigValidator } from './ConfigValidator';

const TAG = 'RawSubscriptionStore';

/** 落盘子目录名（相对应用 cacheDir） */
export const RAW_SUB_DIR_NAME = 'raw_subscriptions';
/** provider 声明使用的 path 语义：'relative'（相对内核 HomeDir= cacheDir） / 'absolute' */
export const RAW_PROVIDER_PATH_MODE: string = 'relative';
/** 相对路径前缀：与现有 rule-providers 的 './ruleset/...' 写法一致 */
export const RAW_PROVIDER_RELATIVE_PREFIX = './';
/** 单个订阅原文上限：超过则不落盘（内核 provider 也会因过大而拖慢启动） */
export const RAW_SUB_MAX_BYTES = 8 * 1024 * 1024;
/** 读回校验/估算时的读取上限 */
export const RAW_SUB_READ_CAP = 4 * 1024 * 1024;
/** 最小权限位（尽量收紧：目录 0700 / 文件 0600） */
export const RAW_SUB_DIR_MODE = 0o700;
export const RAW_SUB_FILE_MODE = 0o600;
/** provider 名前缀（与节点名/其他 provider 隔离，避免组内重名） */
export const RAW_PROVIDER_NAME_PREFIX = 'raw-';
/** provider 健康检查开关（2026-10-22 起**关闭**）。
 *
 * 为什么关：健康检查是**第二套、不受 App 控制**的测速源 ——
 *  · 它按自己的 interval 周期性打网络，与 App 的 LatencyEngine、组的 url-test 三份并行；
 *  · 它的结果只影响 provider 视图里的「延迟」列，App 界面的延迟全部来自 `/proxies/{name}/delay`；
 *  · https 的 generate_204 在受限出口会 TLS 握手挂起（本仓已因此把测速 URL 统一成 http），
 *    而 provider 的 URL 是**生成配置里的静态值**，没法按节点分化。
 * 关掉它 = 少一套并发源、少一类「不知道谁在打网络」的现场。要恢复请看 git 历史。
 */
export const RAW_PROVIDER_HEALTH_CHECK_ENABLED: boolean = false;
export const RAW_PROVIDER_HEALTH_CHECK_URL = 'https://www.gstatic.com/generate_204';
export const RAW_PROVIDER_HEALTH_CHECK_INTERVAL = 300;

/** 落盘结果（ok=false 时 reason 为中文原因，调用方据此记诊断并降级） */
export class RawWriteResult {
  ok: boolean = false;
  bytes: number = 0;
  filePath: string = '';
  reason: string = '';
}

/** 已落盘的 provider 条目（内存登记表；不含原文，只有路径/字节数/条目估算） */
export class RawProviderEntry {
  subscriptionId: string = '';
  providerName: string = '';
  /** provider 声明里的 path（相对或绝对，取决于 RAW_PROVIDER_PATH_MODE） */
  providerPath: string = '';
  /** 真实文件绝对路径（诊断用） */
  filePath: string = '';
  bytes: number = 0;
  /** 从落盘文件读回并估算的节点条目数（内核侧真实值需真机查询 /providers） */
  nodeEstimate: number = 0;
}

/** 计划产物：给生成器用的 provider 清单 + 账本 */
export class RawProviderPlan {
  entries: RawProviderEntry[] = [];
  stats: RawProviderStats = new RawProviderStats();
}

/** 「双轨 provider」账本（生成配置/诊断共用，任何差额都可见） */
export class RawProviderStats {
  /** 开关是否开启（关闭时为 false，生成结果与现状完全一致） */
  enabled: boolean = false;
  /** 候选 provider 数（登记表内条目） */
  candidates: number = 0;
  /** 实际写入配置的 provider 数 */
  emitted: number = 0;
  /** 因文件缺失而跳过的 provider 数（不生成 use: 引用，避免内核启动失败） */
  missingFiles: number = 0;
  /** 因子订阅已无节点（例如订阅被删）而跳过的数量 */
  orphaned: number = 0;
  /** 因跨订阅节点重名而退回静态发射的数量（provider 里节点名由内核逐字采用，不能改名） */
  nameConflicts: number = 0;
  /** 因「App 侧节点名与原文不一致」而退回静态发射的数量（含冷启动原文未就绪） */
  nameMismatch: number = 0;
  /** path 模式（relative / absolute） */
  pathMode: string = '';
  /** 实际发出的 provider 名（逗号分隔，便于诊断） */
  providerNames: string = '';

  detail(): string {
    const base = `双轨 provider ${this.enabled ? '开' : '关'}：发出 ${this.emitted}/${this.candidates}`
      + `（缺失文件 ${this.missingFiles}，无对应节点 ${this.orphaned}，`
      + `重名回退 ${this.nameConflicts}，名字不一致回退 ${this.nameMismatch}，path=${this.pathMode}）`;
    if (this.missingFiles > 0) {
      // C30（冷启动兜底）：原文文件缺失通常是系统回收了 cacheDir。
      // 此时双轨 provider 会被跳过（配置里不写 use: 引用 → 内核不会因缺文件起不来），
      // 但功能是降级的，必须告诉用户「重新拉一次订阅就能恢复」，而不是静默变慢。
      return `${base}；原文文件缺失（可能被系统清理缓存）：请重新拉取该订阅以恢复双轨 provider`;
    }
    return base;
  }
}

/** 双轨 provider 状态（订阅卡/诊断面板展示） */
export class RawProviderStatus {
  subscriptionId: string = '';
  enabled: boolean = false;
  fileExists: boolean = false;
  /** 原文不是 Clash YAML（不能作为 file provider） */
  ineligible: boolean = false;
  /** 上次落盘失败 */
  failed: boolean = false;
  bytes: number = 0;
  nodeEstimate: number = 0;
  /** 中文一句话状态 */
  label: string = '';
  /** ok / warn / fail（与诊断面板 tone 一致） */
  tone: string = 'ok';
}

/** 订阅 provider 状态持久化值（写入 Subscription.rawProviderState） */
export class RawProviderStates {
  /** 未启用（开关关闭） */
  static readonly OFF: string = 'off';
  /** 原文已落盘且可读回 */
  static readonly READY: string = 'ready';
  /** 原文不是 Clash YAML，无法作为 file provider */
  static readonly INELIGIBLE: string = 'ineligible';
  /** 落盘失败（已降级为仅解析链） */
  static readonly FAILED: string = 'failed';
  /** 开启但文件缺失（可能被清理/写入未完成） */
  static readonly MISSING: string = 'missing';

  static isValid(value: string): boolean {
    return value === '' || value === RawProviderStates.OFF || value === RawProviderStates.READY
      || value === RawProviderStates.INELIGIBLE || value === RawProviderStates.FAILED
      || value === RawProviderStates.MISSING;
  }
}

export class RawSubscriptionStore {
  /** 双轨开关（由 SettingsService.load/save 同步，避免各处各自读设置） */
  static enabled: boolean = false;
  /** 应用私有目录（context.cacheDir），init 前为空 → 所有操作安全空转 */
  private static baseDir: string = '';
  /** 内存登记表（订阅 id → provider 条目） */
  private static registry: RawProviderEntry[] = [];
  /**
   * 最近一次双轨诊断口径（由 SubscriptionService 写入，诊断面板直接读，
   * 无需为了展示而新建服务实例）。
   */
  static lastDiagnosticLine: string = '';

  /** 由 SubscriptionService.init(context) 调用 */
  static init(cacheDir: string): void {
    RawSubscriptionStore.baseDir = cacheDir.length > 0 ? cacheDir : '';
  }

  static isReady(): boolean {
    return RawSubscriptionStore.baseDir.length > 0;
  }

  /** 目录路径（绝对） */
  static dirPath(): string {
    return `${RawSubscriptionStore.baseDir}/${RAW_SUB_DIR_NAME}`;
  }

  /**
   * 同步开关状态。默认**不删文件**（purgeOnDisable=false 语义为常态）—— 落盘原文既是
   * provider 的数据源，也是「节点定义原文透传」的数据源，关开关≠删数据。
   * 只有显式清理入口（诊断面板 purgeRawProviders）才传 purgeOnDisable=true。
   * 返回删除的文件数（常态为 0）。
   */
  static setEnabled(value: boolean, purgeOnDisable: boolean = false): number {
    RawSubscriptionStore.enabled = value;
    if (value || !purgeOnDisable) {
      AppLogger.info(TAG, `raw provider store ${value ? 'enabled' : 'disabled (keep files)'}`);
      return 0;
    }
    return RawSubscriptionStore.removeAll();
  }

  /** 订阅 id → 文件名安全片段（只保留 [A-Za-z0-9_-]，避免路径穿越/特殊字符） */
  static safeId(subscriptionId: string): string {
    const safe = subscriptionId.replace(/[^A-Za-z0-9_-]/g, '');
    if (safe.length === 0) {
      return 'unknown';
    }
    return safe.length > 64 ? safe.substring(0, 64) : safe;
  }

  /** 文件名（只含订阅 id，不含订阅名/URL 明文） */
  static fileNameFor(subscriptionId: string): string {
    return `raw_${RawSubscriptionStore.safeId(subscriptionId)}.yaml`;
  }

  static filePathFor(subscriptionId: string): string {
    return `${RawSubscriptionStore.dirPath()}/${RawSubscriptionStore.fileNameFor(subscriptionId)}`;
  }

  /** provider 名（YAML 映射键 / 代理组 use: 引用） */
  static providerNameFor(subscriptionId: string): string {
    return `${RAW_PROVIDER_NAME_PREFIX}${RawSubscriptionStore.safeId(subscriptionId)}`;
  }

  /** provider 声明的 path（默认相对内核 HomeDir） */
  static providerPathFor(subscriptionId: string): string {
    if (RAW_PROVIDER_PATH_MODE === 'absolute') {
      return RawSubscriptionStore.filePathFor(subscriptionId);
    }
    return `${RAW_PROVIDER_RELATIVE_PREFIX}${RAW_SUB_DIR_NAME}/${RawSubscriptionStore.fileNameFor(subscriptionId)}`;
  }

  /**
   * 写原始订阅内容。任何失败都返回 ok=false（绝不抛出）——调用方必须降级为仅解析链。
   * 顺序：内容大小校验 → 目录(0700) → **落盘前 YAML 校验(C26)** → 原子写(C27)
   *      → 权限收窄(0600) → 回读校验长度。
   *
   * C26（落盘前校验）：provider 原文由 **mihomo 自己**做 YAML 解析，
   *   而 yaml.v3 的 uniqueKeys 默认开启 → 原文里只要有一处同层级重复键，
   *   整个 provider 加载失败（进而可能拖垮整份配置的加载）。
   *   所以落盘前先过 ConfigValidator：能降级的就地降级（重复键取首个），
   *   降级后仍不通过就**拒绝写入**（保留上一份可用原文）并回报原因。
   *
   * C27（原子写）：先写同目录临时文件 → fsync → rename 覆盖。
   *   旧写法是 TRUNC 直写：写到一半失败会把**上一份可用原文**截断成半截文件，
   *   而这份原文含全部明文凭据、是双轨 provider 的唯一来源 —— 截断等于双轨直接报废。
   */
  static writeRaw(subscriptionId: string, content: string): RawWriteResult {
    const result = new RawWriteResult();
    if (!RawSubscriptionStore.isReady()) {
      result.reason = '私有目录未初始化';
      return result;
    }
    if (subscriptionId.length === 0) {
      result.reason = '订阅 id 为空';
      return result;
    }
    if (content.length === 0) {
      result.reason = '订阅原文为空';
      return result;
    }
    if (content.length > RAW_SUB_MAX_BYTES) {
      result.reason = `订阅原文 ${content.length} 字节超过 ${RAW_SUB_MAX_BYTES} 上限`;
      return result;
    }
    const dir = RawSubscriptionStore.dirPath();
    const path = RawSubscriptionStore.filePathFor(subscriptionId);
    // provider 原文由 mihomo 直接做 YAML 解析(双轨 use:),一个控制字符就是
    // 整份拒载(真机报错 "control characters are not allowed")。落盘前先做
    // 与 ClashConfigGenerator.sanitizeControlChars 同规则的清洗(两侧必须保持
    // 一致;不能直接 import 生成器——那会构成模块环)。
    const cleaned = RawSubscriptionStore.stripControlChars(content);
    // C26：落盘前 YAML 校验（重复键等会让内核整份拒载）
    const gate = ConfigValidator.repair(cleaned);
    if (gate.issues.length > 0) {
      AppLogger.warn(TAG, `[raw-gate/${subscriptionId}] ${gate.summary()}`);
    }
    if (!gate.ok) {
      result.reason = `订阅原文 YAML 校验未通过（内核会整份拒载）：${gate.summary()}`;
      return result;
    }
    const payload = gate.degraded && gate.text.length > 0 ? gate.text : cleaned;
    const tmp = `${path}.tmp`;
    try {
      ensurePrivateDir(dir);
      RawSubscriptionStore.tightenMode(dir, RAW_SUB_DIR_MODE);
      // 原子写：临时文件 → fsync → 同目录 rename 覆盖（rename 是原子替换，
      // 失败时旧文件原封不动，绝不出现「半截原文」）
      privateFs.writePrivate(tmp, payload);
      RawSubscriptionStore.tightenMode(tmp, RAW_SUB_FILE_MODE);
      fs.renameSync(tmp, path);
      RawSubscriptionStore.tightenMode(path, RAW_SUB_FILE_MODE);
      const stat = fs.statSync(path);
      if (stat.size <= 0) {
        result.reason = '写入后文件为空';
        return result;
      }
      result.ok = true;
      result.bytes = stat.size;
      result.filePath = path;
      return result;
    } catch (e) {
      // 清理可能残留的临时文件（不影响旧文件）
      try {
        privateFs.remove(tmp);
      } catch (cleanupError) {
        AppLogger.warn(TAG, `raw tmp cleanup failed: ${AppLogger.errText(cleanupError)}`);
      }
      result.reason = AppLogger.errText(e);
      return result;
    }
  }

  /**
   * 与 ClashConfigGenerator.sanitizeControlChars 逐字同规则的本地副本
   * （生成器 import 本模块，反向引用会成环，无法共享实现）。
   * mihomo yaml.v3 对 C0(除\n)、0x7F-0x84、0x86-0x9F 报
   * "control characters are not allowed" 整份拒载：provider 原文由内核直接
   * 解析,故必须与内联链同样净化。规则若改动,两处必须同步
   * （tools/verify-config-sanitize.mjs 有双侧一致性断言）。
   */
  private static stripControlChars(value: string): string {
    let out = '';
    for (let i = 0; i < value.length; i++) {
      const code = value.charCodeAt(i);
      if (code === 0x09 || code === 0x0d) {
        out += ' ';
      } else if (code === 0x0a || (code >= 0x20 && code <= 0x7e) || code >= 0xa0) {
        out += value.charAt(i);
      } else {
        out += '?';
      }
    }
    return out;
  }

  /** 读取落盘原文（上限内）；失败返回空串，绝不抛出 */
  static readRaw(subscriptionId: string): string {
    if (!RawSubscriptionStore.isReady()) {
      return '';
    }
    const read = privateFs.readCapped(RawSubscriptionStore.filePathFor(subscriptionId), RAW_SUB_READ_CAP);
    return read.ok ? read.text : '';
  }

  /** 是否已落盘（只探测存在性） */
  static has(subscriptionId: string): boolean {
    if (!RawSubscriptionStore.isReady() || subscriptionId.length === 0) {
      return false;
    }
    return privateFs.exists(RawSubscriptionStore.filePathFor(subscriptionId));
  }

  static sizeOf(subscriptionId: string): number {
    if (!RawSubscriptionStore.has(subscriptionId)) {
      return 0;
    }
    try {
      return fs.statSync(RawSubscriptionStore.filePathFor(subscriptionId)).size;
    } catch (e) {
      return 0;
    }
  }

  /** 删除单个订阅的落盘原文；成功返回 true（同时从登记表移除） */
  static remove(subscriptionId: string): boolean {
    if (!RawSubscriptionStore.isReady()) {
      return false;
    }
    const removed = privateFs.remove(RawSubscriptionStore.filePathFor(subscriptionId));
    RawSubscriptionStore.drop(subscriptionId);
    return removed;
  }

  /** 删除全部落盘原文并清空登记表；返回成功删除数（逐文件独立容错） */
  static removeAll(): number {
    let count = 0;
    for (const name of RawSubscriptionStore.fileNames()) {
      if (privateFs.remove(`${RawSubscriptionStore.dirPath()}/${name}`)) {
        count = count + 1;
      }
    }
    RawSubscriptionStore.registry = [];
    if (count > 0) {
      AppLogger.info(TAG, `removed ${count} raw subscription file(s)`);
    }
    return count;
  }

  /**
   * 删除不属于任何现存订阅的文件（启动时清理：订阅在应用被杀时删除等场景）。
   * knownIds 之外的 raw_*.yaml 一律视为孤儿。
   */
  static removeOrphans(knownIds: string[]): number {
    if (!RawSubscriptionStore.isReady()) {
      return 0;
    }
    const keep = new Set<string>();
    for (const id of knownIds) {
      keep.add(RawSubscriptionStore.fileNameFor(id));
    }
    let count = 0;
    for (const name of RawSubscriptionStore.fileNames()) {
      if (keep.has(name)) {
        continue;
      }
      if (privateFs.remove(`${RawSubscriptionStore.dirPath()}/${name}`)) {
        count = count + 1;
      }
    }
    if (count > 0) {
      AppLogger.info(TAG, `removed ${count} orphan raw subscription file(s)`);
    }
    return count;
  }

  /** 目录内 raw_*.yaml 文件名列表（失败返回空数组） */
  static fileNames(): string[] {
    if (!RawSubscriptionStore.isReady()) {
      return [];
    }
    try {
      const names = fs.listFileSync(RawSubscriptionStore.dirPath());
      const out: string[] = [];
      for (const n of names) {
        if (n.startsWith('raw_') && n.endsWith('.yaml')) {
          out.push(n);
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 落盘原文总占用（字节） */
  static totalBytes(): number {
    let total = 0;
    for (const name of RawSubscriptionStore.fileNames()) {
      try {
        total = total + fs.statSync(`${RawSubscriptionStore.dirPath()}/${name}`).size;
      } catch (e) {
        // 单文件统计失败不影响总量
      }
    }
    return total;
  }

  // ── 登记表（供生成器 / 诊断使用；不含原文） ────────────────────────────

  static upsert(entry: RawProviderEntry): void {
    const next: RawProviderEntry[] = [];
    for (const e of RawSubscriptionStore.registry) {
      if (e.subscriptionId !== entry.subscriptionId) {
        next.push(e);
      }
    }
    next.push(entry);
    RawSubscriptionStore.registry = next;
  }

  static drop(subscriptionId: string): void {
    RawSubscriptionStore.registry =
      RawSubscriptionStore.registry.filter((e: RawProviderEntry) => e.subscriptionId !== subscriptionId);
  }

  static clearRegistry(): void {
    RawSubscriptionStore.registry = [];
  }

  static entryFor(subscriptionId: string): RawProviderEntry | null {
    const found = RawSubscriptionStore.registry.find(
      (e: RawProviderEntry) => e.subscriptionId === subscriptionId);
    return found === undefined ? null : found;
  }

  static registered(): RawProviderEntry[] {
    return RawSubscriptionStore.registry;
  }

  /**
   * 可用于生成 `use:` 的 provider 条目：登记表非空且文件仍存在。
   * 登记表为空（例如进程刚重启、服务尚未 init）时从磁盘按文件名自愈重建，
   * 避免「开关开着但 provider 一个都没写进配置」。
   */
  static active(): RawProviderEntry[] {
    if (RawSubscriptionStore.registry.length === 0) {
      RawSubscriptionStore.hydrateFromDisk();
    }
    const out: RawProviderEntry[] = [];
    for (const e of RawSubscriptionStore.registry) {
      if (RawSubscriptionStore.has(e.subscriptionId)) {
        out.push(e);
      }
    }
    return out;
  }

  /** 从磁盘重建登记表（文件名即订阅 id；条目数按落盘文件条目估算） */
  private static hydrateFromDisk(): void {
    if (!RawSubscriptionStore.isReady()) {
      return;
    }
    for (const name of RawSubscriptionStore.fileNames()) {
      const id = name.substring('raw_'.length, name.length - '.yaml'.length);
      if (id.length === 0) {
        continue;
      }
      const entry = new RawProviderEntry();
      entry.subscriptionId = id;
      entry.providerName = RawSubscriptionStore.providerNameFor(id);
      entry.providerPath = RawSubscriptionStore.providerPathFor(id);
      entry.filePath = `${RawSubscriptionStore.dirPath()}/${name}`;
      entry.bytes = RawSubscriptionStore.sizeOf(id);
      entry.nodeEstimate = -1;
      RawSubscriptionStore.upsert(entry);
    }
  }

  /**
   * 登记在册、但磁盘上原文已消失的订阅 id（C30 冷启动兜底的判据）。
   *
   * 典型触发：系统回收了应用 cacheDir（冷启动/长期后台/存储紧张），
   * 原文（含明文凭据）随之消失，而订阅状态还停留在 'ready'。
   * 双轨 provider 会因此被跳过 —— 功能降级但不致命（解析链仍在用），
   * 所以这里给调用方一个明确的「该重新拉取哪些订阅」的清单。
   */
  static missingProviderIds(): string[] {
    const out: string[] = [];
    for (const e of RawSubscriptionStore.registry) {
      if (!RawSubscriptionStore.has(e.subscriptionId)
        && out.indexOf(e.subscriptionId) < 0) {
        out.push(e.subscriptionId);
      }
    }
    return out;
  }

  /** 单订阅 provider 状态（订阅卡 / 诊断面板） */
  static statusFor(subscriptionId: string, recordedState: string): RawProviderStatus {
    const status = new RawProviderStatus();
    status.subscriptionId = subscriptionId;
    status.enabled = RawSubscriptionStore.enabled;
    if (!status.enabled) {
      status.label = 'provider 关闭（双轨未启用）';
      return status;
    }
    const exists = RawSubscriptionStore.has(subscriptionId);
    status.fileExists = exists;
    status.bytes = exists ? RawSubscriptionStore.sizeOf(subscriptionId) : 0;
    status.ineligible = recordedState === RawProviderStates.INELIGIBLE;
    status.failed = recordedState === RawProviderStates.FAILED;
    if (exists) {
      status.nodeEstimate = RawSubscriptionStore.estimateNodes(subscriptionId);
      status.label = `provider 就绪（读回条目估算 ${status.nodeEstimate}，${status.bytes} 字节）`;
      status.tone = 'ok';
      return status;
    }
    if (status.ineligible) {
      status.label = 'provider 不适用：原文不是 Clash YAML（内核只认带 proxies 的 YAML）';
      status.tone = 'warn';
      return status;
    }
    if (status.failed) {
      status.label = 'provider 落盘失败，已降级为仅解析链（节点仍保留）';
      status.tone = 'warn';
      return status;
    }
    status.label = 'provider 文件缺失：请重新刷新该订阅（节点仍保留在列表中）';
    status.tone = 'warn';
    return status;
  }

  /** 落盘文件的节点条目估算（用 YAML 条目计数，不含内核侧真实值） */
  static estimateNodes(subscriptionId: string): number {
    const entry = RawSubscriptionStore.entryFor(subscriptionId);
    if (entry !== null && entry.nodeEstimate >= 0) {
      return entry.nodeEstimate;
    }
    return -1;
  }

  /** 诊断面板用一句话总览 */
  static summary(): string {
    const files = RawSubscriptionStore.fileNames();
    const words = `双轨 provider ${RawSubscriptionStore.enabled ? '已开启' : '已关闭'}`
      + `，落盘文件 ${files.length} 个 / ${RawSubscriptionStore.totalBytes()} 字节`
      + `，path 模式 ${RAW_PROVIDER_PATH_MODE}`;
    return words;
  }

  /** 权限位收窄（失败不致命：沙箱内文件仍受应用隔离保护） */
  private static tightenMode(path: string, mode: number): void {
    try {
      chmodPrivate(path, mode);
    } catch (e) {
      AppLogger.warn(TAG, `chmod ${mode.toString(8)} failed for ${path}`);
    }
  }
}
