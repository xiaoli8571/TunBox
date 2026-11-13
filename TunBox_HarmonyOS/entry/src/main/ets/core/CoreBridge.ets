/**
 * 内核桥（NAPI 封装的 ArkTS 侧接口）
 * 移植自 upstream: TunBox_Android/lib/services/clash_service_native_bridge.dart
 *                android/.../kotlin/bridge/Bridge.kt
 *
 * 底层由 entry/src/main/cpp (NAPI) 加载 libgojni.so（Mihomo c-shared 内核）实现。
 * ABI（cshared_main.go 导出）：
 *   TunBoxInit(homeDir, configFile) / TunBoxStart(configPath, tunFd) /
 *   TunBoxStop() / TunBoxIsRunning() / TunBoxVersion() / TunBoxLastError()
 */
import native from 'libtunbox_core_napi.so';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'CoreBridge';
const CORE_LIB = 'libgojni.so';
/** NAPI 原生模块显式接口（.so 无类型声明，避免 arkts-no-any-unknown） */
interface NativeCoreModule {
  setPhysicalNetId(netId: number): boolean;
  attachTunFd(fd: number, mtu: number): boolean;
  initProtect(): number;
  readProtectSocketFd(): number[];
  setProtectResult(ok: boolean): void;
  setProtectResultForFd(fd: number, seq: number, ok: boolean): void;
  startCore(configPath: string, tunFd: number): Promise<boolean>;
  stopCore(): Promise<void>;
  updateNetwork(dnsJson: string, resetFlows: boolean): Promise<boolean>;
  prepareProfile(text: string): Promise<string>;
  /** mihomo 解析 profile 文件 -> JSON {"config","digest","proxies","proxyGroups","rules","matchRules","error"} */
  getProfileBase(path: string): Promise<string>;
  /** 内核同一 yaml 库解码 -> JSON {"map","error"} */
  decodeYaml(text: string): Promise<string>;
  /**
   * FlClash `Profile.saveFile` + controller `validateProfile` 原生等价物。
   * 返回 JSON {"error":"..."}（空 = 通过；age 键缺失返回原始 AgeSecretKeyRequired）。
   */
  validateProfile(text: string, ageSecretKey: string, profilePath: string): Promise<string>;
  /** FlClash handleGetProfileOutbounds 移植 -> JSON {"proxies","proxy-groups","error"} */
  getProfileOutbounds(path: string): Promise<string>;
  /** 内核侧 utls 取回（浏览器级 TLS 指纹），返回 JSON {"body","error"} */
  fetchText(url: string, userAgent: string, authHeader: string, proxyPort: number): Promise<string>;
  isCoreAlive(): boolean;
  coreVersion(): string;
  lastError(): string;
}
const nativeModule: NativeCoreModule = native as NativeCoreModule;
/** 内核侧取回结果：正文 + 语义响应头（配额 / 条件请求 / 文件名） */
export class CoreFetchResult {
  body: string = '';
  etag: string = '';
  userInfo: string = '';
  disposition: string = '';
  contentType: string = '';
  status: number = 0;
}

/**
 * 内核解析后的 profile 基座（FlClash `ProfileBase` 同构）。
 * `config` 是 RawConfig 的 JSON map（`rule` 已由内核改名为 `rules`）；
 * counts 与 matchRules 供节点计数与 matchTarget 语义使用。
 */
export class CoreProfileBase {
  config: Record<string, Object> = {};
  digest: string = '';
  proxies: number = 0;
  proxyGroups: number = 0;
  rules: number = 0;
  matchRules: string[] = [];
}
const STOP_WAIT_MS = 5000;

/** name/type 投影子项（FlClash core ProfileOutbound）。 */
export class CoreOutboundName {
  name: string = '';
  type: string = '';
}

/** FlClash `ProfileOutbounds` 投影（handleGetProfileOutbounds 的 ArkTS 载体）。 */
export class CoreOutboundsResult {
  proxies: CoreOutboundName[] = [];
  proxyGroups: CoreOutboundName[] = [];
}

export class CoreBridgeImpl {
  private loaded: boolean = false;
  private tunFd: number = -1;
  private pendingStart: Promise<boolean> | null = null;

  async prepareProfile(text: string): Promise<string> {
    const result = await nativeModule.prepareProfile(text);
    if (result.length === 0) {
      throw new Error('内核订阅校验器不可用');
    }
    const reply = JSON.parse(result) as Record<string, Object>;
    const error = reply['error'];
    if (typeof error === 'string' && error.length > 0) {
      throw new Error(error);
    }
    const yaml = reply['yaml'];
    if (typeof yaml !== 'string' || yaml.length === 0) {
      throw new Error('内核未返回有效订阅');
    }
    return yaml;
  }

  /**
   * FlClash `CoreController.getConfig` / `getProfileBase` 同构：内核用 mihomo 自己的
   * 解析器读 profile，返回 map（App 侧拿它做 patch，绝不再做文本级 YAML 手术）。
   * 同时带回 digest 与 proxies/proxyGroups/rules/matchRules（ProfileBase 语义）。
   */
  async getProfileBase(path: string): Promise<CoreProfileBase> {
    const raw = await nativeModule.getProfileBase(path);
    if (raw.length === 0) {
      throw new Error('内核 profile 解析器不可用');
    }
    const reply = JSON.parse(raw) as Record<string, Object>;
    const error = reply['error'];
    if (typeof error === 'string' && error.length > 0) {
      throw new Error(error);
    }
    const config = reply['config'];
    if (config === null || config === undefined || typeof config !== 'object') {
      throw new Error('内核未返回 profile 配置');
    }
    const out = new CoreProfileBase();
    out.config = config as Record<string, Object>;
    const digest = reply['digest'];
    if (typeof digest === 'string') { out.digest = digest; }
    const proxies = reply['proxies'];
    if (typeof proxies === 'number') { out.proxies = proxies; }
    const proxyGroups = reply['proxyGroups'];
    if (typeof proxyGroups === 'number') { out.proxyGroups = proxyGroups; }
    const rules = reply['rules'];
    if (typeof rules === 'number') { out.rules = rules; }
    const matchRules = reply['matchRules'];
    if (Array.isArray(matchRules)) {
      const items = matchRules as Object[];
      for (const item of items) {
        if (typeof item === 'string') { out.matchRules.push(item); }
      }
    }
    return out;
  }

  /**
   * FlClash `Profile.saveFile` + controller `validateProfile` 原生等价物：
   * temp → age 解密 → validateConfig → ConvertsV2Ray 回退 → 通过后**原样**写
   * profilePath。返回 JSON {"error":"..."}：空 = 通过；错误原文原样抛出
   * （age 键缺失为 `AgeSecretKeyRequired`，UI 层据此要 key，§5.3/§5.6）。
   */
  async validateProfile(text: string, ageSecretKey: string, profilePath: string): Promise<void> {
    const raw = await nativeModule.validateProfile(text, ageSecretKey, profilePath);
    if (raw.length === 0) {
      throw new Error('内核 profile 校验器不可用');
    }
    const reply = JSON.parse(raw) as Record<string, Object>;
    const error = reply['error'];
    if (typeof error === 'string' && error.length > 0) {
      throw new Error(error);
    }
  }

  /**
   * FlClash `core/profile_base.go handleGetProfileOutbounds` 移植：只投影
   * name/type + 组名，供预览构造 `core:<name>` 影子节点（§5.5）。
   */
  async getProfileOutbounds(path: string): Promise<CoreOutboundsResult> {
    const raw = await nativeModule.getProfileOutbounds(path);
    if (raw.length === 0) {
      throw new Error('内核 outbounds 投影不可用');
    }
    const reply = JSON.parse(raw) as Record<string, Object>;
    const error = reply['error'];
    if (typeof error === 'string' && error.length > 0) {
      throw new Error(error);
    }
    const out = new CoreOutboundsResult();
    const readList = (key: string): CoreOutboundName[] => {
      const items: CoreOutboundName[] = [];
      const value = reply[key];
      if (Array.isArray(value)) {
        for (const item of value as Object[]) {
          if (item === null || item === undefined || typeof item !== 'object') { continue; }
          const rec = item as Record<string, Object>;
          const entry = new CoreOutboundName();
          const name = rec['name'];
          const type = rec['type'];
          entry.name = typeof name === 'string' ? name : '';
          entry.type = typeof type === 'string' ? type : '';
          if (entry.name.length > 0) { items.push(entry); }
        }
      }
      return items;
    };
    out.proxies = readList('proxies');
    out.proxyGroups = readList('proxy-groups');
    return out;
  }

  /** YAML 文本 -> map（内核同一 yaml 库；ArkTS 无 YAML 解析器的 FlClash loadYaml 等价物）。 */
  async decodeYaml(text: string): Promise<Record<string, Object>> {
    const raw = await nativeModule.decodeYaml(text);
    if (raw.length === 0) {
      throw new Error('内核 YAML 解码器不可用');
    }
    const reply = JSON.parse(raw) as Record<string, Object>;
    const error = reply['error'];
    if (typeof error === 'string' && error.length > 0) {
      throw new Error(error);
    }
    const map = reply['map'];
    if (map === null || map === undefined || typeof map !== 'object') {
      throw new Error('内核未返回解码结果');
    }
    return map as Record<string, Object>;
  }

  async fetchText(url: string, userAgent: string, authHeader: string, proxyPort: number = 0): Promise<CoreFetchResult> {
    const raw = await nativeModule.fetchText(url, userAgent, authHeader, proxyPort);
    if (raw.length === 0) {
      throw new Error('内核取回模块不可用');
    }
    const reply = JSON.parse(raw) as Record<string, Object>;
    const error = reply['error'];
    if (typeof error === 'string' && error.length > 0) {
      throw new Error(error);
    }
    const body = reply['body'];
    if (typeof body !== 'string' || body.length === 0) {
      throw new Error('内核未返回内容');
    }
    const out = new CoreFetchResult();
    out.body = body;
    const etag = reply['etag'];
    if (typeof etag === 'string') { out.etag = etag; }
    const userInfo = reply['userInfo'];
    if (typeof userInfo === 'string') { out.userInfo = userInfo; }
    const disposition = reply['disposition'];
    if (typeof disposition === 'string') { out.disposition = disposition; }
    const contentType = reply['contentType'];
    if (typeof contentType === 'string') { out.contentType = contentType; }
    const status = reply['status'];
    if (typeof status === 'number') { out.status = status; }
    return out;
  }

  setPhysicalNetId(netId: number): boolean {
    return this.ensureLoaded() && nativeModule.setPhysicalNetId(netId);
  }

  private ensureLoaded(): boolean {
    if (this.loaded) {
      return true;
    }
    this.loaded = true;
    AppLogger.info(TAG, `${CORE_LIB} bridge module registered`);
    AppLogger.info(TAG, `native module attachTunFd=${typeof nativeModule.attachTunFd}, startCore=${typeof nativeModule.startCore}`);
    return true;
  }

  /** VpnExtensionAbility 在 TUN 建立后调用：注入 fd */
  async attachTun(fd: number, mtu: number): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    this.tunFd = -1;
    const attached = nativeModule.attachTunFd(fd, mtu);
    AppLogger.info(TAG, `attachTunFd(fd=${fd}, mtu=${mtu}) -> ${attached}`);
    if (attached) {
      this.tunFd = fd;
    }
    return attached;
  }

  /** 初始化 Go socket-protect 请求通道。 */
  async initProtect(): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    return nativeModule.initProtect() >= 0;
  }

  /** 非阻塞读取一条 protect 请求 [socketFd, seq]；无请求时 socketFd 为 -1。 */
  readProtectSocketFd(): number[] {
    return nativeModule.readProtectSocketFd();
  }

  /** 将 VpnConnection.protect() 的结果回传给 Go bridge。 */
  setProtectResult(ok: boolean): void {
    nativeModule.setProtectResult(ok);
  }

  /** 按 seq 精确回传 protect 结果, 唤醒对应拨号协程(旧符号保留兼容)。 */
  setProtectResultForFd(fd: number, seq: number, ok: boolean): void {
    nativeModule.setProtectResultForFd(fd, seq, ok);
  }

  /** 启动内核（configPath 为已写入的 Mihomo YAML 文件路径） */
  async startCore(configPath: string): Promise<boolean> {
    if (!this.ensureLoaded()) {
      return false;
    }
    const pending = nativeModule.startCore(configPath, this.tunFd);
    this.pendingStart = pending;
    try {
      return await pending;
    } finally {
      if (this.pendingStart === pending) {
        this.pendingStart = null;
      }
    }
  }

  async stopCore(): Promise<void> {
    // Native start runs in a worker: stop only after it settles, otherwise that
    // worker could start a new core after disconnect has already stopped it.
    // 但启动若被"联网下载"阻塞，promise 可能永不 settle —— 无限等待会让断开/清理
    // 流程一起卡死。这里给等待加上限，超时后仍执行 native stopCore() 兜底回收。
    const pending = this.pendingStart;
    this.tunFd = -1;
    if (pending !== null) {
      let timer: number = -1;
      const capped = new Promise<void>((resolve) => {
        timer = setTimeout(() => {
          AppLogger.warn(TAG, `stopCore wait for pending start exceeded ${STOP_WAIT_MS}ms; forcing native stop`);
          resolve();
        }, STOP_WAIT_MS);
      });
      try {
        await Promise.race([pending.then(() => undefined).catch(() => undefined), capped]);
      } finally {
        if (timer >= 0) {
          clearTimeout(timer);
        }
      }
    }
    await nativeModule.stopCore();
  }

  /** Runs in a native worker; socket protect callbacks stay responsive. */
  async updateNetwork(dnsServers: string[], resetFlows: boolean): Promise<boolean> {
    return nativeModule.updateNetwork(JSON.stringify(dnsServers), resetFlows);
  }

  async isCoreAlive(): Promise<boolean> {
    return nativeModule.isCoreAlive();
  }

  async coreVersion(): Promise<string> {
    return nativeModule.coreVersion();
  }

  async lastError(): Promise<string> {
    return nativeModule.lastError();
  }
}

export const coreBridge: CoreBridgeImpl = new CoreBridgeImpl();
