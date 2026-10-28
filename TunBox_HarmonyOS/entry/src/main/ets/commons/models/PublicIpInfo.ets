/**
 * 数据模型：公网 IP 信息
 * 移植自 upstream: packages/tunbox_shared/lib/models/public_ip_info.dart
 */
export class PublicIpInfo {
  ip: string = '';
  country: string = '';
  countryCode: string = '';
  city: string = '';
  isp: string = '';
  /**
   * ASN 与运营商合并串（ip-api 的 `as` 字段，形如 `AS15169 Google LLC`）。
   * 数据页「出口 IP」卡片对齐 ClashPlus `_IpInfoContent` 的 ASN 行。
   */
  asn: string = '';
  /** 出口所在时区（ip-api `timezone`，形如 `Asia/Tokyo`）——对齐 Plus 的时区行 */
  timezone: string = '';
  queryTime: number = 0;

  static empty(): PublicIpInfo {
    return new PublicIpInfo();
  }
}

/** 应用诊断信息，移植自 app_diagnostics.dart */
export class AppDiagnostics {
  coreRunning: boolean = false;
  vpnActive: boolean = false;
  clashApiReachable: boolean = false;
  clashApiPort: number = 0;
  coreVersion: string = '';
  startedAt: number = 0;
  lastError: string = '';
  uptimeSeconds: number = 0;
  connectionState: string = '';
  currentNode: string = '';
  uploadSpeed: number = 0;
  downloadSpeed: number = 0;
  uploadBytes: number = 0;
  downloadBytes: number = 0;
  logs: string[] = [];
}
