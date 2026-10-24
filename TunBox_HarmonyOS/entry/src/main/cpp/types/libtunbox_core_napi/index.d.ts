/**
 * NAPI 内核桥模块的 ArkTS 类型声明
 * 实现: entry/src/main/cpp/tunbox_core_napi.cpp (libtunbox_core_napi.so)
 */
/** 异步启动 Core。tunFd 仅用于选择有 TUN/无 TUN 模式，native 会使用 attachTunFd 保存的私有副本。 */
export const startCore: (configPath: string, tunFd: number) => Promise<boolean>;
export const initProtect: () => number;
/** 返回 [socketFd, seq]；无请求时 socketFd 为 -1（seq 为 -1）。 */
export const readProtectSocketFd: () => number[];
/** 旧版无 seq 回执，仅保留兼容，不再唤醒等待者。 */
export const setProtectResult: (ok: boolean) => void;
/** 按 seq 回传 protect 结果，精确唤醒对应拨号协程。 */
export const setProtectResultForFd: (fd: number, seq: number, ok: boolean) => void;
export const stopCore: () => Promise<void>;
export const prepareProfile: (text: string) => Promise<string>;
export const isCoreAlive: () => boolean;
export const coreVersion: () => string;
export const lastError: () => string;
export const attachTunFd: (fd: number, mtu: number) => boolean;
