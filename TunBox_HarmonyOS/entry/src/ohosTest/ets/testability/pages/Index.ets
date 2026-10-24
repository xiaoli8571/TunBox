@Entry
@Component
struct Index {
  build() {
    Column() {
      Text('TunBox Local Unit Tests')
        .fontSize(18)
        .fontColor('#F5F7FF')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#0A1020')
  }
}
