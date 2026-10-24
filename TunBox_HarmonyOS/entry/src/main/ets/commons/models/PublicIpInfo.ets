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
