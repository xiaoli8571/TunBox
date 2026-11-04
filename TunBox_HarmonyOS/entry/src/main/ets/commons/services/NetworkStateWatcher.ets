/** Physical default-network snapshots with trailing-edge coalescing. No UI ownership. */
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'NetworkStateWatcher';
export const NET_DEBOUNCE_MS: number = 200;
export const BEARER_CELLULAR: number = 0;
export const BEARER_WIFI: number = 1;
export const BEARER_BLUETOOTH: number = 2;
export const BEARER_ETHERNET: number = 3;
export const BEARER_VPN: number = 4;

export class NetTypes {
  static readonly NONE: string = 'none';
  static readonly WIFI: string = 'wifi';
  static readonly CELLULAR: string = 'cellular';
  static readonly ETHERNET: string = 'ethernet';
  static readonly UNKNOWN: string = 'unknown';
}

export class NetworkSnapshot {
  netType: string = NetTypes.UNKNOWN;
  netId: number = 0;
  interfaceName: string = '';
  addresses: string[] = [];
  dnsServers: string[] = [];
  validated: boolean = false;
  metered: boolean = true;

  copy(): NetworkSnapshot {
    const out = new NetworkSnapshot();
    out.netType = this.netType;
    out.netId = this.netId;
    out.interfaceName = this.interfaceName;
    out.addresses = this.addresses.slice();
    out.dnsServers = this.dnsServers.slice();
    out.validated = this.validated;
    out.metered = this.metered;
    return out;
  }

  identity(): string {
    return `${this.netId}|${this.netType}|${this.interfaceName}|${this.addresses.join(',')}`;
  }

  fingerprint(): string {
    return `${this.identity()}|${this.dnsServers.join(',')}|${this.validated}|${this.metered}`;
  }
}

export interface NetworkStateListener {
  onNetworkTypeChanged(netType: string, generation: number, snapshot?: NetworkSnapshot): void;
}

export function normalizeNetType(bearerTypes: number[], hasDefaultNet: boolean): string {
  if (!hasDefaultNet) { return NetTypes.NONE; }
  if (bearerTypes.includes(BEARER_WIFI)) { return NetTypes.WIFI; }
  if (bearerTypes.includes(BEARER_ETHERNET)) { return NetTypes.ETHERNET; }
  if (bearerTypes.includes(BEARER_CELLULAR)) { return NetTypes.CELLULAR; }
  return NetTypes.UNKNOWN;
}

/** Compatibility helper: a rejected observation MUST be retained by the caller. */
export function shouldEmit(prev: string, next: string, elapsedMs: number, debounceMs: number): boolean {
  if (next === prev) { return false; }
  return prev.length === 0 || debounceMs <= 0 || elapsedMs < 0 || elapsedMs >= debounceMs;
}

export class NetworkStateWatcher {
  private debounceMs: number;
  private netConn: connection.NetConnection | null = null;
  private subscribed: boolean = false;
  private current: NetworkSnapshot = new NetworkSnapshot();
  private observed: boolean = false;
  private gen: number = 0;
  private pending: NetworkSnapshot | null = null;
  private timer: number = -1;
  private epoch: number = 0;
  private listeners: NetworkStateListener[] = [];

  constructor(debounceMs: number = NET_DEBOUNCE_MS, _nowFn?: () => number) {
    this.debounceMs = debounceMs >= 0 ? debounceMs : NET_DEBOUNCE_MS;
  }

  networkType(): string { return this.current.netType; }
  snapshot(): NetworkSnapshot { return this.current.copy(); }
  generation(): number { return this.gen; }
  isSubscribed(): boolean { return this.subscribed; }
  debounceWindowMs(): number { return this.debounceMs; }

  addListener(listener: NetworkStateListener): void {
    if (this.listeners.indexOf(listener) < 0) { this.listeners.push(listener); }
  }

  removeListener(listener: NetworkStateListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) { this.listeners.splice(index, 1); }
  }

  start(_context: Object): boolean {
    if (this.subscribed) { return true; }
    const epoch = ++this.epoch;
    this.refreshSync();
    let conn: connection.NetConnection | null = null;
    try {
      // SDK: default network is INTERNET + non-VPN. Do not pick a bearer by enum value.
      conn = connection.createNetConnection();
      this.netConn = conn;
      conn.on('netAvailable', (): void => { if (epoch === this.epoch) { this.refreshSync(); } });
      conn.on('netLost', (): void => { if (epoch === this.epoch) { this.refreshSync(); } });
      conn.on('netUnavailable', (): void => { if (epoch === this.epoch) { this.refreshSync(); } });
      conn.on('netCapabilitiesChange', (): void => { if (epoch === this.epoch) { this.refreshSync(); } });
      conn.on('netConnectionPropertiesChange', (info: connection.NetConnectionPropertyInfo): void => {
        if (epoch === this.epoch) { this.refreshProperties(info); }
      });
      this.subscribed = true;
      conn.register((err: BusinessError): void => {
        if (epoch !== this.epoch) { return; }
        if (err !== null && err !== undefined && err.code !== 0) {
          this.subscribed = false;
          ++this.epoch;
          this.cancelPending();
          this.retireConnection();
          AppLogger.warn(TAG, `network register failed code=${err.code}`);
        }
      });
      return this.subscribed;
    } catch (e) {
      this.subscribed = false;
      ++this.epoch;
      this.cancelPending();
      this.retireConnection();
      AppLogger.warn(TAG, 'network subscription unavailable: ' + AppLogger.errText(e));
      return false;
    }
  }

  stop(): void {
    ++this.epoch;
    this.cancelPending();
    this.retireConnection();
    this.subscribed = false;
    this.observed = false;
    this.current = new NetworkSnapshot();
    this.listeners = [];
  }

  private retireConnection(): void {
    const conn = this.netConn;
    this.netConn = null;
    if (conn !== null) {
      try { conn.unregister((): void => {}); } catch (e) {
        AppLogger.warn(TAG, 'unregister failed: ' + AppLogger.errText(e));
      }
    }
  }

  refreshSync(): void {
    const next = this.readCurrentSnapshot();
    if (next !== null) { this.observe(next); }
  }

  private refreshProperties(info: connection.NetConnectionPropertyInfo): void {
    const next = this.readCurrentSnapshot();
    if (next === null) { return; }
    if (info.netHandle.netId === next.netId) {
      this.applyProperties(next, info.connectionProperties);
    }
    this.observe(next);
  }

  private applyProperties(next: NetworkSnapshot, props: connection.ConnectionProperties): void {
    next.interfaceName = props.interfaceName || '';
    next.dnsServers = [];
    for (const dns of props.dnses || []) {
      const host = dns.address;
      if (host.length > 0 && next.dnsServers.indexOf(host) < 0) { next.dnsServers.push(host); }
    }
    next.addresses = [];
    for (const link of props.linkAddresses || []) {
      next.addresses.push(`${link.address.address}/${link.prefixLength}`);
    }
    // DNS order is significant (primary/secondary); address ordering is not.
    next.addresses.sort();
  }

  private readCurrentSnapshot(): NetworkSnapshot | null {
    try {
      const handle = connection.getDefaultNetSync();
      const next = new NetworkSnapshot();
      if (handle === null || handle === undefined || handle.netId === 0) {
        next.netType = NetTypes.NONE;
        return next;
      }
      next.netId = handle.netId;
      const caps = connection.getNetCapabilitiesSync(handle);
      const bearers: number[] = [];
      for (const bearer of caps.bearerTypes || []) { bearers.push(bearer as number); }
      next.netType = normalizeNetType(bearers, true);
      next.validated = (caps.networkCap || []).includes(connection.NetCap.NET_CAPABILITY_VALIDATED);
      next.metered = !(caps.networkCap || []).includes(connection.NetCap.NET_CAPABILITY_NOT_METERED);
      try { this.applyProperties(next, connection.getConnectionPropertiesSync(handle)); } catch (e) {
        // Partial OS replies must not erase known properties of the same network.
        if (this.current.netId === next.netId) {
          next.interfaceName = this.current.interfaceName;
          next.addresses = this.current.addresses.slice();
          next.dnsServers = this.current.dnsServers.slice();
        }
      }
      return next;
    } catch (e) {
      // Query failure is not evidence of network loss. Keep last known state.
      AppLogger.warn(TAG, 'network snapshot query failed: ' + AppLogger.errText(e));
      return null;
    }
  }

  feedForTest(netType: string): void {
    const next = new NetworkSnapshot();
    next.netType = netType;
    this.observe(next);
  }

  feedSnapshotForTest(next: NetworkSnapshot): void { this.observe(next); }

  private cancelPending(): void {
    if (this.timer >= 0) { clearTimeout(this.timer); this.timer = -1; }
    this.pending = null;
  }

  private observe(next: NetworkSnapshot): void {
    if (this.pending !== null && next.fingerprint() === this.pending.fingerprint()) { return; }
    if (this.observed && next.fingerprint() === this.current.fingerprint()) {
      this.cancelPending();
      return;
    }
    this.cancelPending();
    if (!this.observed || next.netType === NetTypes.NONE || this.debounceMs === 0) {
      this.publish(next);
      return;
    }
    this.pending = next.copy();
    const epoch = this.epoch;
    this.timer = setTimeout((): void => {
      this.timer = -1;
      if (epoch !== this.epoch) { return; }
      const pending = this.pending;
      this.pending = null;
      if (pending !== null) { this.publish(pending); }
    }, this.debounceMs);
  }

  private publish(next: NetworkSnapshot): void {
    this.current = next.copy();
    this.observed = true;
    this.gen++;
    for (const listener of this.listeners.slice()) {
      try { listener.onNetworkTypeChanged(next.netType, this.gen, next.copy()); } catch (e) {
        AppLogger.warn(TAG, 'network listener failed: ' + AppLogger.errText(e));
      }
    }
  }
}
