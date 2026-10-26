/**
 * MainPage —— 应用主容器页（自绘悬浮导航栏，严格对齐《TunBox-UI重构笔记》§2.2）
 *
 * 2026-10-17 UI 重构（用户决策「完全按文档」）：移除 HdsTabs 系统沉浸材质页签，
 * 改为自绘悬浮栏（2026-10-17 用户要求回到三页签：主页 / 订阅 / 设置；规则页走
 * router 推入式子页，与节点/连接等页同级）。
 * 2026-10-26 用户最终定稿：底栏「完全透明」—— 栏体零渲染（无填充/无模糊/无描边/无投影），
 * 只留页签项浮在内容之上；见 components/FloatingBottomBar.ets 头注释。
 * 因此不再有宽屏侧边页签形态（文档未定义该形态），四种窗口尺寸共用同一底部悬浮栏。
 *
 * 页面容器（与旧版宿主语义一致，只是页签栏换成自绘）：
 *  - 内容层：四个页签组件按需创建（visited 懒挂载）后常驻（visibility 切换），
 *    保持旧 TabContent 的懒创建 + keep-alive 行为，避免启动时四页同时 bootstrap；
 *  - 悬浮栏：Stack(alignContent: Bottom) 浮在内容之上，内容自然延伸到栏体之下
 *    （透明栏才有可透内容，栏体不会退化成实色圆角片）；
 *  - 刷新桥：切页签 / 从推入式子页返回时，用 TabLifecycleBridge 通知对应页签执行
 *    原 onPageShow 语义的刷新（桥的迟注册兜底覆盖「首次进入」）；
 *  - 跨页跳转：AppStorage 'tb_main_tab' 是页签真相源（@StorageLink），
 *    首页「规则管理」卡片等入口写该键即可切到目标页签。
 */
import { FloatingBottomBar } from '../components/FloatingBottomBar';
import { TunBoxColors, TunBoxGeometry, TunBoxMotion } from '../theme/TunBoxTokens';
import { TabLifecycleBridge } from '../commons/utils/TabLifecycleBridge';
import { AppLogger } from '../commons/utils/AppLogger';
import { HomePage } from './HomePage';
import { SubscriptionPage } from './SubscriptionPage';
import { SettingsView } from './SettingsPage';

const TAG = 'MainPage';
/** 页签数：主页 / 订阅 / 设置 */
const TAB_COUNT = 3;
const TAB_HOME = 0;
const TAB_SUBS = 1;
const TAB_SETTINGS = 2;

@Entry
@Component
struct MainPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  /** 当前页签（AppStorage 真相源：外部入口可写 'tb_main_tab' 直接跳页签） */
  @StorageLink('tb_main_tab') @Watch('onTabChanged') activeIndex: number = TAB_HOME;
  /** 已创建过的页签（懒挂载 + 常驻） */
  @State private visited: boolean[] = [true, false, false];
  /** 页签切入方向：+1 向右切（新页从右滑入），-1 向左切（新页从左滑入） */
  @State private slideDir: number = 1;
  private prevTab: number = TAB_HOME;
  /** 页签内容与宿主之间的「重新展示」桥（替代原各页 onPageShow 语义） */
  private homeBridge: TabLifecycleBridge = new TabLifecycleBridge();
  private subsBridge: TabLifecycleBridge = new TabLifecycleBridge();
  private settingsBridge: TabLifecycleBridge = new TabLifecycleBridge();

  onPageShow(): void {
    // 从推入式子页（节点 / 连接 / 应用分流 / 网站分流等）返回时刷新当前页签
    this.notifyTab(this.activeIndex);
  }

  private onTabChanged(): void {
    const dir = this.activeIndex === this.prevTab ? 0 : (this.activeIndex > this.prevTab ? 1 : -1);
    if (dir !== 0) {
      this.slideDir = dir;
    }
    this.prevTab = this.activeIndex;
    this.notifyTab(this.activeIndex);
  }

  /**
   * 底栏点击入口（替代底栏直接写页签）：先落方向、下一帧再切页签。
   *
   * 反向切页原先没有动画的根因：方向与页签在同一帧内改动时，退出中的旧页面
   * 用的还是上一次渲染绑定的 transition（旧方向），新旧两页位移方向互相抵消，
   * 看起来就像没动画。隔一帧再切页签，退出效果一定吃到新方向。
   */
  private selectTab(index: number): void {
    if (index === this.activeIndex) {
      return;
    }
    this.slideDir = index > this.activeIndex ? 1 : -1;
    setTimeout((): void => {
      this.activeIndex = index;
    }, 0);
  }

  /** 懒挂载 + 通知目标页签「重新展示」（未创建时由桥挂起，创建后再补发） */
  private notifyTab(index: number): void {
    if (index < 0 || index >= TAB_COUNT) {
      AppLogger.warn(TAG, `unknown tab index ${index}, fallback to home`);
      this.activeIndex = TAB_HOME;
      return;
    }
    if (!this.visited[index]) {
      const next: boolean[] = this.visited.slice();
      next[index] = true;
      this.visited = next;
    }
    this.bridgeOf(index).notifyShown();
  }

  private bridgeOf(index: number): TabLifecycleBridge {
    if (index === TAB_SUBS) {
      return this.subsBridge;
    }
    if (index === TAB_SETTINGS) {
      return this.settingsBridge;
    }
    return this.homeBridge;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Stack() {
        if (this.visited[TAB_HOME]) {
          HomePage({ shownBridge: this.homeBridge })
            .width('100%').height('100%')
            .visibility(this.activeIndex === TAB_HOME ? Visibility.Visible : Visibility.None)
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slideDir * TunBoxMotion.slideVp }))
                .animation({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve }),
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slideDir * -TunBoxMotion.slideVp }))
                .animation({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })))
        }
        if (this.visited[TAB_SUBS]) {
          SubscriptionPage({ shownBridge: this.subsBridge })
            .width('100%').height('100%')
            .visibility(this.activeIndex === TAB_SUBS ? Visibility.Visible : Visibility.None)
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slideDir * TunBoxMotion.slideVp }))
                .animation({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve }),
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slideDir * -TunBoxMotion.slideVp }))
                .animation({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })))
        }
        if (this.visited[TAB_SETTINGS]) {
          SettingsView({ shownBridge: this.settingsBridge })
            .width('100%').height('100%')
            .visibility(this.activeIndex === TAB_SETTINGS ? Visibility.Visible : Visibility.None)
            .transition(TransitionEffect.asymmetric(
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slideDir * TunBoxMotion.slideVp }))
                .animation({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve }),
              TransitionEffect.OPACITY.combine(TransitionEffect.translate({ x: this.slideDir * -TunBoxMotion.slideVp }))
                .animation({ duration: TunBoxMotion.ms, curve: TunBoxMotion.curve })))
        }
      }
      .width('100%')
      .height('100%')

      // 底部渐隐底（2026-10-26 用户要求「稍微加一点点底色」）：底栏本体仍然完全透明，
      // 这里只在底部铺一条全宽、无模糊的页面底色渐隐，让滚动内容进入底栏前自然淡出，
      // 不再和底栏图标/文字重叠；颜色=页面渐变终点色的不同 alpha，与页面底色无缝衔接。
      // 0.42 起过渡、0.68 处已接近不透明（≈0.94）——底栏图标所在的 40~70vp 带里
      // 内容只剩几个百分点的残影，再往上才是柔和淡出，视觉上像页面底部自然淡出。
      Column()
        .width('100%')
        .height(TunBoxGeometry.dockScrimHeight)
        .linearGradient({
          angle: 180,
          colors: [
            [TunBoxColors.dockScrimTop, 0.0],
            [TunBoxColors.dockScrimMid, 0.42],
            [TunBoxColors.dockScrimBottom, 0.68],
            [TunBoxColors.dockScrimBottom, 1.0]
          ]
        })
        // 只做视觉遮挡，不吃触摸：内容区（含底栏下方）照常可点可滚
        .hitTestBehavior(HitTestMode.None)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])

      // 底部悬浮导航栏（文档 §2.2，浮在内容之上，栏体完全透明）
      FloatingBottomBar({
        currentTab: this.activeIndex,
        onSelect: (index: number): void => { this.selectTab(index); }
      })
    }
    .width('100%')
    .height('100%')
    .linearGradient({ angle: 180, colors: [[TunBoxColors.bgGradientStart, 0.0], [TunBoxColors.bgGradientEnd, 1.0]] })
    // 根渐变铺进状态栏/手势条安全区：切页动画期间不再露出窗口白底（2026-10-17 修「顶部/底栏闪浅白」）
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
