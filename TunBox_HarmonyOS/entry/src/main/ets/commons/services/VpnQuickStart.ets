/**
 * 后台快捷连接/断开入口，桌面快捷方式与服务卡片共用。
 *
 * 入口使用进程级互斥。操作开始即向全部卡片发布忙碌态，完成后发布
 * 真实最终状态，避免多个卡片或连续点击重复拉起、停止 VPN。
 */
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';
import { ConnectionOrchestrator, ConnState } from './ConnectionOrchestrator';
import { FormStateSync, FormStateSnapshot } from './FormStateSync';
import { ProxyNode } from '../models/ProxyNode';
import { NodeUsability } from '../subscription/NodeUsability';
import { AppLogger } from '../utils/AppLogger';
import { FormInfoMetrics } from './FormInfoMetrics';
import { TunBoxNotifier } from './TunBoxNotifier';

const TAG = 'VpnQuickStart';

export class VpnQuickStart {
  /** 同一应用进程内所有快捷入口共享，防止多卡片并发执行切换。 */
  private static operation: Promise<string> | null = null;
  /** 连接尚未完成时收到的明确断开意图，不能被进程级互斥吞掉。 */
  private static pendingDisconnect: boolean = false;
  /**
   * 最近一次执行的判定原因（可观测通道用）。
   * 形如 `already-connected(core-alive)` / `no-node` / `connect-failed(...)`，
   * 供 QuickToggleAbility 落盘到 vpn_shortcut_outcome.txt，便于事后定位
   * 「点了没反应」到底是已连接短路、无节点还是建连失败。
   */
  private static lastReason: string = '';

  static isBusy(): boolean {
    return VpnQuickStart.operation !== null;
  }

  static lastDetail(): string {
    return VpnQuickStart.lastReason;
  }

  static run(mode: string, context: Context): Promise<string> {
    if (VpnQuickStart.operation !== null) {
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);
      // 在途请求收到 toggle = 明确断开意图。只要当前处于连接中/恢复中，或
      // 已有存活证据，就必须记为 pendingDisconnect 并让旧代际失效。
      // （不看持久化意图：意图读取是异步的，这里要的是"当前是否正在往连接方向走"。）
      if (mode === 'toggle' && (orchestrator.state === ConnState.CONNECTING ||
        orchestrator.state === ConnState.RECOVERING || orchestrator.isTunnelAlive())) {
        VpnQuickStart.pendingDisconnect = true;
        orchestrator.requestDisconnect();
        AppLogger.info(TAG, 'disconnect requested while connect operation is in progress');
        VpnQuickStart.lastReason = 'disconnect-during-connect';
        return VpnQuickStart.operation.then((): string => 'off');
      }
      AppLogger.info(TAG, 'duplicate quick request joined existing operation');
      VpnQuickStart.lastReason = 'joined-inflight-operation';
      return VpnQuickStart.operation;
    }
    const task = VpnQuickStart.runExclusive(mode, context);
    VpnQuickStart.operation = task;
    task.finally((): void => {
      if (VpnQuickStart.operation === task) {
        VpnQuickStart.operation = null;
      }
      // 防御性复位：任何路径结束后都不得把「待断开」意图泄漏到下一次快捷执行。
      VpnQuickStart.pendingDisconnect = false;
    });
    return task;
  }

  private static async runExclusive(mode: string, context: Context): Promise<string> {
    let finalSnapshot: FormStateSnapshot = FormStateSync.disconnected();
    try {
      await SettingsService.init(context);
      const subscriptions = SubscriptionService.instance();
      await subscriptions.init(context);
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);

      // 冷启动竞态兜底：HomePage 已有节点就绪看门狗，但桌面快捷方式/卡片启动
      // 会直接走 VpnQuickStart，可能在订阅 hydrate 完成前立刻发起连接。
      // 此时 preferredNode 解析到旧节点名，后续会报「节点选择未生效」。
      // 这里等待最多 3s，让节点表完成恢复；就绪即返回，不额外增加热启动时延。
      if (subscriptions.nodes.length === 0 && !subscriptions.hasUsableProfile()) {
        const deadline: number = Date.now() + 3000;
        while (Date.now() < deadline) {
          await new Promise<void>((resolve) => setTimeout((): void => resolve(), 200));
          await subscriptions.init(context);
          if (subscriptions.nodes.length > 0 || subscriptions.hasUsableProfile()) {
            break;
          }
        }
      }

      // 【2026-10-24 加固】首选节点可能是存量节点表里的订阅信息条目（「剩余流量：xxx」
      // 这类，内核里无此名、钉选必失败）—— 视为未选中，回落到 fallback 的真节点。
      // 【2026-10-25】改走 resolvePreferenceHint：跨订阅旧偏好判无效 + 刷新 id 漂移按名自愈。
      const preferred = await subscriptions.resolvePreferenceHint();
      const node: ProxyNode | null = (preferred !== null && !NodeUsability.isInfoEntry(preferred.name))
        ? preferred
        : subscriptions.fallbackConnectionNode();
      const nodeName = node === null ? '' : node.name;
      // 权威判据：持久化意图 ∧ 内核存活证据。旧版只看进程内 state 与心跳，
      // 新进程(卡片/快捷方式)state 恒为 DISCONNECTED、心跳过期即 alive=false，
      // 于是"点断开"落进连接分支 → 反而重连（真机实证根因）。
      const authority = await orchestrator.authorityState();
      const alive = authority.connected;

      if (mode === 'toggle' && alive) {
        // 已连接：真正断开（不反转、不重连）
        await FormStateSync.publish(context, FormStateSync.disconnecting(nodeName));
        await orchestrator.disconnect();
        finalSnapshot = node === null ? FormStateSync.noNode() : FormStateSync.disconnected(nodeName);
        await FormStateSync.publish(context, finalSnapshot);
        await TunBoxNotifier.cancel();
        FormInfoMetrics.refreshAfterVpnTransition(context);
        VpnQuickStart.lastReason = `toggled-off(${authority.reason})`;
        return 'off';
      }

      if (mode === 'toggle' && !alive && authority.desiredConnected) {
        // 意图仍为已连接但内核已死（崩溃/心跳超时）：点断开 = 清理残留并如实置为
        // 已断开，绝不能重新拉起隧道。
        AppLogger.warn(TAG, `toggle on dead tunnel (${authority.reason}); cleanup only`);
        await FormStateSync.publish(context, FormStateSync.disconnecting(nodeName));
        await orchestrator.disconnect();
        finalSnapshot = node === null ? FormStateSync.noNode() : FormStateSync.disconnected(nodeName);
        await FormStateSync.publish(context, finalSnapshot);
        await TunBoxNotifier.cancel();
        VpnQuickStart.lastReason = `dead-tunnel-cleanup(${authority.reason})`;
        return 'off';
      }

      if (mode !== 'toggle' && alive) {
        finalSnapshot = FormStateSync.connected(nodeName);
        await FormStateSync.publish(context, finalSnapshot);
        // 「启动代理」在已连接状态下点击：幂等短路，不重复拉起隧道。
        VpnQuickStart.lastReason = `already-connected(${authority.reason})`;
        return 'already';
      }

      if (node === null) {
        AppLogger.warn(TAG, 'quick start: no node available');
        finalSnapshot = FormStateSync.noNode();
        await FormStateSync.publish(context, finalSnapshot);
        VpnQuickStart.lastReason = 'no-node';
        return 'no_node';
      }

      await FormStateSync.publish(context, FormStateSync.connecting(node.name));
      const ok = await orchestrator.connect(node, subscriptions);
      if (VpnQuickStart.pendingDisconnect || orchestrator.isDisconnectRequested()) {
        VpnQuickStart.pendingDisconnect = false;
        await FormStateSync.publish(context, FormStateSync.disconnecting(node.name));
        await orchestrator.disconnect();
        finalSnapshot = FormStateSync.disconnected(node.name);
        await FormStateSync.publish(context, finalSnapshot);
        FormInfoMetrics.refreshAfterVpnTransition(context);
        VpnQuickStart.lastReason = 'disconnect-requested-during-connect';
        return 'off';
      }
      finalSnapshot = ok ? FormStateSync.connected(node.name) : FormStateSync.failed(node.name);
      await FormStateSync.publish(context, finalSnapshot);
      if (ok) {
        // 卡片路径保活：QuickToggleAbility 随后 terminateSelf，UI 进程的通知/监控
        // 会随之消失。这里立即拉起常驻通知（配合 VpnExtensionAbility 的长时任务），
        // 保证用户能看到"已连接"前台凭证；内核死亡由 EntryFormAbility 的
        // reconcile/updateForm 周期对账负责把卡片改回已断开。
        await TunBoxNotifier.update('TunBox 已连接', node.name, '↓ 0 B/s  ↑ 0 B/s');
        FormInfoMetrics.refreshAfterVpnTransition(context);
      }
      AppLogger.info(TAG, `quick ${mode} => ${ok ? 'on' : 'failed'} (node=${node.name})`);
      VpnQuickStart.lastReason = ok ? 'connect-ok' : 'connect-failed';
      return ok ? 'on' : 'failed';
    } catch (error) {
      const message = AppLogger.errText(error);
      AppLogger.error(TAG, `quick start failed: ${message}`);
      VpnQuickStart.lastReason = `exception(${message})`;
      try {
        finalSnapshot = await FormStateSync.calibrate(context);
        if (finalSnapshot.busy) {
          finalSnapshot = FormStateSync.failed(finalSnapshot.nodeName);
        }
        await FormStateSync.publish(context, finalSnapshot);
      } catch (publishError) {
        AppLogger.warn(TAG, `failed to publish terminal state: ${AppLogger.errText(publishError)}`);
      }
      return 'failed';
    }
  }
}
