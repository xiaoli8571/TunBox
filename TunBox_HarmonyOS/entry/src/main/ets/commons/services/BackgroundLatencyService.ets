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
import { ConnectionOrchestrator } from './ConnectionOrchestrator';
import { LatencyLiveView } from './LatencyLiveView';
import { LatencyEngine, LatencyProgress } from './LatencyEngine';
import { ClashApiService } from './ClashApiService';
import { AppSettings } from '../models/AppSettings';
import { ProxyNode } from '../models/ProxyNode';
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';
import { effectiveTestUrl } from '../latency/LatencyProbe';
import { CoreCatalogService } from '../flclash/CoreCatalogService';
import { FlclashLatencyProgress, FlclashLatencyService } from '../flclash/FlclashLatencyService';

const TAG = 'BackgroundLatency';

export class BackgroundLatencyService {
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
    onChannelReady: (() => void) | null = null): Promise<LatencyProgress | null> {
    return await BackgroundLatencyService.execute(context, subscriptionId, onChannelReady);
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
    FlclashLatencyService.cancelCurrent();
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
    _source: string): Promise<LatencyProgress> {
    const progress = new LatencyProgress();
    progress.total = nodes.length;
    progress.running = true;
    if (nodes.length === 0) {
      progress.running = false;
      return progress;
    }
    // FlClash 的组测速用的是**内核组里**的成员名（`group.all`），不是 App 侧列表：
    // 原文接管 proxy-groups 后，两边的名字只有一处真源 —— 内核。
    const model = await CoreCatalogService.refresh(api, true);
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
    await BackgroundLatencyService.runWithCatalog(api, names, url, progress);
    return progress;
  }

  /** 用内核目录里的节点名跑一批（FlClash 的节点名就是内核名）。 */
  static async runNames(api: ClashApiService, names: string[], url: string,
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
    await BackgroundLatencyService.runWithCatalog(api, names, url, progress);
    return progress;
  }

  private static async runWithCatalog(api: ClashApiService, names: string[], url: string,
    progress: LatencyProgress): Promise<void> {
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
    const session = FlclashLatencyService.start(api, names, url, 'manual', null);
    const summary: FlclashLatencyProgress = await session.wait();
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
    onChannelReady: (() => void) | null = null): Promise<LatencyProgress | null> {
    if (LatencyEngine.isRunning() || FlclashLatencyService.isRunning()) {
      AppLogger.info(TAG, 'silent batch skipped: a latency run is already in flight');
      return null;
    }
    try {
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);
      await SettingsService.init(context);
      const subs = SubscriptionService.instance();
      await subs.init(context);
      if (subs.subscriptions.length === 0) {
        return null;
      }
      // 【2026-10-24 体验修复】冷启动自动重连/prewarm 正在准备通道的头几秒，
      // 用户点测速会撞上「通道未就绪」被立即拒绝（真机取证：17:53:46 被拒、
      // 17:53:52 隧道就绪、17:54:34 手动批正常——中间只差几秒）。改为短暂
      // 等待重试：通道就绪后正常开测，而不是让用户自己掐时间再点一次。
      // 9s 窗口足够覆盖隧道建立（connect timing ~2-5s）；负缓存/内核真起不来
      // 的场景重试也无害，到点如实报错。
      let api: ClashApiService | null = null;
      const channelDeadline = Date.now() + 9000;
      while (Date.now() < channelDeadline) {
        api = await orchestrator.ensureLatencyApi(true);
        if (api !== null) {
          break;
        }
        if (LatencyEngine.isRunning() || FlclashLatencyService.isRunning()) {
          // 等待期间真有批次开始了（另一个入口先到）：直接让行退出
          AppLogger.info(TAG, 'delay batch skipped: another run started while waiting for channel');
          return null;
        }
        await new Promise<void>((resolve) => setTimeout(() => resolve(), 1500));
      }
      if (api === null) {
        AppLogger.warn(TAG, 'delay batch skipped: kernel channel unavailable');
        throw new Error('测速通道未就绪（代理连接建立中或测速内核未启动），请稍后重试');
      }
      // 节点名来自内核目录（FlClash 同构：App 不持有节点清单）
      const model = await CoreCatalogService.refresh(api, true);
      if (model === null) {
        AppLogger.warn(TAG, 'delay batch skipped: /proxies unavailable');
        return null;
      }
      const settings = await SettingsService.load();
      const url = BackgroundLatencyService.resolveTestUrl(settings);
      const nodes = CoreCatalogService.flattenNodes(settings.proxyMode);
      const names: string[] = [];
      for (const node of nodes) {
        names.push(node.name);
      }
      if (subscriptionId !== null && names.length === 0) {
        return null;
      }
      return await BackgroundLatencyService.runNames(api, names, url, onChannelReady);
    } catch (e) {
      AppLogger.warn(TAG, `silent batch failed: ${AppLogger.errText(e)}`);
      return null;
    }
  }
}
