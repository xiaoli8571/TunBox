/**
 * 页签宿主的「重新展示」通知桥（HdsTabs 根容器 → 各页签内容组件）。
 *
 * 背景：HomePage / SubscriptionPage 从 @Entry 路由页转为 HdsTabs 的 TabContent
 * 内容组件后，页面级 onPageShow 不再可用（仅 @Entry 支持）。宿主 MainPage 在自己的
 * onPageShow（从推入式子页返回）与页签切换时，通过本桥把「重新展示」事件转发给对应
 * 页签，页签内容据此执行原 onPageShow 语义的刷新（bootstrap）。
 *
 * 迟注册兜底：宿主先发出通知、内容组件尚未创建（TabContent 懒创建）时，事件挂起到
 * 组件注册处理器的瞬间立即补发，保证「首次切进页签」一定完成一次刷新。
 */
export class TabLifecycleBridge {
  private showHandler: (() => void) | null = null;
  private pendingShown: boolean = false;

  /** 内容组件在 aboutToAppear 注册处理；注册瞬间补发挂起事件 */
  setShowHandler(handler: (() => void) | null): void {
    this.showHandler = handler;
    if (handler !== null && this.pendingShown) {
      this.pendingShown = false;
      handler();
    }
  }

  /** 宿主调用：通知该页签「重新展示」（无处理器时挂起，待注册后补发） */
  notifyShown(): void {
    const handler = this.showHandler;
    if (handler === null) {
      this.pendingShown = true;
      return;
    }
    handler();
  }
}
