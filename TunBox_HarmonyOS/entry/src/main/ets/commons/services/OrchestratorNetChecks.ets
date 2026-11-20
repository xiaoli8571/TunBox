/**
 * Network reachability probes, loopback port selection, and traffic/duration formatters
 * extracted from ConnectionOrchestrator.
 */
import { http, connection } from '@kit.NetworkKit';
import { LocalPortProbe } from './LocalPortProbe';
import { ClashApiService } from './ClashApiService';
import { AppLogger } from '../utils/AppLogger';
import { LatencyTestUrl } from '../latency/LatencyTestUrl';

const TAG = 'OrchestratorNetChecks';

/** Port triplet candidate groups tried in order to avoid colliding with co-installed cores. */
export const PORT_CANDIDATE_SETS: number[][] = [
  [9090, 7890, 1053],
  [19090, 17890, 11053],
  [29090, 27890, 21053]
];

/** Immutable port triplet bound to a single kernel launch (tunnel or test core). */
export class RuntimePorts {
  apiPort: number = 0;
  mixedPort: number = 0;
  dnsPort: number = 0;
}

/** Stateless connectivity, port probing, and notification formatting helpers. */
export class OrchestratorNetChecks {
  /** Select the first candidate triplet where all three ports are free on loopback. */
  static async pickPorts(defaultApi: number, defaultMixed: number, defaultDns: number,
    excludeApiPort: number): Promise<RuntimePorts> {
    const picked = new RuntimePorts();
    picked.apiPort = defaultApi;
    picked.mixedPort = defaultMixed;
    picked.dnsPort = defaultDns;
    for (const candidate of PORT_CANDIDATE_SETS) {
      if (excludeApiPort > 0 && candidate[0] === excludeApiPort) {
        continue;
      }
      let allFree = true;
      for (const port of candidate) {
        if (!(await LocalPortProbe.isFree(port))) {
          allFree = false;
          break;
        }
      }
      if (allFree) {
        picked.apiPort = candidate[0];
        picked.mixedPort = candidate[1];
        picked.dnsPort = candidate[2];
        return picked;
      }
    }
    throw new Error('本地内核端口均被占用，请关闭其他代理后重试');
  }

  /** Detect whether another core owns the controller port (reachable with 401/403). */
  static async detectForeignControllerBusy(api: ClashApiService): Promise<boolean> {
    try {
      const probe = await api.probeController(1500);
      return probe.reachable && !probe.secretAccepted
        && (probe.httpCode === 401 || probe.httpCode === 403);
    } catch (_e) {
      return false;
    }
  }

  /** Verify DNS resolution through the OS resolver (which routes via TUN hijack when connected). */
  static async checkDnsResolvable(): Promise<boolean> {
    try {
      const addresses = await connection.getAddressesByName('www.gstatic.com');
      return Array.isArray(addresses) && addresses.length > 0;
    } catch (e) {
      AppLogger.info(TAG, `dns self-check failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /** Verify AAAA resolution via the system resolver so ipv6=false masking is not bypassed. */
  static async checkIpv6Resolvable(): Promise<boolean> {
    try {
      const addresses = await connection.getAddressesByName('ipv6.google.com');
      if (!Array.isArray(addresses)) {
        return false;
      }
      for (let i = 0; i < addresses.length; i++) {
        const entry = addresses[i];
        if (entry === null || entry === undefined) {
          continue;
        }
        if (entry.family === 2) {
          return true;
        }
        if (typeof entry.address === 'string' && entry.address.indexOf(':') >= 0) {
          return true;
        }
      }
      return false;
    } catch (e) {
      AppLogger.info(TAG, `ipv6 self-check failed: ${AppLogger.errText(e)}`);
      return false;
    }
  }

  /** Probe HTTP egress reachability via generate_204. */
  static async checkEgressReachable(): Promise<boolean> {
    const client = http.createHttp();
    try {
      const resp = await client.request(LatencyTestUrl.DEFAULT_URL, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 1500,
        readTimeout: 1500
      });
      return resp.responseCode === 204 || resp.responseCode === 200;
    } catch (_e) {
      return false;
    } finally {
      client.destroy();
    }
  }

  static formatSpeed(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${bytesPerSecond.toFixed(0)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / 1024 / 1024).toFixed(2)} MB/s`;
  }

  static formatBytes(total: number): string {
    if (total < 1024) {
      return `${total} B`;
    }
    if (total < 1024 * 1024) {
      return `${(total / 1024).toFixed(1)} KB`;
    }
    if (total < 1024 * 1024 * 1024) {
      return `${(total / 1024 / 1024).toFixed(1)} MB`;
    }
    return `${(total / 1024 / 1024 / 1024).toFixed(2)} GB`;
  }

  static connDurationText(startedAt: number): string {
    if (startedAt <= 0) {
      return '';
    }
    let s = Math.floor((Date.now() - startedAt) / 1000);
    if (s < 0) {
      s = 0;
    }
    const h = Math.floor(s / 3600);
    const m = Math.floor((s % 3600) / 60);
    const sec = s % 60;
    const mm = m < 10 ? `0${m}` : `${m}`;
    const ss = sec < 10 ? `0${sec}` : `${sec}`;
    return `${h}:${mm}:${ss}`;
  }

  static notifyNodeText(name: string): string {
    const n = name.trim();
    if (n.length <= 24) {
      return n;
    }
    return `${n.substring(0, 24)}…`;
  }
}
