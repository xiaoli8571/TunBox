/**
 * 编排器链路自检探针（第二阶段集成层 · 小幅辅助文件）
 *
 * 职责:
 *   把 ConnectionOrchestrator 的真实运行态（订阅/节点/心跳/隧道标记/Clash API/DNS/出口/
 *   意图一致性）映射为 LinkHealthChecker 需要的 10 个探针 (LinkHealthProbes)。
 *
 * 设计约束:
 *   1) 只读 + 无副作用：探针只读取视图，不修改任何状态。
 *   2) 绝不 reject：所有失败都通过 ProbeOutcome.fail / skip 表达；底层 Promise 的
 *      异常由 LinkHealthChecker.withOutcomeTimeout 兜底，但这里也做防御。
 *   3) 视图由 ConnectionOrchestrator 实现（实现 OrchestratorHealthView），
 *      探针本身不反向依赖整个编排器，便于单测与离线校验。
 */
import { LinkHealthProbes, ProbeOutcome } from './LinkHealthChecker';

/** 编排器可提供的只读运行态视图（由 ConnectionOrchestrator 实现） */
export interface OrchestratorHealthView {
  /** 是否已加载订阅 */
  hasSubscriptions(): boolean;
  /** 当前订阅内节点数量 */
  subsNodeCount(): number;
  /** 当前（上次/目标）节点名 */
  currentNodeName(): string;
  /** 当前节点配置是否可生成有效 YAML */
  isCurrentNodeValid(): boolean;
  /** 扩展进程心跳是否新鲜（内核存活） */
  isHeartbeatAlive(): boolean;
  /** 隧道存活标记文件是否存在 */
  isTunnelMarkerPresent(): boolean;
  /** 持久化的用户连接意图 */
  isDesiredConnected(): Promise<boolean>;
  /** 连接意图与真实内核状态是否一致 */
  isIntentConsistent(): Promise<boolean>;
  /** 扩展进程回写的启动错误（空 = 无错误） */
  startErrorText(): string;
  /** 本次连接是否启用 IPv6 双栈（= 设置页 IPv6 开关，默认开） */
  isIpv6Enabled(): boolean;
  /** Clash API 是否可达 */
  checkClashApiReachable(): Promise<boolean>;
  /** DNS 是否可解析 */
  checkDnsResolvable(): Promise<boolean>;
  /** 客户端侧 AAAA 解析是否真的能拿到 v6 地址（IPv6 双栈的端到端判据） */
  checkIpv6Resolvable(): Promise<boolean>;
  /** IPv4 出口是否连通（generate_204） */
  checkEgressReachable(): Promise<boolean>;
}

/** 10 项链路探针的真实实现 */
export class OrchestratorHealthProbes implements LinkHealthProbes {
  private view: OrchestratorHealthView;

  constructor(view: OrchestratorHealthView) {
    this.view = view;
  }

  probeSubscription(): Promise<ProbeOutcome> {
    if (!this.view.hasSubscriptions() || this.view.subsNodeCount() === 0) {
      return Promise.resolve(ProbeOutcome.fail('未加载订阅或订阅内无节点',
        '请到主页「订阅」里刷新', 'refresh-subscription'));
    }
    return Promise.resolve(ProbeOutcome.pass(
      '订阅含 ' + this.view.subsNodeCount() + ' 个节点', '' + this.view.subsNodeCount()));
  }

  probeNode(): Promise<ProbeOutcome> {
    if (this.view.isCurrentNodeValid()) {
      return Promise.resolve(ProbeOutcome.pass('当前节点配置可生成', this.view.currentNodeName()));
    }
    return Promise.resolve(ProbeOutcome.fail('当前节点配置缺失或无效',
      '请重新选择节点或刷新订阅', 'reselect-node'));
  }

  probeVpnAuth(): Promise<ProbeOutcome> {
    const err = this.view.startErrorText();
    const lower = err.toLowerCase();
    if (lower.indexOf('permission') >= 0 || err.indexOf('授权') >= 0 || lower.indexOf('201') >= 0) {
      return Promise.resolve(ProbeOutcome.fail('VPN 能力授权缺失: ' + err,
        '请在系统弹窗中允许 VPN 连接', 'grant-vpn-permission'));
    }
    if (this.view.isTunnelMarkerPresent() || this.view.isHeartbeatAlive()) {
      return Promise.resolve(ProbeOutcome.pass('VPN 能力已授权（隧道标记/心跳存在）'));
    }
    return Promise.resolve(ProbeOutcome.skip('未处于连接态，无法判定 VPN 授权'));
  }

  probeTun(): Promise<ProbeOutcome> {
    if (this.view.isTunnelMarkerPresent()) {
      return Promise.resolve(ProbeOutcome.pass('TUN 已建立（存在存活标记）'));
    }
    return this.view.isDesiredConnected().then((desired: boolean): ProbeOutcome => {
      if (desired) {
        return ProbeOutcome.fail('期望已连接但缺少 TUN 存活标记', '请重建隧道', 'rebuild-tun');
      }
      return ProbeOutcome.skip('未请求连接，跳过 TUN 检查');
    });
  }

  probeCore(): Promise<ProbeOutcome> {
    if (this.view.isHeartbeatAlive()) {
      return Promise.resolve(ProbeOutcome.pass('内核心跳新鲜'));
    }
    return Promise.resolve(ProbeOutcome.fail('内核心跳缺失或过期（内核可能已死）',
      '请重启内核并重建隧道', 'restart-core'));
  }

  probeClashApi(): Promise<ProbeOutcome> {
    return this.view.checkClashApiReachable().then((ok: boolean): ProbeOutcome => {
      if (ok) {
        return ProbeOutcome.pass('Clash API 可达');
      }
      return ProbeOutcome.fail('Clash API 不可达', '请重启 Clash API（重建隧道）', 'restart-clash-api');
    });
  }

  probeDns(): Promise<ProbeOutcome> {
    if (!this.view.isHeartbeatAlive()) {
      return Promise.resolve(ProbeOutcome.skip('内核未运行，跳过 DNS 检查'));
    }
    return this.view.checkDnsResolvable().then((ok: boolean): ProbeOutcome => {
      if (ok) {
        return ProbeOutcome.pass('DNS 解析正常');
      }
      return ProbeOutcome.fail('DNS 解析失败', '请检查内核 DNS 配置（随修复重建）', 'fix-dns');
    });
  }

  probeIpv4Egress(): Promise<ProbeOutcome> {
    if (!this.view.isHeartbeatAlive()) {
      return Promise.resolve(ProbeOutcome.skip('内核未运行，跳过出口连通检查'));
    }
    return this.view.checkEgressReachable().then((ok: boolean): ProbeOutcome => {
      if (ok) {
        return ProbeOutcome.pass('IPv4 出口连通 (generate_204)');
      }
      return ProbeOutcome.fail('IPv4 出口连通失败', '请检查上层网络或更换节点', 'check-uplink');
    });
  }

  /**
   * IPv6 双栈探针（2026-10-21 DNS 恒接管后重写判据）。
   *
   * 判据：**客户端侧 AAAA 解析**能不能拿到 v6 地址。
   *
   * DNS 已恒接管、且生成器改用 `enhanced-mode: redir-host`（没有 fake 池），
   * AAAA 由 `withResolver` 直接向上游要真实地址，只受 `dns.ipv6` 控制
   * （dns/middleware.go:205-208）。所以「拿不到 AAAA」不再是配置必然，而是
   * 当前网络/上游确实没有 v6 ⇒ 如实报 fail 并建议关闭开关（避免设备一半流量
   * 走不通），修复动作标 check-uplink。开关关闭时仍 skip。
   */
  probeIpv6(): Promise<ProbeOutcome> {
    if (!this.view.isIpv6Enabled()) {
      return Promise.resolve(ProbeOutcome.skip('IPv6 双栈已在设置中关闭（设置 → 网络）'));
    }
    if (!this.view.isHeartbeatAlive()) {
      return Promise.resolve(ProbeOutcome.skip('内核未运行，跳过 IPv6 检查'));
    }
    return this.view.checkIpv6Resolvable().then((ok: boolean): ProbeOutcome => {
      if (ok) {
        return ProbeOutcome.pass('IPv6 双栈生效（AAAA 解析正常）');
      }
      return ProbeOutcome.fail('IPv6 双栈已开启，但当前网络解析不到 v6 地址',
        '当前网络/运营商未提供 IPv6：建议在「设置 → 网络」关闭 IPv6 双栈', 'check-uplink');
    });
  }

  probeIntentConsistency(): Promise<ProbeOutcome> {
    return this.view.isIntentConsistent().then((ok: boolean): ProbeOutcome => {
      if (ok) {
        return ProbeOutcome.pass('连接意图与真实状态一致');
      }
      return ProbeOutcome.fail('连接意图与真实状态不一致',
        '已尝试自动对齐（以真实内核状态为准）', 'reconcile-intent');
    });
  }
}
