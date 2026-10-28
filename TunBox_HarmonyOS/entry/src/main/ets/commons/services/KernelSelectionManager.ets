import { ClashApiService, KernelGroupSelection } from './ClashApiService';
import { ConnectionTarget, ConnectionTargetSource } from '../config/RuntimeConfigBuilder';

/**
 * 内核出口状态管理器（2026-10-27 架构收口：从 `ConnectionOrchestrator` 拆出的第一块）。
 *
 * ## 职责边界（刻意做窄）
 * - **只**负责问内核「主出口组现在是什么」，并持有最近一次确认过的 `ConnectionTarget`；
 * - 不读写设置、不碰 UI、不参与连接流程编排 —— 因此可以独立测试、独立复用。
 *
 * ## 为什么需要它
 * 旧实现里「当前是什么节点」散在三处：TunBox 节点列表、`settings.preferredNode*`、
 * 最终 YAML 的组结构。三者会漂移（真机：UI 香港 / 内核新加坡）。现在这些判断收敛到
 * 一个对象，`ConnectionOrchestrator` 只通过它取"当前出口"。
 */
export class KernelSelectionManager {
  private target: ConnectionTarget | null = null;
  /** 查询互斥：避免 /proxies 轮询堆积。 */
  private polling: boolean = false;

  /** 最近一次确认过的出口；null = 尚未确认过任何出口。 */
  current(): ConnectionTarget | null {
    return this.target;
  }

  /** 当前出口节点名；未确认时为空串。 */
  nodeName(): string {
    return this.target === null ? '' : this.target.nodeName;
  }

  /** 当前出口所在组名；未确认时为空串。 */
  groupName(): string {
    return this.target === null ? '' : this.target.groupName;
  }

  /** 展示用「组 → 节点」。 */
  label(): string {
    return this.target === null ? '' : this.target.label();
  }

  /** 记录一次已确认的出口（连接成功 / 内核回报）。 */
  set(target: ConnectionTarget): void {
    this.target = target;
  }

  clear(): void {
    this.target = null;
  }

  /** 读内核某组的当前状态（薄封装，便于替换实现与单测）。 */
  async read(api: ClashApiService | null, groupName: string): Promise<KernelGroupSelection | null> {
    if (api === null) { return null; }
    return api.readKernelSelection(groupName);
  }

  /** 该组里第一个可钉的叶子节点名（兜底用）。 */
  async pickLeaf(api: ClashApiService | null, groupName: string): Promise<string | null> {
    if (api === null) { return null; }
    return api.selectLeafFromKernelGroup(groupName);
  }

  /**
   * 与内核对齐一次：
   * 主组 `now` 是合法叶子且与当前记录不同 → 更新记录并返回**新目标**；否则返回 null。
   * 返回 null 表示「没有新事实」，调用方不需要刷新 UI。
   */
  async syncFromKernel(api: ClashApiService | null, groupName: string,
    profileId: string = ''): Promise<ConnectionTarget | null> {
    if (api === null || this.polling) { return null; }
    this.polling = true;
    try {
      const sel = await api.readKernelSelection(groupName);
      if (sel === null || !sel.nowIsLeaf) { return null; }
      if (this.target !== null && this.target.nodeName === sel.now) { return null; }
      this.target = new ConnectionTarget(sel.group, sel.now, ConnectionTargetSource.KERNEL,
        profileId, Date.now());
      return this.target;
    } finally {
      this.polling = false;
    }
  }
}
