/** 订阅卡片的纯格式化逻辑；-1、非有限数均表示未知，不能冒充已用 0。 */
export class SubscriptionSummary {
  static updateTime(timestamp: number, now: number = Date.now()): string {
    if (!Number.isFinite(timestamp) || timestamp <= 0) { return '未更新'; }
    const minutes: number = Math.floor(Math.max(0, now - timestamp) / 60000);
    if (minutes < 1) { return '刚刚'; }
    if (minutes < 60) { return `${minutes}分钟前`; }
    const hours: number = Math.floor(minutes / 60);
    return hours < 24 ? `${hours}小时前` : `${Math.floor(hours / 24)}天前`;
  }

  static bytes(bytes: number): string {
    if (!Number.isFinite(bytes) || bytes < 0) { return '--'; }
    const units: string[] = ['B', 'K', 'M', 'G', 'T'];
    let value: number = bytes;
    let index: number = 0;
    while (value >= 1024 && index < units.length - 1) { value /= 1024; index++; }
    const number: string = index === 0 ? Math.round(value).toString()
      : (value < 10 ? value.toFixed(1).replace(/\.0$/, '') : Math.round(value).toString());
    return `${number}${units[index]}`;
  }

  static traffic(upload: number, download: number, total: number): string {
    const known: boolean = Number.isFinite(upload) && upload >= 0
      && Number.isFinite(download) && download >= 0;
    return `${known ? SubscriptionSummary.bytes(upload + download) : '--'}/${SubscriptionSummary.bytes(total)}`;
  }
}
