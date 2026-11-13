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
/** Physical DNS refresh and optional stale-flow reset; never rebuilds the TUN. */
export const updateNetwork: (dnsJson: string, resetFlows: boolean) => Promise<boolean>;
export const prepareProfile: (text: string) => Promise<string>;
/**
 * 用内核（mihomo 自身解析器）读取并解析 profile 文件。
 * 返回 JSON 字符串：{"config":{...},"digest":"...","proxies":N,"proxyGroups":N,
 * "rules":N,"matchRules":[...],"error":"..."}。
 * FlClash `CoreController.getConfig` / `getProfileBase` 同构——App 只做 map 级 patch。
 */
export const getProfileBase: (path: string) => Promise<string>;
/**
 * FlClash `Profile.saveFile` + controller `validateProfile` 的原生等价物。
 * temp → age 解密（armor 头 + 空 key 返回原始 `AgeSecretKeyRequired`）→
 * validateConfig → ConvertsV2Ray 回退 → 通过后把最终字节原样写到 profilePath。
 * 返回 JSON 字符串：{"error":"..."}（空 error = 通过，错误保留原始类型/文案）。
 */
export const validateProfile: (text: string, ageSecretKey: string, profilePath: string) => Promise<string>;
/**
 * FlClash `core/profile_base.go handleGetProfileOutbounds` 移植。
 * 返回 JSON 字符串：{"proxies":[{"name","type"}],"proxy-groups":[{"name","type"}],
 * "error":"..."} —— 只投影 name/type，供预览构造 core:<name> 影子节点。
 */
export const getProfileOutbounds: (path: string) => Promise<string>;
/**
 * YAML 文本 -> JSON map（内核同一 yaml 库解析，方言与配置加载一致）。
 * 返回 JSON 字符串：{"map":{...},"error":"..."}。本项目复用内核解析库承担
 * FlClash Dart 侧 loadYaml 的角色。
 */
export const decodeYaml: (text: string) => Promise<string>;
/**
 * 用内核的浏览器级 TLS 指纹（utls Chrome）拉取订阅 / provider 文本。
 * 返回 JSON 字符串：{"body":"...","error":"..."}。
 * 与 FlClash 的下载语义一致：单一 UA，不做 UA 轮换。
 */
export const fetchText: (url: string, userAgent: string, authHeader: string, proxyPort: number) => Promise<string>;
export const isCoreAlive: () => boolean;
export const coreVersion: () => string;
export const lastError: () => string;
export const attachTunFd: (fd: number, mtu: number) => boolean;

/** Bind headless core sockets to a physical network (UI process only). */
export const setPhysicalNetId: (netId: number) => boolean;
