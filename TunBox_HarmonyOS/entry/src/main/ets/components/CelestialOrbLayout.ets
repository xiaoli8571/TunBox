/**
 * 天体轨域（CelestialPowerOrb）几何布局 —— 纯数据 + 纯函数，**不 import 任何 @kit**。
 *
 * ## 为什么单独拆出来（2026-10-18）
 *
 * 用户报障：启动按钮外圈「球 + 弧线」在四周转动时会互相重叠。
 * 根因是三条元素各自用**不同的角速度**（`spin` / `spin*0.55` / `-spin*0.8`）：
 * 相对角度随时间线性变化，必然周期性重合 —— 这不是参数没调好，而是「不同速」
 * 这件事本身就保证不了不相交。
 *
 * 修法：**所有转动元素共用同一个轨道相位**（`speedFactor` 全为 1），彼此只保留
 * 固定角度偏移；这样任意两元素的角间距恒定，只要初始布局留够空隙，就永远不会重叠。
 * 同时把布局抽成本文件，让 Node 回归脚本能真跑 `minGapVp()` 验证这个不变量
 * （`scripts/verify-orb-separation.mjs`），而不是靠肉眼截图。
 *
 * 约定：角度 0° 指向 +X（三点钟方向），顺时针为正；与 Canvas 的 `arc()` 一致。
 */

/** 单个转动元素：一个卫星球，或一段弧线。 */
export class OrbElement {
  static readonly KIND_BALL: string = 'ball';
  static readonly KIND_ARC: string = 'arc';

  kind: string = OrbElement.KIND_ARC;
  /** 所在轨道半径（vp，以按钮中心为圆心） */
  radius: number = 0;
  /** 相对轨道相位的角度偏移（度） */
  offsetDeg: number = 0;
  /** 弧线扫角（度）；球为 0 */
  sweepDeg: number = 0;
  /** 视觉外延半径（vp）：球=光晕半径，弧=线宽一半 */
  extent: number = 0;
  /** 角速度倍率：**必须全为 1**，否则相对角度会漂移并最终重叠（见文件头） */
  speedFactor: number = 1;

  constructor(kind: string, radius: number, offsetDeg: number, sweepDeg: number, extent: number,
    speedFactor: number = 1) {
    this.kind = kind;
    this.radius = radius;
    this.offsetDeg = offsetDeg;
    this.sweepDeg = sweepDeg;
    this.extent = extent;
    this.speedFactor = speedFactor;
  }

  /** 该元素在轨道相位 spinDeg 时的起始角（度） */
  startAt(spinDeg: number): number {
    return this.offsetDeg + spinDeg * this.speedFactor;
  }

  /**
   * 该元素在轨道相位 spinDeg 时的**几何中心**角（归一化到 [0,360)）。
   *
   * 长条的「中线」就是它；十字是否对齐只看这个值（起点不是中线 ——
   * 第一版长条 0°→42° 的中心是 21°，球在 90°，两轴并不正交，正是用户报的偏差）。
   */
  centerAt(spinDeg: number): number {
    const c: number = this.offsetDeg + this.sweepDeg / 2 + spinDeg * this.speedFactor;
    return ((c % 360) + 360) % 360;
  }

  /** 该元素在轨道相位 spinDeg 时占据的角区间 [start, end]（球 start == end） */
  spanAt(spinDeg: number): number[] {
    const start: number = this.startAt(spinDeg);
    return [start, start + this.sweepDeg];
  }

  /** 该元素（含扫角）在给定相位下的采样点，用于计算两两最小间距 */
  samplesAt(spinDeg: number, stepDeg: number): number[][] {
    const out: number[][] = [];
    const span: number[] = this.spanAt(spinDeg);
    const step: number = Math.max(0.5, stepDeg);
    const count: number = Math.max(1, Math.ceil((span[1] - span[0]) / step));
    for (let i = 0; i <= count; i++) {
      const deg: number = span[0] + (span[1] - span[0]) * i / count;
      const rad: number = deg * Math.PI / 180;
      out.push([this.radius * Math.cos(rad), this.radius * Math.sin(rad)]);
    }
    return out;
  }
}

export class OrbLayout {
  /** 卫星光晕半径（vp，见 drawSatellite 的 radial gradient 半径） */
  static readonly BALL_EXTENT: number = 11;
  /** 弧线半宽（vp，lineWidth 4.5 / 2） */
  static readonly ARC_HALF_WIDTH: number = 2.25;
  /** 外圈点阵轨道半径（trackSize / 2）
   *  2026-10-19：随启动按钮等比缩小，280 → 245（orbTrack/2 = 122.5） */
  static readonly OUTER_R: number = 122.5;
  /** 渐变轨环半径（arcRingSize / 2）
   *  2026-10-19：随启动按钮等比缩小，260 → 228（orbArcRing/2 = 114）。
   *  这条是四个转动元素实际使用的半径（见下方 BALL/ARC 定义）。 */
  static readonly RING_R: number = 114;
  /**
   * 两条长条的统一扫角（度）—— 取旧实现里较长那根的 42°，
   * 两根等长才构成对称十字（2026-10-18 用户要求）。
   */
  static readonly ARC_SWEEP: number = 42;

  /**
   * 四个转动元素的固定角度槽位 —— **十字对称布局**（2026-10-18 用户要求）。
   *
   * 用户原话（两轮）：
   *   1. > 改成对称吧，长条的长度改的跟现在长的那一根一样长，两个球也对称，
   *      > 形成一个十字，然后就保持匀速转动。
   *   2. > 小球的位置要在横线的中间，要保证都在十字架对应的位置，完全对称，
   *      > 现在小球没有完全在十字中线上。
   *
   * ## 第二轮的关键修正：长条必须**关于自己的轴居中**
   *
   * 第一版长条是 `0°→42°` / `180°→222°` —— 起点压在水平轴上、末端甩到 42°，
   * 于是长条的**几何中心线**落在 21° / 201°。十字的两条中线实际是 21°/201° 与
   * 111°/291°，而球在 90°/270° —— 球相对「十字中线」偏了 21°，
   * 视觉上就是用户说的「小球没有完全在十字中线上」。
   *
   * 现在长条改为**以轴为中心**对称展开：`-21°→21°`（右）与 `159°→201°`（左），
   * 中心线正好是 0° 与 180°；球在 90° 与 270°，与长条中线严格正交 90°：
   *
   *     270°  外圈卫星（蓝）                r = 140
   *     -21°→ 21° 蓝→青长条（右，中心 0°）    r = 130
   *      90°  外圈卫星（绿）                r = 140
   *     159°→201° 绿色长条（左，中心 180°）   r = 130
   *
   * 由此得到的对称性（回归脚本逐条断言）：
   *   · 长条中心线 = 0°/180°，球 = 90°/270°，两轴严格正交；
   *   · 左右长条关于圆心镜像、上下球关于圆心镜像（各自相差 180°）；
   *   · 任意相位旋转后仍成立（四者共用同一相位，形状不变，只是整体转动）。
   *
   * ## 第三轮修正：球与长条必须**同半径**，十字才真的对称
   *
   * 前两版球在 r=140（外圈点阵轨道）、长条在 r=130（轨环）—— 两条「臂」落在
   * 不同圆周上，球看起来贴着外圈虚线跑、长条贴着内环跑，十字的两臂一长一短，
   * 用户看到的就是「小球没有完全在十字中线上」。
   *
   * 现在四者**统一半径 r=130**（`RING_R`），球在 90°/270°、长条中线在 0°/180°：
   *
   *     270°  球（蓝）                    r = 130
   *     -21°→ 21° 蓝→青长条（右，中线 0°）   r = 130
   *      90°  球（绿）                    r = 130
   *     159°→201° 绿色长条（左，中线 180°）  r = 130
   *
   * 于是十字的两条臂完全等价（同半径、同粗细量级、只差长度与元素种类），
   * 球严格落在另一条臂的中线上，四者两两相隔 90°，任意相位都保持这个形态。
   *
   * 相邻最小角间距 = 69°（长条末端 21° → 球 90°），换算弧长 ≈ 156vp，
   * 远大于视觉外延之和（11 + 2.25 ≈ 13vp），匀速转动时**永不重叠**。
   */
  static readonly BALL1: OrbElement =
    new OrbElement(OrbElement.KIND_BALL, OrbLayout.RING_R, -90, 0, OrbLayout.BALL_EXTENT);
  static readonly ARC1: OrbElement =
    new OrbElement(OrbElement.KIND_ARC, OrbLayout.RING_R, -OrbLayout.ARC_SWEEP / 2,
      OrbLayout.ARC_SWEEP, OrbLayout.ARC_HALF_WIDTH);
  static readonly BALL2: OrbElement =
    new OrbElement(OrbElement.KIND_BALL, OrbLayout.RING_R, 90, 0, OrbLayout.BALL_EXTENT);
  static readonly ARC2: OrbElement =
    new OrbElement(OrbElement.KIND_ARC, OrbLayout.RING_R, 180 - OrbLayout.ARC_SWEEP / 2,
      OrbLayout.ARC_SWEEP, OrbLayout.ARC_HALF_WIDTH);

  static elements(): OrbElement[] {
    return [OrbLayout.BALL1, OrbLayout.ARC1, OrbLayout.BALL2, OrbLayout.ARC2];
  }

  /** 所有元素的角速度倍率是否一致（不一致就一定会在某个相位重叠） */
  static uniformSpeed(): boolean {
    const list: OrbElement[] = OrbLayout.elements();
    for (const e of list) {
      if (Math.abs(e.speedFactor - list[0].speedFactor) > 1e-9) {
        return false;
      }
    }
    return true;
  }

  /**
   * 扫一整圈轨道相位，返回任意两元素之间**最小视觉间距**（vp，已扣除各自外延）。
   * 正值 = 永不相交；返回值即回归脚本的断言依据。
   */
  static minGapVp(spinStepDeg: number = 1, sampleStepDeg: number = 2): number {
    const list: OrbElement[] = OrbLayout.elements();
    let best: number = Number.POSITIVE_INFINITY;
    for (let spin = 0; spin < 360; spin += Math.max(0.5, spinStepDeg)) {
      for (let i = 0; i < list.length; i++) {
        for (let j = i + 1; j < list.length; j++) {
          const a: OrbElement = list[i];
          const b: OrbElement = list[j];
          const pa: number[][] = a.samplesAt(spin, sampleStepDeg);
          const pb: number[][] = b.samplesAt(spin, sampleStepDeg);
          let pairMin: number = Number.POSITIVE_INFINITY;
          for (const p of pa) {
            for (const q of pb) {
              const dx: number = p[0] - q[0];
              const dy: number = p[1] - q[1];
              const d: number = Math.sqrt(dx * dx + dy * dy) - a.extent - b.extent;
              if (d < pairMin) {
                pairMin = d;
              }
            }
          }
          if (pairMin < best) {
            best = pairMin;
          }
        }
      }
    }
    return best;
  }
}
