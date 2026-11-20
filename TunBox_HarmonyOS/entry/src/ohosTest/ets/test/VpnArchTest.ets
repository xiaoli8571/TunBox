/**
 * VPN 架构改造专项用例（Extension 主导网络/恢复、Kill Switch、IPv4-only、低频状态）。
 *
 * 与 scripts/verify-vpn-architecture.mjs 使用同一批纯函数（VpnRecoveryPolicy /
 * TunnelAuthority），这里是它们在真机 ohosTest 运行时下的等价覆盖：
 * 后台/锁屏/UI 进程回收后的状态还原、网络切换 MTU、内核崩溃有限恢复、
 * TUN 重建升级与泄漏阻断收敛、退避封顶、以及配置生成的 IPv4-only 断言。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  BASE_MTU, CELLULAR_MTU, MAX_CORE_RECOVERY_ATTEMPTS, MAX_TUNNEL_REBUILDS,
  NetTypes, RecoveryAction, RecoveryInput, coreRecoveryDelayMs, decideRecoveryAction,
  leakSwitchDecision, mtuForNetType, shouldResetRecovery, tunnelRebuildDelayMs
} from '../../../main/ets/commons/services/VpnRecoveryPolicy';
import {
  ExtensionStatusView, HEARTBEAT_STALE_MS, deriveUiPhase, parseExtensionStatus, resolveAuthority
} from '../../../main/ets/commons/services/TunnelAuthority';
import { ClashConfigGenerator } from '../../../main/ets/commons/services/ClashConfigGenerator';
import { AppSettings } from '../../../main/ets/commons/models/AppSettings';
import { ProxyNode } from '../../../main/ets/commons/models/ProxyNode';

function makeInput(userStopped: boolean, netType: string, coreAlive: boolean,
  connectionUp: boolean, rebuilding: boolean, attempts: number, rebuilds: number): RecoveryInput {
  const inp = new RecoveryInput();
  inp.userStopped = userStopped;
  inp.netType = netType;
  inp.coreAlive = coreAlive;
  inp.connectionUp = connectionUp;
  inp.rebuilding = rebuilding;
  inp.recoveryAttempts = attempts;
  inp.tunnelRebuilds = rebuilds;
  return inp;
}

function statusText(phase: string, mtu: number, netType: string, coreAlive: boolean,
  attempts: number, rebuilds: number, seq: number): string {
  const aliveFlag = coreAlive ? 'true' : 'false';
  return '{"phase":"' + phase + '","mtu":' + mtu + ',"netType":"' + netType + '","coreAlive":' + aliveFlag
    + ',"recoveryAttempts":' + attempts + ',"rebuilds":' + rebuilds + ',"seq":' + seq
    + ',"ts":1700000000000,"detail":"ut"}';
}

export function vpnArchTest() {
  describe('VpnArchTest', () => {

    // ── 统一 MTU：承载切换不改 MTU（切 Wi-Fi/蜂窝不需要重建 TUN）────────────
    // 旧用例名 mtu_cellular_lower_than_wifi 与最后一条「蜂窝 < Wi-Fi」断言是按承载分档
    // 时代的口径；BASE_MTU 统一为 1360 之后那条断言恒为假，本用例每次必挂。
    it('mtu_is_uniform_across_bearers', 0, () => {
      expect(mtuForNetType(NetTypes.CELLULAR)).assertEqual(CELLULAR_MTU);
      expect(mtuForNetType(NetTypes.WIFI)).assertEqual(BASE_MTU);
      expect(mtuForNetType(NetTypes.ETHERNET)).assertEqual(BASE_MTU);
      expect(mtuForNetType(NetTypes.CELLULAR)).assertEqual(mtuForNetType(NetTypes.WIFI));
    });

    // ── 恢复退避：指数增长且封顶（弱网重连风暴抑制）──────────────────
    it('recovery_backoff_monotonic_and_capped', 0, () => {
      expect(coreRecoveryDelayMs(0)).assertEqual(1000);
      expect(coreRecoveryDelayMs(1)).assertEqual(2000);
      expect(coreRecoveryDelayMs(2)).assertEqual(4000);
      expect(coreRecoveryDelayMs(9)).assertEqual(8000);
      expect(tunnelRebuildDelayMs(0)).assertEqual(1500);
      expect(tunnelRebuildDelayMs(9)).assertEqual(8000);
    });

    // ── Kill Switch：断网保持阻断、不消耗恢复预算 ────────────────────
    it('killswitch_blocks_on_network_loss', 0, () => {
      expect(leakSwitchDecision(false, NetTypes.NONE, false)).assertEqual('leak-blocked');
      expect(leakSwitchDecision(true, NetTypes.WIFI, false)).assertEqual('down');
      expect(leakSwitchDecision(false, NetTypes.WIFI, false)).assertEqual('recover');
      expect(decideRecoveryAction(makeInput(false, NetTypes.NONE, false, true, false, 0, 0)))
        .assertEqual(RecoveryAction.LEAK_BLOCKED);
    });

    // ── 内核崩溃：有限热恢复 → 升级 TUN 重建 → 耗尽收敛到阻断 ──────────
    it('core_crash_recovery_escalates_then_blocks', 0, () => {
      expect(decideRecoveryAction(makeInput(false, NetTypes.WIFI, false, true, false, 0, 0)))
        .assertEqual(RecoveryAction.CORE_RECOVERY);
      expect(decideRecoveryAction(makeInput(false, NetTypes.WIFI, false, true, false,
        MAX_CORE_RECOVERY_ATTEMPTS - 1, 0))).assertEqual(RecoveryAction.CORE_RECOVERY);
      expect(decideRecoveryAction(makeInput(false, NetTypes.WIFI, false, true, false,
        MAX_CORE_RECOVERY_ATTEMPTS, 0))).assertEqual(RecoveryAction.TUN_REBUILD);
      expect(decideRecoveryAction(makeInput(false, NetTypes.WIFI, false, true, false,
        MAX_CORE_RECOVERY_ATTEMPTS, MAX_TUNNEL_REBUILDS))).assertEqual(RecoveryAction.LEAK_BLOCKED);
    });

    // ── 不可恢复场景必然收敛（不长跑重建风暴）─────────────────────────
    it('hopeless_failure_converges_to_block', 0, () => {
      let attempts = 0;
      let rebuilds = 0;
      let last = '';
      for (let step = 0; step < 40; step = step + 1) {
        const act = decideRecoveryAction(makeInput(false, NetTypes.WIFI, false, true, false, attempts, rebuilds));
        last = act;
        if (act === RecoveryAction.CORE_RECOVERY) {
          attempts = attempts + 1;
        } else if (act === RecoveryAction.TUN_REBUILD) {
          rebuilds = rebuilds + 1;
        } else {
          break;
        }
      }
      expect(last).assertEqual(RecoveryAction.LEAK_BLOCKED);
      expect(attempts).assertEqual(MAX_CORE_RECOVERY_ATTEMPTS);
      expect(rebuilds).assertEqual(MAX_TUNNEL_REBUILDS);
    });

    // ── 单航班门控：重建中/用户停止/无隧道时不重复调度 ────────────────
    it('recovery_is_single_flight_gated', 0, () => {
      expect(decideRecoveryAction(makeInput(false, NetTypes.WIFI, false, true, true, 0, 0)))
        .assertEqual(RecoveryAction.NONE);
      expect(decideRecoveryAction(makeInput(true, NetTypes.WIFI, false, true, false, 0, 0)))
        .assertEqual(RecoveryAction.NONE);
      expect(decideRecoveryAction(makeInput(false, NetTypes.WIFI, false, false, false, 0, 0)))
        .assertEqual(RecoveryAction.NONE);
      expect(decideRecoveryAction(makeInput(false, NetTypes.WIFI, true, true, false, 0, 0)))
        .assertEqual(RecoveryAction.NONE);
    });

    // ── 长稳：恢复成功计数归零，空闲不触发动作 ────────────────────────
    it('long_run_stable_resets_and_idle', 0, () => {
      expect(shouldResetRecovery(true, NetTypes.WIFI)).assertTrue();
      expect(shouldResetRecovery(true, NetTypes.CELLULAR)).assertTrue();
      expect(shouldResetRecovery(false, NetTypes.WIFI)).assertFalse();
      expect(shouldResetRecovery(true, NetTypes.NONE)).assertFalse();
      let fired = 0;
      for (let step = 0; step < 20; step = step + 1) {
        if (decideRecoveryAction(makeInput(false, NetTypes.WIFI, true, true, false, 0, 0)) !== RecoveryAction.NONE) {
          fired = fired + 1;
        }
      }
      expect(fired).assertEqual(0);
    });

    // ── 状态解析 + UI 进程回收后还原真实相位 ──────────────────────────
    it('extension_status_restores_ui_phase', 0, () => {
      const running = parseExtensionStatus(statusText('running', 1400, 'wifi', true, 0, 0, 1));
      expect(running.ok).assertTrue();
      expect(running.mtu).assertEqual(1400);
      expect(deriveUiPhase(running, true)).assertEqual('connected');
      // 租约过期（UI 进程被回收且无新事件）：不得谎报已连接。
      expect(deriveUiPhase(running, false)).assertEqual('stale');
      const rec = parseExtensionStatus(statusText('recovering', 1360, 'cellular', false, 1, 0, 2));
      expect(deriveUiPhase(rec, false)).assertEqual('recovering');
      const blk = parseExtensionStatus(statusText('leak-blocked', 1400, 'none', false, 3, 2, 3));
      expect(deriveUiPhase(blk, false)).assertEqual('leak-blocked');
      const stopped = parseExtensionStatus(statusText('stopped', 1400, 'wifi', false, 0, 0, 4));
      expect(deriveUiPhase(stopped, true)).assertEqual('disconnected');
    });

    it('extension_status_parser_rejects_garbage', 0, () => {
      expect(parseExtensionStatus('').ok).assertFalse();
      expect(parseExtensionStatus('hello').ok).assertFalse();
      expect(parseExtensionStatus('{"mtu":1400}').ok).assertFalse();
      const empty = new ExtensionStatusView();
      expect(deriveUiPhase(empty, false)).assertEqual('stale');
    });

    // ── 低频存活租约：15s 陈旧窗口 + 隧道存活标记兜底 ─────────────────
    it('liveness_lease_window_semantics', 0, () => {
      expect(HEARTBEAT_STALE_MS).assertEqual(15000);
      expect(resolveAuthority(true, 10000, false).connected).assertTrue();
      expect(resolveAuthority(true, HEARTBEAT_STALE_MS + 1, false).connected).assertFalse();
      expect(resolveAuthority(true, -1, true).coreAlive).assertTrue();
      expect(resolveAuthority(false, 0, true).connected).assertFalse();
    });

    // ── 生成的内核配置：DNS 恒接管（fake-ip）+ 可选双栈 + 性能参数 ──────────
    it('generated_config_dns_always_on_and_tuned', 0, () => {
      const settings = new AppSettings();
      const node = new ProxyNode();
      node.name = 'UT-HK';
      node.proxyType = 'ss';
      node.server = 'h.example.com';
      node.port = 443;
      node.method = 'aes-128-gcm';
      node.password = 'pw';
      const yaml = ClashConfigGenerator.generate(node, [node], settings, 7890, 9090, 1053,
        'ut-secret', false, false, {}, true, []);
      // 第 9 个实参 ipv6Enabled=false ⇒ 顶层与 dns 侧同为 false
      expect(yaml.includes('ipv6: false')).assertTrue();
      // 伪键不产出；假池在 fake-ip 模式下存在，但 ipv6Enabled=false 时不得下发 range6
      expect(yaml.includes('disable-ipv6: true')).assertFalse();
      expect(yaml.includes('store-fake-ip')).assertFalse();
      expect(yaml.includes('enhanced-mode: fake-ip')).assertTrue();
      expect(yaml.includes('fake-ip-range: 198.18.0.1/16')).assertTrue();
      expect(yaml.includes('fake-ip-range6')).assertFalse();
      expect(yaml.includes('fake-ip-filter:')).assertTrue();
      expect(yaml.includes('  enable: true')).assertTrue();
      expect(yaml.includes('dns-hijack:')).assertTrue();
      expect(yaml.includes('    - any:53')).assertTrue();
      expect(yaml.includes('inet6-address')).assertFalse();
      expect(yaml.includes('cache-algorithm: arc')).assertTrue();
      // useGeoip=false ⇒ 整块 fallback 不声明（否则内核启动期会去下载 MMDB：坑 40）
      expect(yaml.includes('fallback:')).assertFalse();
      expect(yaml.includes('keep-alive-interval:')).assertTrue();
      expect(yaml.includes('udp-timeout:')).assertTrue();
      expect(yaml.includes('tcp-concurrent: true')).assertTrue();
      expect(yaml.includes('unified-delay: true')).assertTrue();
      expect(yaml.includes('auto-route: false')).assertTrue();
    });
  });
}
