/**
 * 安全区 / 手势区实测（2026-10-30 用户报障：底部系统导航条是一条实色带，和 Dock 割裂）。
 *
 * ## 问题是什么
 * 用户截图取证（621×154 的底部裁切）里，Dock 玻璃往下是一条**硬边**的深色带，
 * 带里躺着手势指示条。逐像素采样能算出这条带的真实来源：
 *   带内 = (11,14,22)，页面渐变终点 = `#0F131D` = (15,19,29)，
 *   15×0.75=11.25、19×0.75=14.25、29×0.75=21.75 —— **三个通道全部吻合 0.75**。
 * 也就是说：页面渐变其实已经画进那条带了（`expandSafeArea` 生效），
 * 是**系统在导航条窗口上又压了一层 25% 的黑**。这层遮罩 App 用
 * `navigationBarColor` 关不掉（0.7.5 已经把它设成 `#00000000` 了，仍然在）。
 *
 * ## 怎么关
 * 唯一开关是**窗口级沉浸式布局**（`setWindowLayoutFullScreen(true)`）：
 * 非沉浸式时系统把底部那一条当成「它的地盘」，自己画一层底以保证手势条可见；
 * 沉浸式之后这条归属 App，透明才是真的透明（内容能从手势条底下滚过）。
 * 见 `EntryAbility.onWindowStageCreate`。
 *
 * ## 沉浸式带来的两个副作用，必须在这里补回来
 * 沉浸式 = 布局**不再自动避让**状态栏/导航条（窗口接口文档原文：
 * 「immersive layout means that the layout does not avoid the status bar ... and
 * components may overlap with them」）。于是：
 *   ① 顶部：所有页的顶栏会钻到状态栏（时钟/电量）底下 → 需要 `topPad()` 让回来；
 *   ② 底部：Dock 会贴到屏幕最底边（等于没有底部外边距）→ 需要 `dockGap()` 抬回来。
 *
 * ## 为什么还要 `calibrate()`（自校准）
 * 「沉浸式之后到底还避让不避让」在不同 ROM/不同 API 版本上并不一致：
 * 有的版本沉浸式后布局仍然按页面安全区排（`safeAreaPadding` 模型），有的就不避让了。
 * 写死任一假设，都会在另一类设备上翻车（要么顶栏被时钟压住，要么顶栏凭空多出一条）。
 * 所以这里**实测**一次：拿页面里一个 `100%` 高度、**没挂 `expandSafeArea`** 的容器
 * 量它的 vp 高度，和整屏 vp 高度比：
 *   - 容器高度 ≈ 整屏        ⇒ 不避让（沉浸式真正生效）→ 顶栏补 `insetTop`，Dock 直接贴底 + gap；
 *   - 容器高度 < 整屏 − 2vp  ⇒ 仍在避让 → 顶栏不补，Dock 用 `translate` 往下沉到目标位置。
 * 两种情况最后落在**同一个视觉位置**：Dock 底边距屏幕底边 `dockGap`，顶栏距屏幕顶边 `insetTop`。
 *
 * ## 发布到 AppStorage 的键
 * | 键 | 含义 |
 * |---|---|
 * | `tb_inset_top`     | 状态栏（挖孔）实测高度 vp |
 * | `tb_inset_bottom`  | 底部手势区实测高度 vp（TYPE_SYSTEM 与 TYPE_NAVIGATION_INDICATOR 取大） |
 * | `tb_avoid_active`  | 布局是否仍在避让系统栏（自校准结果） |
 * | `tb_dock_gap`      | Dock 底边到屏幕底边的目标间距 vp |
 * | `tb_dock_margin`   | Dock 实际用的 `margin.bottom`（避让时 0，不避让时 = gap） |
 * | `tb_dock_sink`     | Dock 的下沉量（避让时 = insetBottom − gap，不避让时 0） |
 * | `tb_dock_clearance`| 内容底部要为 Dock 预留的高度（从内容容器底边算） |
 *
 * 值有变化时递增 `theme_revision`：所有页面都是 `@StorageLink('theme_revision')`，
 * 一次递增即可让顶栏留白 / Dock 位置 / 内容留白**同帧**重排，不会出现半帧错位。
 */
import { display, window } from '@kit.ArkUI';
import { AppLogger } from '../commons/utils/AppLogger';

const TAG = 'SafeArea';

/** Dock 高度（与 TunBoxGeometry.dockHeight 同值；本文件不 import tokens，避免循环依赖） */
const DOCK_HEIGHT: number = 64;
/**
 * 内容底边与 Dock 顶边之间的呼吸值。
 * 不能小：Dock 的 `backgroundEffect` 模糊半径是 26vp，内容（末张卡片 + 投影）一旦进入
 * 这个半径，玻璃栏内上半就会被抹暗 —— 就是 2026-10-29 修过的「底框一半是阴影」。
 * 40vp 给足余量（当年写死 112 的等效余量约 48vp，现在按实测手势区算更紧一点但仍在安全侧）。
 */
const DOCK_BREATH: number = 40;
/** 内容底部留白的下限：不低于旧写死值 112，避免回归「末张卡片卡在栏口」 */
const CLEARANCE_FLOOR: number = 112;
/**
 * 顶栏往下让白时，从状态栏高度里扣回来的量（2026-10-30 二修）。
 * 顶栏行高 56vp、标题垂直居中 ⇒ 行内上下各留 (56−标题行高)/2 ≈ 12~14vp。
 * 扣掉这一半，标题上沿就贴到状态栏下沿 8vp 处，不再空一条。
 * 上限：不得超过行内留白，否则标题会顶进状态栏。
 */
const TOP_TRIM: number = 12;
/** 量到的 vp 与整屏 vp 差多少以内算「没避让」（像素取整误差，2vp 足够） */
const AVOID_EPSILON: number = 2;

export class SafeArea {
  static readonly KEY_TOP: string = 'tb_inset_top';
  static readonly KEY_BOTTOM: string = 'tb_inset_bottom';
  /** true = 布局仍自动避让系统栏；false = 沉浸式已生效，布局钻进系统栏下面 */
  static readonly KEY_AVOID: string = 'tb_avoid_active';
  static readonly KEY_DOCK_GAP: string = 'tb_dock_gap';
  static readonly KEY_DOCK_MARGIN: string = 'tb_dock_margin';
  static readonly KEY_DOCK_SINK: string = 'tb_dock_sink';
  static readonly KEY_CLEARANCE: string = 'tb_dock_clearance';
  /** 整屏高度 vp（自校准里量到的那次；顶部渐变模糊的渐隐比例要用） */
  static readonly KEY_SCREEN_VP: string = 'tb_screen_vp';

  private static density: number = 3;
  private static calibrated: boolean = false;
  private static lastBoxHeightVp: number = 0;
  private static listening: boolean = false;

  /** px → vp。`display.densityPixels` 就是 1vp 对应的 px 数，和 UIContext.px2vp 同口径。 */
  private static px2vp(px: number): number {
    const d: number = SafeArea.density > 0 ? SafeArea.density : 3;
    return px / d;
  }

  /**
   * 绑定主窗口：先量一次，再订阅避让区变化（转屏、三键/手势切换、悬浮导航开启都会触发）。
   * 必须在 `setWindowLayoutFullScreen(true)` 之后调用，否则量到的是切换前的值。
   */
  static init(win: window.Window): void {
    SafeArea.measure(win);
    if (SafeArea.listening) {
      return;
    }
    SafeArea.listening = true;
    try {
      win.on('avoidAreaChange', (options: window.AvoidAreaOptions): void => {
        // 任何一类避让区变化都重算一遍：三键导航 ↔ 手势导航、折叠屏展开、悬浮导航开关
        SafeArea.measure(win);
        SafeArea.publish();
        AppLogger.info(TAG, `avoidAreaChange type=${options.type}`);
      });
    } catch (e) {
      // 老系统上事件名/回调形态可能不同：拿不到就只在启动时量一次
      AppLogger.warn(TAG, `avoidAreaChange subscribe failed: ${AppLogger.errText(e)}`);
    }
  }

  /** 量一次上下避让区，写进 AppStorage（还没校准过时也要先发布，让首帧尽量接近目标值）。 */
  static measure(win: window.Window): void {
    try {
      const d = display.getDefaultDisplaySync();
      if (d.densityPixels > 0) {
        SafeArea.density = d.densityPixels;
      }
    } catch (e) {
      AppLogger.warn(TAG, `display probe failed: ${AppLogger.errText(e)}`);
    }
    let topPx: number = 0;
    let bottomPx: number = 0;
    try {
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      topPx = sys.topRect.height;
      bottomPx = sys.bottomRect.height;
    } catch (e) {
      AppLogger.warn(TAG, `getWindowAvoidArea(SYSTEM) failed: ${AppLogger.errText(e)}`);
    }
    // 手势指示条单独一类：某些版本上 TYPE_SYSTEM 的 bottomRect 是 0，真实的手势区只在这里
    try {
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      if (indicator.bottomRect.height > bottomPx) {
        bottomPx = indicator.bottomRect.height;
      }
    } catch (e) {
      // 旧系统没有这一类：忽略，用 TYPE_SYSTEM 的值
    }
    const topVp: number = SafeArea.px2vp(topPx);
    const bottomVp: number = SafeArea.px2vp(bottomPx);
    // 顶部单独变化时 Dock 几何可能完全不变，仍须通知依赖静态 helper 的页面重排。
    SafeArea.setNumber(SafeArea.KEY_TOP, topVp);
    SafeArea.setNumber(SafeArea.KEY_BOTTOM, bottomVp);
    AppLogger.info(TAG, `insets top=${topVp.toFixed(1)}vp bottom=${bottomVp.toFixed(1)}vp`);
  }

  /**
   * 自校准（见文件头）。参数是页面里一个「100% 高、没挂 expandSafeArea」容器的实测高度 vp。
   * 只认第一次非零测量，之后不再改判（避免动画/键盘弹出引起的抖动反复翻转）。
   */
  static calibrate(boxHeightVp: number): void {
    if (boxHeightVp <= 0) {
      return;
    }
    let screenVp: number = 0;
    try {
      const d = display.getDefaultDisplaySync();
      screenVp = SafeArea.px2vp(d.height);
    } catch (e) {
      return;
    }
    if (screenVp <= 0) {
      return;
    }
    const avoid: boolean = boxHeightVp < screenVp - AVOID_EPSILON;
    // 首次 onAreaChange 可能发生在沉浸式切换完成前；允许后续稳定测量修正判断。
    // 小幅变化通常来自布局动画，忽略它们，避免无意义重排。
    if (SafeArea.calibrated && Math.abs(boxHeightVp - SafeArea.lastBoxHeightVp) < 8 &&
      avoid === SafeArea.avoidActive()) {
      return;
    }
    SafeArea.calibrated = true;
    SafeArea.lastBoxHeightVp = boxHeightVp;
    // 整屏高度（vp）也发布：顶部渐隐比例要适配不同屏幕。
    SafeArea.setNumber(SafeArea.KEY_SCREEN_VP, Math.round(screenVp));
    AppStorage.setOrCreate<boolean>(SafeArea.KEY_AVOID, avoid);
    SafeArea.publish();
    AppLogger.info(TAG,
      `calibrate: box=${boxHeightVp.toFixed(1)}vp screen=${screenVp.toFixed(1)}vp → avoid=${avoid}`);
  }

  /** 由实测值算出 Dock 几何并发布；值真的变了才递增 theme_revision。 */
  static publish(): void {
    const insetBottom: number = SafeArea.insetBottom();
    const avoid: boolean = SafeArea.avoidActive();
    // Dock 底边离开屏幕底边的目标间距：手势区的 60%，夹在 8~22vp。
    // 取 60% 是为了让 Dock 的底沿正好落在手势指示条上方一点点 —— 既「往下调了」，
    // 又不会让系统手势条压在 Dock 的圆角上（那条是系统窗口，压上来会像划破了）。
    let gap: number = Math.round(insetBottom * 0.6);
    if (gap < 8) {
      gap = 8;
    } else if (gap > 22) {
      gap = 22;
    }
    const margin: number = avoid ? 0 : gap;
    const sink: number = avoid ? Math.max(0, Math.round(insetBottom - gap)) : 0;
    let clearance: number = Math.round(DOCK_HEIGHT + gap + DOCK_BREATH);
    if (clearance < CLEARANCE_FLOOR) {
      clearance = CLEARANCE_FLOOR;
    }
    SafeArea.setNumber(SafeArea.KEY_DOCK_GAP, gap);
    SafeArea.setNumber(SafeArea.KEY_DOCK_MARGIN, margin);
    SafeArea.setNumber(SafeArea.KEY_DOCK_SINK, sink);
    SafeArea.setNumber(SafeArea.KEY_CLEARANCE, clearance);
  }

  private static setNumber(key: string, value: number): void {
    const old: number = AppStorage.get<number>(key) ?? -1;
    if (Math.abs(old - value) < 0.01) {
      return;
    }
    AppStorage.setOrCreate<number>(key, value);
    const revision: number = (AppStorage.get<number>('theme_revision') ?? 0) + 1;
    AppStorage.setOrCreate<number>('theme_revision', revision);
  }

  static insetTop(): number {
    return AppStorage.get<number>(SafeArea.KEY_TOP) ?? 0;
  }

  static insetBottom(): number {
    return AppStorage.get<number>(SafeArea.KEY_BOTTOM) ?? 0;
  }

  /** 布局是否仍在避让系统栏（默认 false = 按沉浸式已生效处理，首次校准后会立刻改写） */
  static avoidActive(): boolean {
    return AppStorage.get<boolean>(SafeArea.KEY_AVOID) ?? false;
  }

  /**
   * 顶栏要往下让多少。只在「沉浸式真的生效、布局不再避让」时补：
   * 此时内容起点在屏幕最顶边，状态栏会压住顶栏。
   *
   * 2026-10-30 二修（用户圈图：状态栏到标题那段空白太大）：
   * 首版直接补满 `insetTop`，但顶栏行本身 56vp、标题在行内垂直居中，
   * 于是标题上沿 = insetTop + 行内留白；这台机器实测 insetTop=43.8vp、标题上沿 64vp，
   * 状态栏下沿到标题空了 **20vp**，像被切成两段。这里把行内留白的一半还回去
   * （`TOP_TRIM`），标题上沿落到 ≈52vp，与状态栏下沿只隔 8vp：仍然是沉浸式
   * （背景一路铺到屏幕顶），但不再空一大条。想更贴就调大（别超过行内留白，
   * 否则标题会压到时钟），想更松就调小。
   */
  static topPad(): number {
    if (SafeArea.avoidActive()) {
      return 0;
    }
    const pad: number = SafeArea.insetTop() - TOP_TRIM;
    return pad > 0 ? pad : 0;
  }

  /** Dock 底边到屏幕底边的目标间距 */
  static dockGap(): number {
    return AppStorage.get<number>(SafeArea.KEY_DOCK_GAP) ?? 12;
  }

  /** Dock 的 margin.bottom（避让模式下为 0，靠 sink 下沉） */
  static dockMargin(): number {
    return AppStorage.get<number>(SafeArea.KEY_DOCK_MARGIN) ?? SafeArea.dockGap();
  }

  /** Dock 的额外下沉量（避让模式下 = insetBottom − gap） */
  static dockSink(): number {
    return AppStorage.get<number>(SafeArea.KEY_DOCK_SINK) ?? 0;
  }

  /** 内容底部留白：从内容容器底边算，保证最后一项能滚到 Dock 上方而不是停在 Dock 底下 */
  static dockClearance(): number {
    return AppStorage.get<number>(SafeArea.KEY_CLEARANCE) ?? CLEARANCE_FLOOR;
  }
}
