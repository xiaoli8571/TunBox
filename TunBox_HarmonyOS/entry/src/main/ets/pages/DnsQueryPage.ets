import { TunBoxColors, TunBoxGeometry } from '../theme/TunBoxTokens';
import { TunBoxTextColors } from '../theme/TextColors';
import { TopNavBar } from '../components/TopNavBar';
import { CoreLogLine, CoreLogListener, CoreLogStream } from '../commons/services/CoreLogStream';
import { ConnectionOrchestrator } from '../commons/services/ConnectionOrchestrator';

/** 一行 DNS 记录（只保留展示需要的两个字段）。 */
class DnsRow {
  time: string = '';
  text: string = '';
}

/**
 * DNS 查询实时视图（FlClash DNS 查询页的鸿蒙等价物）。
 *
 * 数据源与 DiagnosticsSheet 相同的 `/logs` WebSocket：mihomo 的 DNS 解析日志
 * 以 debug 级别下发，因此本页连接时用 `debug`，离开时恢复 `info`，
 * 不改变其他页面对日志级别的预期。
 *
 * 只做展示与过滤：不解析、不缓存、不落盘；上限 300 行，暂停后不再追加。
 */
@Entry
@Component
struct DnsQueryPage {
  @StorageLink('theme_revision') themeRevision: number = 0;
  @State private rows: DnsRow[] = [];
  @State private keyword: string = '';
  @State private paused: boolean = false;
  @State private phase: string = 'idle';
  private stream: CoreLogStream = CoreLogStream.instance();
  private orchestrator: ConnectionOrchestrator = ConnectionOrchestrator.instance();
  private listener: CoreLogListener = (lines: CoreLogLine[]): void => {
    this.apply(lines);
  };

  aboutToAppear(): void {
    this.stream.addListener(this.listener);
    this.connect();
    this.apply(this.stream.snapshot());
  }

  aboutToDisappear(): void {
    this.stream.removeListener(this.listener);
    // 恢复通用页面使用的级别（DNS 页临时开 debug 才能看到解析日志）
    const port: number = this.orchestrator.api.currentPort();
    if (port > 0) {
      this.stream.connect(port, this.orchestrator.api.currentSecret(), 'info');
    }
  }

  private connect(): void {
    const port: number = this.orchestrator.api.currentPort();
    if (port <= 0) {
      this.phase = 'closed';
      return;
    }
    this.stream.connect(port, this.orchestrator.api.currentSecret(), 'debug');
    this.phase = this.stream.phase();
  }

  /** mihomo 的 DNS 日志形如 `[DNS] example.com --> 1.2.3.4`，按小写包含判定。 */
  private isDns(line: CoreLogLine): boolean {
    return line.text.toLowerCase().includes('dns');
  }

  private clockOf(ms: number): string {
    const d: Date = new Date(ms);
    const hh: string = String(d.getHours()).padStart(2, '0');
    const mm: string = String(d.getMinutes()).padStart(2, '0');
    const ss: string = String(d.getSeconds()).padStart(2, '0');
    return `${hh}:${mm}:${ss}`;
  }

  private apply(lines: CoreLogLine[]): void {
    if (this.paused) {
      return;
    }
    const out: DnsRow[] = [];
    for (const line of lines) {
      if (!this.isDns(line)) {
        continue;
      }
      const row = new DnsRow();
      row.time = this.clockOf(line.receivedAt);
      row.text = line.text.trim();
      out.push(row);
      if (out.length >= 300) {
        break;
      }
    }
    this.rows = out;
    this.phase = this.stream.phase();
  }

  private visibleRows(): DnsRow[] {
    const key: string = this.keyword.trim().toLowerCase();
    if (key.length === 0) {
      return this.rows;
    }
    return this.rows.filter((row: DnsRow): boolean => row.text.toLowerCase().includes(key));
  }


  private phaseText(): string {
    if (this.phase === 'open') {
      return '实时';
    }
    if (this.phase === 'connecting') {
      return '连接中…';
    }
    return '未连接内核';
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      Column()
        .width('100%').height('100%')
        .linearGradient({
          angle: 180,
          colors: [[TunBoxColors.bgGradientStart(this.themeRevision), 0.0],
            [TunBoxColors.bgGradientEnd(this.themeRevision), 1.0]]
        })
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      Column() {
        TopNavBar({ title: 'DNS 查询', hasBack: true }) {
          Row({ space: 8 }) {
            Button(this.paused ? '继续' : '暂停').fontSize(13)
              .backgroundColor(TunBoxColors.chipBg(this.themeRevision))
              .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
              .onClick(() => {
                this.paused = !this.paused;
                if (!this.paused) {
                  this.apply(this.stream.snapshot());
                }
              })
            Button('清空').fontSize(13)
              .backgroundColor(TunBoxColors.chipBg(this.themeRevision))
              .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
              .onClick(() => { this.rows = []; })
          }
        }

        Column({ space: 10 }) {
          Row({ space: 8 }) {
            Text(this.phaseText())
              .fontSize(11).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
            Blank()
            Text(`${this.rows.length} 条`)
              .fontSize(11).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
          }.width('100%')

          TextInput({ text: this.keyword, placeholder: '过滤域名 / IP' })
            .height(38).width('100%').fontSize(13)
            .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
            .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
            .onChange((value: string) => { this.keyword = value; })

          if (this.visibleRows().length === 0) {
            Column({ space: 6 }) {
              Text(this.phase === 'open' ? '暂无 DNS 记录' : '内核未连接，联机后自动出现解析记录')
                .fontSize(13).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
              Text('DNS 日志由内核以 debug 级别下发；只在本页临时开启，离开后恢复。')
                .fontSize(11).fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
            }
            .width('100%').padding({ top: 40 })
            .alignItems(HorizontalAlign.Center)
          } else {
            List({ space: 6 }) {
              ForEach(this.visibleRows(), (row: DnsRow) => {
                ListItem() {
                  Row({ space: 8 }) {
                    Text(row.time).fontSize(10)
                      .fontColor(TunBoxTextColors.secondaryFor(this.themeRevision))
                    Text(row.text).fontSize(11)
                      .fontColor(TunBoxTextColors.primaryFor(this.themeRevision))
                      .layoutWeight(1).maxLines(3)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%').padding(10).borderRadius(12)
                  .backgroundColor(TunBoxColors.surfaceCard(this.themeRevision))
                  .alignItems(VerticalAlign.Top)
                }
              }, (row: DnsRow) => `${row.time}#${row.text}`)
            }
            .layoutWeight(1)
            .width('100%')
            .scrollBar(BarState.Off)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .padding({
          left: TunBoxGeometry.pagePadding, right: TunBoxGeometry.pagePadding,
          top: 8, bottom: 16
        })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
  }
}
