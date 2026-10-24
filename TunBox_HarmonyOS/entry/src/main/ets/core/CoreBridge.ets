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
  attachTunFd(fd: number, mtu: number): boolean;
  initProtect(): number;
  readProtectSocketFd(): number[];
  setProtectResult(ok: boolean): void;
  setProtectResultForFd(fd: number, seq: number, ok: boolean): void;
  startCore(configPath: string, tunFd: number): Promise<boolean>;
  stopCore(): Promise<void>;
  prepareProfile(text: string): Promise<string>;
  isCoreAlive(): boolean;
  coreVersion(): string;
  lastError(): string;
}
const nativeModule: NativeCoreModule = native as NativeCoreModule;
/** stopCore 等待启动落地的硬上限：内核启动若被联网下载阻塞，promise 可能永不 settle */
const STOP_WAIT_MS = 5000;

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
