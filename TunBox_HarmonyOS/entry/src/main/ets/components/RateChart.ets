/**
 * 首页实时速率曲线 —— 对齐《TunBox-UI重构笔记》§3.1「实时速率波动波浪」
 *
 * 归一化坐标系（基线 46/52，振幅 36/52，26 点滑动窗口），按组件实测宽高缩放；
 * 配色改为文档色板：曲线品牌蓝 #0A59F7，面积品牌蓝弱化填充。
 */
import { TunBoxColors } from '../theme/TunBoxTokens';
import { ThemeService } from '../theme/ThemeService';
import { NexusSizes } from '../theme/NexusTokens';

@Component
export struct RateChart {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @Prop points: number[] = [];
  @Prop isConnected: boolean = false;
  @State private chartW: number = NexusSizes.rateChartW;
  @State private chartH: number = NexusSizes.rateChartH;

  private lineColor(): ResourceColor {
    return TunBoxColors.primaryFor(this.themeRevision);
  }

  private areaColor(): ResourceColor {
    const rgb = ThemeService.isDark() ? '59, 130, 246' : '10, 89, 247';
    return this.isConnected ? `rgba(${rgb}, 0.14)` : `rgba(${rgb}, 0.08)`;
  }

  private baseRatio(): number {
    return NexusSizes.rateBaseY / NexusSizes.rateChartH;
  }

  private ampRatio(): number {
    return NexusSizes.rateAmpY / NexusSizes.rateChartH;
  }

  private linePoints(): number[][] {
    const n = Math.max(2, this.points.length);
    const pts: number[][] = [];
    for (let i = 0; i < this.points.length; i++) {
      const r = Math.min(1, Math.max(0, this.points[i]));
      const x = i * (this.chartW / (n - 1));
      const y = this.chartH * this.baseRatio() - r * this.chartH * this.ampRatio();
      pts.push([x, y]);
    }
    return pts;
  }

  private areaPoints(): number[][] {
    const line = this.linePoints();
    const closed: number[][] = line.slice();
    closed.push([this.chartW, this.chartH]);
    closed.push([0, this.chartH]);
    return closed;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 面积
      Polygon({ width: this.chartW, height: this.chartH })
        .points(this.areaPoints())
        .fill(this.areaColor())
        .stroke(Color.Transparent)
        .strokeWidth(0)
      // 折线
      Polyline({ width: this.chartW, height: this.chartH })
        .points(this.linePoints())
        .stroke(this.lineColor())
        .strokeWidth(2.2)
        .strokeLineCap(LineCapStyle.Round)
        .strokeLineJoin(LineJoinStyle.Round)
        .fill(Color.Transparent)
    }
    .width('100%')
    .height(48)
    .onAreaChange((_old: Area, cur: Area) => {
      const w = Number(cur.width);
      const h = Number(cur.height);
      if (!Number.isNaN(w) && w > 0) {
        this.chartW = w;
      }
      if (!Number.isNaN(h) && h > 0) {
        this.chartH = h;
      }
    })
  }
}
