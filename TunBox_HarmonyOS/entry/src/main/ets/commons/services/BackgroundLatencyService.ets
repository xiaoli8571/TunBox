/**
 * 测速入口（FlClash 同构的薄适配层）
 *
 * ## 这一轮做了什么（2026-10-22）
 *
 * 旧实现自带一整套管线：内核组测（`GET /group/{name}/delay`）、离线 TCP 探活、
 * DNS 预解析判定、core_not_ready 连击作废、批次硬截止、5 分钟新鲜度跳过、
 * 冷启动静默全量测速。**这些 FlClash 都没有**（规格 §4.4），本文件按 1:1 撤销：
 *
 *  - 唯一引擎：`commons/flclash/FlclashDelay`（32 并发、逐节点 `/proxies/{n}/delay`、
 *    timeout=5000、URL 默认 https://www.gstatic.com/generate_204、-1 超时 / -2 失败）；
 *  - 组测速 = 组内所有节点**逐个测**（FlClash `delayTest(group.all)`）；
 *  - 没有任何自动/静默测速（`scheduleStartup` 保留为兼容入口，但不再发起探测）。
 *
 * 保留的语义（与 FlClash 一致的部分）：
 *  - 通道 = 当前内核（已连接用隧道核，未连接用无头测速核）；
 *  - 结果写入 `LatencyLiveView`（进程内），页面读同一份；
 *  - 通道不可用时**不写任何节点结论**。
 */
import { AppLogger } from '../utils/AppLogger';
import { ConnState, ConnectionOrchestrator } from './ConnectionOrchestrator';
import { LatencyLiveView } from './LatencyLiveView';
import { LatencyContext } from './LatencyState';
import { LatencyStoreBridge } from './LatencyStoreBridge';
import { IsolatedLatencyCore, IsolatedLatencyPorts } from './IsolatedLatencyCore';
import { CoreCatalog } from '../flclash/CoreCatalog';
import { DelayTarget } from '../flclash/FlclashDelay';
import { LatencyEngine, LatencyProgress } from './LatencyEngine';
import { ClashApiService } from './ClashApiService';
import { AppSettings } from '../models/AppSettings';
import { ProxyNode } from '../models/ProxyNode';
import { ProxyGroup } from '../models/ProxyGroup';
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';
import { effectiveTestUrl } from '../latency/LatencyProbe';
import { CoreCatalogService } from '../flclash/CoreCatalogService';
import { ProfileRepository } from '../flclash/ProfileRepository';
import { DelayPlan, ProxyPanelMembers } from '../flclash/ProxyPanelMembers';
import { ClashConfigGenerator } from './ClashConfigGenerator';
import { FlclashLatencyProgress, FlclashLatencyService } from '../flclash/FlclashLatencyService';

const TAG = 'BackgroundLatency';

export class BackgroundLatencyService {
  private static preparing: boolean = false;
  private static generation: number = 0;

  static isRunning(): boolean {
    return BackgroundLatencyService.preparing || FlclashLatencyService.isRunning() || LatencyEngine.isRunning();
  }

  static cancelCurrent(): void {
    BackgroundLatencyService.generation++;
    FlclashLatencyService.cancelCurrent();
  }

  /** Flat lists may span profiles. Every subset uses its own actual core context. */
  static async testNodes(context: Context, profileId: string, names: string[],
    onReady: (() => void) | null = null, source: string = 'manual'): Promise<LatencyProgress | null> {
    return BackgroundLatencyService.execute(context, profileId, onReady, '', names, source);
  }
  /**
   * 冷启动静默测速 —— **已按 FlClash 撤销**。
   *
   * FlClash 不会在启动时自动测速：延迟只在用户点「测速」（或托盘/快捷键）时产生。
   * 保留方法只为兼容既有调用点，实际不发起任何探测。
   */
  static scheduleStartup(_context: Context, _delayMs: number = 0): void {
    AppLogger.info(TAG, 'startup latency test is disabled (FlClash parity: latency only on user action)');
  }

  /** 静默测试全部节点（FlClash 无此行为；保留为显式调用入口） */
  static async testAll(context: Context): Promise<void> {
    await BackgroundLatencyService.execute(context, null);
  }

  /** 订阅刷新后测该订阅节点（FlClash 无自动测速；保留为显式调用入口） */
  static async testSubscription(context: Context, subscriptionId: string,
    onChannelReady: (() => void) | null = null, groupName: string = ''): Promise<LatencyProgress | null> {
    return await BackgroundLatencyService.execute(context, subscriptionId, onChannelReady, groupName);
  }

  /**
   * 预热测速通道（页面进入时后台调用）。
   * 与 FlClash 一致：只准备通道（拉起/复用内核），**不发起任何探测、不写结论**。
   */
  static async prewarmChannel(context: Context): Promise<void> {
    try {
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);
      await SettingsService.init(context);
      const subs = SubscriptionService.instance();
      await subs.init(context);
      await orchestrator.prewarmLatencyChannel();
    } catch (e) {
      AppLogger.warn(TAG, `latency channel prewarm failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 兼容旧调用点：手动测速优先（新引擎单航班，新批自然抢占旧批） */
  static beginManualPriority(): void {
    BackgroundLatencyService.cancelCurrent();
  }

  static endManualPriority(_context: Context): void {
  }

  static isManualPriorityActive(): boolean {
    return false;
  }

  /** 本批测速 URL（唯一真源 `effectiveTestUrl`，默认 gstatic https 204） */
  static resolveTestUrl(settings: AppSettings): string {
    return effectiveTestUrl(settings);
  }

  /**
   * 组测速（订阅页行尾按钮 / 节点页「测全部」共用）。
   *
   * FlClash 的组测速 = 组内所有节点逐个测，**不是** `GET /group/{name}/delay`。
   * 进度字段与旧 `LatencyProgress` 保持兼容（页面不用改）。
   */
  static async runKernelGroupTest(api: ClashApiService, nodes: ProxyNode[], url: string,
    _source: string, expected: string = ''): Promise<LatencyProgress> {
    const progress = new LatencyProgress();
    progress.total = nodes.length;
    progress.running = true;
    if (nodes.length === 0) {
      progress.running = false;
      return progress;
    }
    // FlClash 的组测速用的是**内核组里**的成员名（`group.all`），不是 App 侧列表：
    // 原文接管 proxy-groups 后，两边的名字只有一处真源 —— 内核。
    // 走快照 TTL：组测速前强制重拉 /proxies 对 600 节点是多花一次 80KB 网络+解析，
    // 而节点集在用户点测速的这一两秒内不会变（订阅刷新走自己的重建路径）。
    const model = await CoreCatalogService.refresh(api, false);
    const names: string[] = [];
    if (model !== null) {
      for (const node of CoreCatalogService.flattenNodes('rule')) {
        names.push(node.name);
      }
    }
    if (names.length === 0) {
      for (const node of nodes) {
        names.push(node.name);
      }
    }
    progress.total = names.length;
    await BackgroundLatencyService.runWithCatalog(api, names, url, expected, progress);
    return progress;
  }

  /** 用内核目录里的节点名跑一批（FlClash 的节点名就是内核名）。 */
  static async runNames(api: ClashApiService, names: string[], url: string, expected: string,
    onChannelReady: (() => void) | null = null): Promise<LatencyProgress> {
    const progress = new LatencyProgress();
    progress.total = names.length;
    progress.running = true;
    if (names.length === 0) {
      progress.running = false;
      return progress;
    }
    if (onChannelReady !== null) {
      onChannelReady();
    }
    await BackgroundLatencyService.runWithCatalog(api, names, url, expected, progress);
    return progress;
  }

  private static async runWithCatalog(api: ClashApiService, names: string[], url: string,
    expected: string, progress: LatencyProgress): Promise<void> {
    // 跨引擎互斥（2026-10-24 P1 修复）：手动组测直调本方法（不走 execute 的双检），
    // 与 LatencyEngine 批次重叠时两引擎合计 64 在途打同一个内核 API（栈内并发 ~8），
    // 互相制造假超时 + runId 清标交叉。Flclash 自身的旧批允许被新批抢占（start 内
    // cancel），但**另一引擎**在跑时必须让行。
    if (LatencyEngine.isRunning()) {
      progress.cancelled = names.length;
      progress.running = false;
      AppLogger.info(TAG, 'kernel group test skipped: LatencyEngine batch in flight');
      return;
    }
    const profileId = ProfileRepository.currentId();
    const revision = ProfileRepository.revisionOf(profileId);
    const session = FlclashLatencyService.start(api, names, url, 'manual', null, expected,
      new LatencyContext(profileId, revision, url, expected), (): boolean =>
        profileId === ProfileRepository.currentId() && revision === ProfileRepository.revisionOf(profileId));
    const summary: FlclashLatencyProgress = await session.wait();
    progress.total = summary.total;
    progress.finished = summary.started;
    progress.measured = summary.measured;
    progress.timeout = summary.timeout;
    progress.failed = summary.failed;
    progress.cancelled = summary.cancelled;
    progress.channel = 'core';
    progress.running = false;
    LatencyLiveView.flushNow();
    AppLogger.info(TAG, `delay batch done: total=${progress.total} measured=${summary.measured} `
      + `timeout=${summary.timeout} failed=${summary.failed} cancelled=${summary.cancelled}`);
  }

  /**
   * 执行一次批次（显式调用入口；FlClash 由用户手势触发）。
   *
   * @param subscriptionId null = 当前 profile 的全部节点
   */
  private static async execute(context: Context, subscriptionId: string | null,
    onChannelReady: (() => void) | null = null, groupName: string = '',
    names: string[] | null = null, source: string = 'manual'): Promise<LatencyProgress | null> {
    if (BackgroundLatencyService.preparing || LatencyEngine.isRunning() || FlclashLatencyService.isRunning()) {
      return null;
    }
    BackgroundLatencyService.preparing = true;
    const generation = ++BackgroundLatencyService.generation;
    let isolated = false;
    let ownsIsolated = false;
    try {
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);
      await SettingsService.init(context);
      const subs = SubscriptionService.instance();
      await subs.init(context);
      const profileId = subscriptionId ?? ProfileRepository.currentId();
      if (profileId.length === 0 || !subs.subscriptions.some((sub): boolean => sub.id === profileId)) { return null; }
      const revision = ProfileRepository.revisionOf(profileId);
      const settings = await SettingsService.load();
      isolated = profileId !== ProfileRepository.currentId()
        || (orchestrator.state === ConnState.CONNECTED && orchestrator.appliedProfile() !== profileId);
      const current = (): boolean => generation === BackgroundLatencyService.generation
        && revision === ProfileRepository.revisionOf(profileId)
        && subs.subscriptions.some((sub): boolean => sub.id === profileId)
        && (isolated ? IsolatedLatencyCore.networkCurrent()
          : profileId === ProfileRepository.currentId() && profileId === orchestrator.appliedProfile());
      let api: ClashApiService | null = null;
      if (isolated) {
        api = await IsolatedLatencyCore.open(context,
          async (ports: IsolatedLatencyPorts, secret: string): Promise<string> =>
            orchestrator.buildIsolatedLatencyYaml(profileId, settings,
              ports.apiPort, ports.mixedPort, ports.dnsPort, secret));
        ownsIsolated = true;

      } else {
        const deadline = Date.now() + 9000;
        while (Date.now() < deadline) {
          api = await orchestrator.ensureLatencyApi(true);
          if (api !== null) { break; }
          await new Promise<void>((resolve) => setTimeout(resolve, 1500));
        }
      }
      if (api === null) { throw new Error('测速通道未就绪，请稍后重试'); }
      if (!current()) { throw new Error('订阅或网络已变化，请重新测速'); }
      if (isolated || orchestrator.state !== ConnState.CONNECTED) {
        await CoreCatalogService.restoreGroupSelections(api, profileId, settings.proxyGroupSelections, current);
      }
      const json = isolated ? await api.proxiesJson() : null;
      const model = isolated ? (json === null ? null : CoreCatalog.parse(json))
        : await CoreCatalogService.refresh(api, true, profileId, current);
      if (model === null || !current()) { throw new Error('无法获取该订阅的内核节点目录，请稍后重试'); }
      CoreCatalogService.rememberProfile(profileId, revision, model);
      const groups = subs.groupsOf(profileId);
      const selectedGroup = groupName || (groups.length > 0 ? groups[0].name : '');
      const url = BackgroundLatencyService.resolveTestUrl(settings);
      const plan = names === null ? ProxyPanelMembers.delayPlan(model, selectedGroup,
        ClashConfigGenerator.SMART_GROUP_NAME, url, '', groups) : new DelayPlan();
      if (names !== null) {
        const seen: Set<string> = new Set<string>();
        for (const name of names) {
          const target = ProxyPanelMembers.delayTarget(model, name, '', url, '', groups);
          if (target === null) { plan.skipped++; continue; }
          if (seen.has(target.key())) { continue; }
          seen.add(target.key()); plan.targets.push(target); plan.names.push(target.name);
        }
      }
      const progress = new LatencyProgress();
      progress.skipped = plan.skipped;
      if (plan.targets.length === 0) {
        progress.message = plan.skipped > 0
          ? `该分组有 ${plan.skipped} 个成员未加载或没有可用出口，请稍后重试`
          : '该分组没有可测速的成员';
        return progress;
      }
      const targets: DelayTarget[] = [];
      for (const target of plan.targets) {
        targets.push(new DelayTarget(target.name, target.url, '', target.expected, api.providerForProxy(target.name)));
      }
      if (LatencyEngine.isRunning() || FlclashLatencyService.isRunning()) { return null; }
      if (onChannelReady !== null) { onChannelReady(); }
      const scope = new LatencyContext(profileId, revision, url);
      const session = FlclashLatencyService.startTargets(api, targets, source, scope, current);
      const summary = await session.wait();
      progress.total = summary.total;
      progress.finished = summary.started;
      progress.measured = summary.measured;
      progress.timeout = summary.timeout;
      progress.failed = summary.failed;
      progress.cancelled = summary.cancelled;
      progress.channel = 'core';
      if (!current()) {
        progress.message = '订阅或网络已变化，本次测速已取消，请重试';
        return progress;
      }
      await LatencyStoreBridge.ensureStore(context);
      for (const target of targets) {
        const targetScope = new LatencyContext(profileId, revision, target.testUrl, target.expected);
        await LatencyStoreBridge.persistConclusions([target.proxyName], targetScope);
      }
      if (summary.cancelled > 0 && summary.measured + summary.timeout + summary.failed === 0) {
        progress.message = `测速未完成：${summary.cancelled} 个目标没有取得内核响应，已保留上次结果`;
      }
      LatencyLiveView.flushNow();
      return progress;
    } catch (error) {
      AppLogger.warn(TAG, `delay batch failed: ${AppLogger.errText(error)}`);
      const progress = new LatencyProgress();
      progress.message = AppLogger.errText(error);
      return progress;
    } finally {
      if (ownsIsolated) { await IsolatedLatencyCore.close(); }
      BackgroundLatencyService.preparing = false;
    }
  }
}
