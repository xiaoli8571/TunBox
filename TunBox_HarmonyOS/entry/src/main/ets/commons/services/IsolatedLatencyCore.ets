import { connection, socket } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { coreBridge } from '../../core/CoreBridge';
import { ClashApiService } from './ClashApiService';
import { AppLogger } from '../utils/AppLogger';
import { ensurePrivateDir, privateFs } from './PrivateFileStore';

export class IsolatedLatencyPorts {
  apiPort: number = 0;
  mixedPort: number = 0;
  dnsPort: number = 0;
}

export type IsolatedLatencyBuilder = (ports: IsolatedLatencyPorts, secret: string) => Promise<string>;

/** This core lives in the UI process; the VPN Extension has its own native core.
 * It never starts/stops an Extension, changes the current profile, or shares an
 * API object/configuration directory with the forwarding core. */
export class IsolatedLatencyCore {
  private static busy: boolean = false;
  private static path: string = '';
  private static netId: number = -1;

  static physicalNetId(): number {
    try {
      const handle = connection.getDefaultNetSync();
      const caps = connection.getNetCapabilitiesSync(handle);
      if (handle.netId > 0 && !(caps.bearerTypes || []).includes(connection.NetBearType.BEARER_VPN)) {
        return handle.netId;
      }
    } catch (_e) {}
    return -1;
  }

  static networkCurrent(): boolean {
    return IsolatedLatencyCore.netId > 0 && IsolatedLatencyCore.netId === IsolatedLatencyCore.physicalNetId();
  }

  private static async free(port: number): Promise<boolean> {
    const server = socket.constructTCPSocketServerInstance();
    try {
      await server.listen({ address: '127.0.0.1', port: port, family: 1 });
      return true;
    } catch (_e) { return false; }
    finally { try { await server.close(); } catch (_e) {} }
  }

  private static copyRuleCache(source: string, target: string, depth: number = 0): void {
    if (depth > 12) { throw new Error('规则缓存目录层级异常'); }
    ensurePrivateDir(target);
    for (const name of fs.listFileSync(source)) {
      if (name.includes('/') || name.includes('\\') || name === '.' || name === '..') { continue; }
      const from = `${source}/${name}`;
      const to = `${target}/${name}`;
      if (fs.statSync(from).isDirectory()) {
        IsolatedLatencyCore.copyRuleCache(from, to, depth + 1);
      } else {
        fs.copyFileSync(from, to);
      }
    }
  }

  static async open(context: Context, build: IsolatedLatencyBuilder): Promise<ClashApiService> {
    if (IsolatedLatencyCore.busy) { throw new Error('另一个订阅测速正在准备中'); }
    IsolatedLatencyCore.busy = true;
    try {
      IsolatedLatencyCore.netId = IsolatedLatencyCore.physicalNetId();
      if (IsolatedLatencyCore.netId <= 0 || !coreBridge.setPhysicalNetId(IsolatedLatencyCore.netId)) {
        throw new Error('独立测速无法绑定物理网络，请确认网络连接后重试');
      }
      const ports = new IsolatedLatencyPorts();
      for (let port = 19090; port < 19150; port += 3) {
        if (await IsolatedLatencyCore.free(port) && await IsolatedLatencyCore.free(port + 1)
          && await IsolatedLatencyCore.free(port + 2)) {
          ports.apiPort = port; ports.mixedPort = port + 1; ports.dnsPort = port + 2;
          break;
        }
      }
      if (ports.apiPort === 0) { throw new Error('独立测速端口不可用'); }
      const dir = `${context.cacheDir}/isolated-latency`;
      ensurePrivateDir(dir);
      // Read-only resource copies; provider caches and logs stay in this directory.
      const resources: string[] = ['Model.bin', 'GeoIP.dat', 'GeoSite.dat', 'geoip.dat', 'geosite.dat',
        'Country.mmdb', 'geoip.metadb', 'geoip.db'];
      const ruleDir = `${context.cacheDir}/ruleset`;
      let hasRules = false;
      try { hasRules = fs.accessSync(ruleDir); } catch (_e) {}
      try {
        if (hasRules) {
          IsolatedLatencyCore.copyRuleCache(ruleDir, `${dir}/ruleset`);
        }
      } catch (error) {
        throw new Error(`独立测速规则资源准备失败：${AppLogger.errText(error)}`);
      }
      for (const name of resources) {
        const source = `${context.cacheDir}/${name}`;
        let exists = false;
        try { exists = fs.accessSync(source); } catch (_e) {}
        if (!exists) { continue; }
        try { fs.copyFileSync(source, `${dir}/${name}`); } catch (error) {
          throw new Error(`独立测速资源复制失败：${name}`);
        }
      }
      const secret = `isolated-${Date.now().toString(36)}-${Math.random().toString(36).substring(2)}`;
      const yaml = await build(ports, secret);
      if (!IsolatedLatencyCore.networkCurrent()) { throw new Error('网络已变化，请重新测速'); }
      IsolatedLatencyCore.path = `${dir}/config.yaml`;
      privateFs.writePrivate(IsolatedLatencyCore.path, yaml);
      const ok = await coreBridge.startCore(IsolatedLatencyCore.path);
      if (!ok) { throw new Error('独立测速内核启动失败'); }
      const api = new ClashApiService();
      api.setEndpoint(ports.apiPort, secret);
      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        if (!IsolatedLatencyCore.networkCurrent()) { throw new Error('网络已变化，请重新测速'); }
        if (await api.healthProbe()) { return api; }
        await new Promise<void>((resolve) => setTimeout(resolve, 100));
      }
      throw new Error('独立测速通道未就绪');
    } catch (error) {
      await IsolatedLatencyCore.close();
      throw new Error(AppLogger.errText(error));
    }
  }

  static async close(): Promise<void> {
    if (!IsolatedLatencyCore.busy) { return; }
    try { await coreBridge.stopCore(); } catch (error) {
      AppLogger.warn('IsolatedLatency', `stop failed: ${AppLogger.errText(error)}`);
    } finally {
      coreBridge.setPhysicalNetId(-1);
      if (IsolatedLatencyCore.path.length > 0) {
        try { fs.unlinkSync(IsolatedLatencyCore.path); } catch (_e) {}
      }
      IsolatedLatencyCore.path = '';
      IsolatedLatencyCore.netId = -1;
      IsolatedLatencyCore.busy = false;
    }
  }
}
