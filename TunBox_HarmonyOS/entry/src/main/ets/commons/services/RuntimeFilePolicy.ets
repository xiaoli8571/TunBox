/**
 * 运行时私有文件策略：证书/配置文件的最小权限落盘与可靠清理。
 *
 * 设计要点（对应审计项「运行时凭据清理」）：
 * 1) 最小权限：写入前确保目录存在且以 0700 创建；文件以 READ_WRITE|CREATE|TRUNC
 *    创建后用 chmod 收窄到 0600（仅属主可读写），避免同设备其他进程读取
 *    含 API secret / 节点口令的 YAML。
 * 2) 可靠清理：每个文件独立 try/catch，一个文件不存在或删除失败不得阻止
 *    其余文件删除（逐文件独立容错）。
 * 3) 集中管理文件名，避免散落的字符串常量导致漏删。
 *
 * 纯策略 + 注入文件系统，便于在 ohosTest 中做专项验证（不依赖真实沙箱）。
 */

/** 含凭据的运行时文件（相对 cacheDir） */
export const PRIVATE_CONFIG_FILE = 'mihomo_config.yaml';
/**
 * 测速配置的**旧版固定文件名**。现在每次启动用自己的文件名（见 testConfigFileName），
 * 这个常量只用于清理旧版本留下的文件。
 */
export const PRIVATE_TEST_CONFIG_FILE = 'mihomo_test_config.yaml';

/**
 * 本次测速核启动专属的配置文件名：`mihomo_test_config.<token>.yaml`。
 *
 * 为什么不能共用一个固定文件名（2026-11-11 真机定案，冷启动后点测速必失败）：
 * 扩展进程退出时会删掉「自己那份」临时测速配置；而 UI 拉起下一个测速核时是
 * 先写配置、再停旧扩展。文件名相同 ⇒ 旧扩展把新一轮刚写好的配置删了，
 * 新扩展启动时 `config file missing`。停扩展是跨进程异步的，调换顺序也堵不住
 * （上一次启动失败、没有心跳的扩展实例照样会在被停时删文件）。
 * 每次启动一个文件名 ⇒ 每个扩展实例只可能删到自己的那份。
 *
 * token 只保留 [a-z0-9-]；清洗后为空则退回旧固定名（不产生非法文件名）。
 */
export function testConfigFileName(token: string): string {
  const safe = token.toLowerCase().replace(/[^a-z0-9-]/g, '');
  return safe.length > 0 ? `mihomo_test_config.${safe}.yaml` : PRIVATE_TEST_CONFIG_FILE;
}

/** 文件名是否是测速配置（新版带 token 的与旧版固定名都算）。 */
export function isTestConfigFileName(name: string): boolean {
  return /^mihomo_test_config(\.[a-z0-9-]+)?\.yaml$/.test(name);
}

/** 路径是否指向测速配置（按最后一段文件名判断）。 */
export function isTestConfigPath(path: string): boolean {
  const slash = path.lastIndexOf('/');
  return isTestConfigFileName(slash >= 0 ? path.substring(slash + 1) : path);
}

/** 扩展进程回写的跨进程状态文件 */
export const TUNNEL_STATE_FILES: string[] = [
  'vpn_heartbeat.txt',
  // 存活租约的原子替换临时文件（先写 .tmp 再 rename 覆盖心跳本体）
  'vpn_heartbeat.txt.tmp',
  'vpn_start_ok.txt',
  'vpn_start_error.txt',
  // UI 每次拉起前重写、扩展仅在 want 丢参时读一次的路由参数快照；
  // 随隧道生命周期清理（名字须与 ConnectionOrchestrator/VpnExtensionAbility 两侧常量一致）
  'vpn_start_params.json',
  // 扩展 onCreate 送达标记（UI 判定 start 是否被系统吞并）；断开时复位
  'vpn_launch_epoch.txt'
];

/** 同步读取状态文件时的最大字节数（防止被写入超长内容后一次性分配巨额内存） */
export const MAX_STATE_FILE_BYTES = 64 * 1024;
/** 最小权限目录 / 文件权限位 */
export const PRIVATE_DIR_MODE = 0o700;
export const PRIVATE_FILE_MODE = 0o600;

/**
 * 同步文件读取结果：ok=false 表示读取失败（文件不存在/IO 错误），
 * text 为空串而非抛异常 —— 调用方按「无数据」处理。
 */
export interface SyncReadResult {
  ok: boolean;
  text: string;
  /** 原始内容是否因超过上限而被截断 */
  truncated: boolean;
}

/**
 * 最小权限文件系统接口。仅为可测试性抽象，生产实现直接包 fileIo。
 */
export interface PrivateFs {
  /** 写入（创建/覆盖）并收窄权限；实现必须保证 fd 在 finally 中关闭 */
  writePrivate(path: string, content: string): void;
  /** 读取上限内的文本；失败返回 { ok: false }，绝不抛异常 */
  readCapped(path: string, maxBytes: number): SyncReadResult;
  /** 异步读取上限内的文本（不阻塞主线程）；失败返回 { ok: false }，绝不抛异常 */
  readCappedAsync(path: string, maxBytes: number): Promise<SyncReadResult>;
  /** 删除单个文件；不存在/失败均返回 false，绝不抛异常 */
  remove(path: string): boolean;
  /** 仅探测存在性 */
  exists(path: string): boolean;
}

/**
 * 逐文件独立容错删除：返回成功删除的文件名列表。
 * 关键约束：任一文件不存在（抛错）不得中断循环，后续文件仍必须尝试删除。
 */
export function removeFilesIndependently(dir: string, fileNames: string[],
  fsImpl: PrivateFs): string[] {
  const removed: string[] = [];
  for (const name of fileNames) {
    if (fsImpl.remove(`${dir}/${name}`)) {
      removed.push(name);
    }
  }
  return removed;
}

/**
 * 凭据文件清理：主配置 + 测速配置 + 隧道状态文件。
 * 每个文件独立容错，缺失即跳过，绝不因单点失败影响其他文件。
 */
export function clearPrivateArtifacts(dir: string, fsImpl: PrivateFs): string[] {
  const targets: string[] = [PRIVATE_CONFIG_FILE, PRIVATE_TEST_CONFIG_FILE];
  for (const f of TUNNEL_STATE_FILES) {
    targets.push(f);
  }
  return removeFilesIndependently(dir, targets, fsImpl);
}

/** 状态文本解析为心跳时间戳；非法内容返回 -1 */
export function parseHeartbeatTimestamp(text: string): number {
  const ts = Number(text.trim());
  if (!Number.isFinite(ts) || ts <= 0) {
    return -1;
  }
  return ts;
}

/** 由心跳文本计算年龄（ms）；-1 = 无心跳/非法 */
export function heartbeatAgeFromText(text: string, now: number): number {
  const ts = parseHeartbeatTimestamp(text);
  if (ts < 0) {
    return -1;
  }
  return now - ts;
}
