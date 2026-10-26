/**
 * Nexus 备份与恢复引擎 —— 对齐开发文档 §9
 * JSON 契约：{ app, version, exportTime, subscriptions[], nodes[], proxyGroups[], hiddenNodes[], settings }
 * 导出：快照 → JSON → 落盘(经系统文件选择器另存)
 * 导入：FileReader 校验 → restoreBackup 整体覆盖 → persist
 * settings 为完整 AppSettings 快照：含强制代理/直连网站、应用分流名单、
 * 自定义规则、代理模式、偏好节点等全部用户设置。
 */
import { AppSettings, AppSettingsJson } from '../models/AppSettings';
import { Subscription } from '../models/Subscription';
import { ProxyNode } from '../models/ProxyNode';
import { ProxyGroup, ProxyGroupJson } from '../models/ProxyGroup';
import { SettingsService } from './SettingsService';
import { SubscriptionService, SubscriptionJson, ProxyNodeJson } from './SubscriptionService';
import { CredentialStore, SubscriptionCredentialSource } from './CredentialStore';
import { ProfileStore } from '../flclash/ProfileStore';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'BackupRestore';
export const BACKUP_APP = 'TunBox';
export const BACKUP_VERSION = '2.1';

/** 单份订阅的配置原文（含节点密码，恢复后无需联网即可起隧道）。 */
export class ProfileBackupEntry {
  id: string = '';
  yaml: string = '';
}

/** 订阅自定义 header 值（只存在 Asset，不进 preferences）。 */
export class SubscriptionSecretEntry {
  id: string = '';
  headerValue: string = '';
}

export class BackupFile {
  app: string = BACKUP_APP;
  version: string = BACKUP_VERSION;
  exportTime: string = '';
  subscriptions: SubscriptionJson[] = [];
  nodes: ProxyNodeJson[] = [];
  proxyGroups: ProxyGroupJson[] = [];
  hiddenNodes: string[] = [];
  settings: AppSettingsJson | null = null;
  /** 2.1 起：配置原文（内核真正的节点来源） */
  profiles: ProfileBackupEntry[] = [];
  /** 2.1 起：订阅 header 凭据 */
  subscriptionSecrets: SubscriptionSecretEntry[] = [];
  /** 2.1 起：导出时的当前订阅（恢复后直接切回它） */
  currentProfileId: string = '';
}

export class RestoreOutcome {
  ok: boolean = false;
  message: string = '';
  subCount: number = 0;
  nodeCount: number = 0;
}

export class BackupRestoreService {
  /** 导出当前快照为 JSON 字符串（HTML Blob 等价：JSON.stringify 美化） */
  static exportJson(): string {
    const svc = SubscriptionService.instance();
    const subsJson: SubscriptionJson[] = [];
    for (const s of svc.subscriptions) {
      subsJson.push(Subscription.toJson(s));
    }
    const nodesJson: ProxyNodeJson[] = [];
    for (const n of svc.nodes) {
      nodesJson.push(ProxyNodeJson.fromNode(n));
    }
    const file = new BackupFile();
    file.exportTime = new Date().toISOString();
    file.subscriptions = subsJson;
    file.nodes = nodesJson;
    file.proxyGroups = BackupRestoreService.groupsToJson();
    file.hiddenNodes = svc.listHiddenKeys();
    return JSON.stringify(file, null, 2);
  }

  /** 导出（含 settings 全量快照 + 配置原文 + 订阅凭据）—— HomePage 备份弹窗调用此入口。
   *  2.1 起备份是自包含的：只带订阅元数据时，卸载重装后既没有 profiles/*.yaml
   *  （内核节点来源）也没有 Asset 里的节点密码，恢复后就会「选不了节点 / 连不上」。 */
  static async exportJsonWithSettings(settings: AppSettings): Promise<string> {
    const svc = SubscriptionService.instance();
    const subsJson: SubscriptionJson[] = [];
    for (const s of svc.subscriptions) {
      subsJson.push(Subscription.toJson(s));
    }
    const nodesJson: ProxyNodeJson[] = [];
    for (const n of svc.nodes) {
      nodesJson.push(ProxyNodeJson.fromNode(n));
    }
    const file = new BackupFile();
    file.exportTime = new Date().toISOString();
    file.subscriptions = subsJson;
    file.nodes = nodesJson;
    file.proxyGroups = BackupRestoreService.groupsToJson();
    file.hiddenNodes = svc.listHiddenKeys();
    file.settings = settings.toJson();
    file.profiles = BackupRestoreService.collectProfiles(svc);
    file.subscriptionSecrets = await BackupRestoreService.collectSubscriptionSecrets(svc);
    file.currentProfileId = ProfileStore.isReady() ? ProfileStore.currentId() : '';
    return JSON.stringify(file, null, 2);
  }

  /** 收集每份订阅的配置原文（内核真正的节点来源，含节点密码）。 */
  private static collectProfiles(svc: SubscriptionService): ProfileBackupEntry[] {
    const out: ProfileBackupEntry[] = [];
    if (!ProfileStore.isReady()) {
      return out;
    }
    for (const s of svc.subscriptions) {
      if (!ProfileStore.exists(s.id)) {
        continue;
      }
      const yaml = ProfileStore.read(s.id);
      if (yaml.length === 0) {
        continue;
      }
      const entry = new ProfileBackupEntry();
      entry.id = s.id;
      entry.yaml = yaml;
      out.push(entry);
    }
    return out;
  }

  /** 收集订阅自定义 header 值（Asset Store 里，卸载即丢）。 */
  private static async collectSubscriptionSecrets(svc: SubscriptionService): Promise<SubscriptionSecretEntry[]> {
    const out: SubscriptionSecretEntry[] = [];
    for (const s of svc.subscriptions) {
      const value = await CredentialStore.subscriptionCredential(s.id, '');
      if (value.length === 0) {
        continue;
      }
      const entry = new SubscriptionSecretEntry();
      entry.id = s.id;
      entry.headerValue = value;
      out.push(entry);
    }
    return out;
  }

  private static groupsToJson(): ProxyGroupJson[] {
    const svc = SubscriptionService.instance();
    const out: ProxyGroupJson[] = [];
    for (const g of svc.proxyGroups) {
      out.push(ProxyGroup.toJson(g));
    }
    return out;
  }

  /** 默认备份文件名 tunbox_vpn_backup_YYYY-MM-DD.json（导入不校验 app 字段，旧 Nexus 备份仍可导入） */
  static defaultFileName(): string {
    const d = new Date();
    const mm = `0${d.getMonth() + 1}`.slice(-2);
    const dd = `0${d.getDate()}`.slice(-2);
    return `tunbox_vpn_backup_${d.getFullYear()}-${mm}-${dd}.json`;
  }

  /**
   * 导入：校验 → restoreBackup 整体覆盖（订阅/节点/代理组/隐藏名单/设置）→ persist。
   * 节点经 mapNodes 重建（id 原样保留，偏好节点引用不断链）；
   * 凭据回填由 persist 内 storeCredentials 承担。
   */
  static async importJsonText(text: string): Promise<RestoreOutcome> {
    const out = new RestoreOutcome();
    let parsed: BackupFile;
    try {
      parsed = JSON.parse(text) as BackupFile;
    } catch (e) {
      out.message = '解析备份文件失败，请确保是合法的 JSON 备份';
      return out;
    }
    if (parsed === null || typeof parsed !== 'object' || !Array.isArray(parsed.subscriptions)) {
      out.message = '备份文件格式不正确，缺少订阅数据';
      return out;
    }
    // 1. 恢复订阅元数据（逐项校验关键字段）
    const restoredSubs: Subscription[] = [];
    for (const j of parsed.subscriptions) {
      if (j === null || typeof j !== 'object') {
        continue;
      }
      const id = typeof j.id === 'string' ? j.id : '';
      const name = typeof j.name === 'string' ? j.name : '';
      const url = typeof j.url === 'string' ? j.url : '';
      if (id.length === 0 || name.length === 0) {
        continue;
      }
      const s = new Subscription();
      s.id = id;
      s.name = name;
      s.url = url;
      s.headerName = typeof j.headerName === 'string' ? j.headerName : '';
      s.lastFetchedAt = typeof j.lastFetchedAt === 'number' ? j.lastFetchedAt : 0;
      s.lastRefreshResult = typeof j.lastRefreshResult === 'string' ? j.lastRefreshResult : '';
      s.nodeCount = typeof j.nodeCount === 'number' ? j.nodeCount : 0;
      s.uploadBytes = typeof j.uploadBytes === 'number' ? j.uploadBytes : -1;
      s.downloadBytes = typeof j.downloadBytes === 'number' ? j.downloadBytes : -1;
      s.totalBytes = typeof j.totalBytes === 'number' ? j.totalBytes : -1;
      s.expireAt = typeof j.expireAt === 'number' ? j.expireAt : -1;
      s.enabled = typeof j.enabled === 'boolean' ? j.enabled : true;
      s.sortOrder = typeof j.sortOrder === 'number' ? j.sortOrder : 0;
      s.rawProviderState = typeof j.rawProviderState === 'string' ? j.rawProviderState : '';
      s.rawProviderNodeEstimate = typeof j.rawProviderNodeEstimate === 'number' ? j.rawProviderNodeEstimate : 0;
      s.etag = typeof j.etag === 'string' ? j.etag : '';
      restoredSubs.push(s);
    }
    if (restoredSubs.length === 0) {
      out.message = '备份中没有可用订阅';
      return out;
    }
    const subIds = new Set<string>();
    for (const s of restoredSubs) {
      subIds.add(s.id);
    }
    // 2. 恢复节点（可选：无节点则仅恢复订阅元数据，用户刷新即可）
    let restoredNodes: ProxyNode[] = [];
    if (Array.isArray(parsed.nodes) && parsed.nodes.length > 0) {
      try {
        const nodes = SubscriptionService.mapNodes(parsed.nodes as Object);
        restoredNodes = nodes.filter((n) => subIds.has(n.subscriptionId));
      } catch (e) {
        AppLogger.warn(TAG, `nodes restore skipped: ${AppLogger.errText(e)}`);
        restoredNodes = [];
      }
    }
    // 3. 恢复代理组（仅保留归属订阅存在的组；旧备份无此段则为空）
    let restoredGroups: ProxyGroup[] = [];
    if (Array.isArray(parsed.proxyGroups) && parsed.proxyGroups.length > 0) {
      try {
        const groups = SubscriptionService.parseGroups(parsed.proxyGroups as Object);
        restoredGroups = groups.filter((g) => subIds.has(g.subscriptionId));
      } catch (e) {
        AppLogger.warn(TAG, `groups restore skipped: ${AppLogger.errText(e)}`);
        restoredGroups = [];
      }
    }
    // 4. 恢复隐藏名单（字符串数组清洗）
    let restoredHidden: string[] = [];
    if (Array.isArray(parsed.hiddenNodes)) {
      for (const h of parsed.hiddenNodes as Object[]) {
        if (typeof h === 'string' && h.length > 0 && h.length <= 4096) {
          restoredHidden.push(h);
        }
      }
    }
    // 5. 整体覆盖 + 落盘（restoreBackup 内 initNodes + persist）
    const svc = SubscriptionService.instance();
    await svc.restoreBackup(restoredSubs, restoredNodes, restoredGroups, restoredHidden);
    // 5.1 恢复配置原文 + 订阅 header 凭据，并把 current profile 切回去。
    //     没有这一段时：卸载重装后 profiles/*.yaml 与 Asset 里的节点密码都不存在，
    //     界面能看到节点，但内核没有节点来源 / 没有密码 → 选不了节点、连不上。
    const profilesRestored = await BackupRestoreService.restoreProfiles(parsed, subIds, restoredSubs);
    // 5.2 旧备份（2.0 及更早没有 profiles）：给缺原文的启用订阅排队后台补拉一次，
    //     否则恢复后订阅列表在、内核节点表永远是空的（用户看到的「刷新不出来」）。
    const needRefresh: string[] = [];
    for (const s of restoredSubs) {
      if (s.enabled && !ProfileStore.exists(s.id)) {
        needRefresh.push(s.id);
      }
    }
    if (needRefresh.length > 0) {
      setTimeout((): void => {
        const runBackfill = async (): Promise<void> => {
          for (const id of needRefresh) {
            try {
              await svc.refreshSubscription(id);
            } catch (e) {
              AppLogger.warn(TAG, `post-restore refresh failed: ${AppLogger.errText(e)}`);
            }
          }
        };
        runBackfill();
      }, 800);
    }
    // 6. 恢复 settings 全量（强制代理/直连网站、应用分流、自定义规则、代理模式等）
    if (parsed.settings !== null && typeof parsed.settings === 'object') {
      try {
        const settings = AppSettings.fromJson(parsed.settings as AppSettingsJson);
        // 代理模式是本机当前运行状态，不从备份覆盖：备份里常是被测出来的 global，
        // 恢复后用户会看到「装完就是全局模式」，且全局 + 缺节点时连不上。
        const live = await SettingsService.load();
        if (live.proxyMode === 'global' || live.proxyMode === 'direct' || live.proxyMode === 'rule') {
          settings.proxyMode = live.proxyMode;
        }
        await SettingsService.save(settings);
      } catch (e) {
        AppLogger.warn(TAG, `settings restore skipped: ${AppLogger.errText(e)}`);
      }
    }
    out.ok = true;
    out.subCount = restoredSubs.length;
    out.nodeCount = restoredNodes.length;
    out.message = `恢复成功，已导入 ${restoredSubs.length} 个订阅` +
      (restoredNodes.length > 0 ? `/${restoredNodes.length} 个节点` : '') +
      (profilesRestored > 0 ? `、${profilesRestored} 份配置原文` : '') +
      (needRefresh.length > 0 ? `；${needRefresh.length} 个订阅缺少配置原文，正在后台重新拉取` : '');
    return out;
  }

  /**
   * 写回 profiles/*.yaml 并切回 current，再把订阅 header 凭据补进 Asset。
   * 备份里没有 profiles 段（2.0 旧备份）时返回 0，由调用方排队后台刷新。
   */
  private static async restoreProfiles(parsed: BackupFile, subIds: Set<string>,
    subs: Subscription[]): Promise<number> {
    if (!ProfileStore.isReady()) {
      return 0;
    }
    let restored = 0;
    if (Array.isArray(parsed.profiles)) {
      for (const entry of parsed.profiles) {
        if (entry === null || typeof entry !== 'object') {
          continue;
        }
        const id = typeof entry.id === 'string' ? entry.id : '';
        const yaml = typeof entry.yaml === 'string' ? entry.yaml : '';
        if (id.length === 0 || yaml.length === 0 || !subIds.has(id)) {
          continue;
        }
        if (yaml.length > 8 * 1024 * 1024) {
          continue;
        }
        if (ProfileStore.write(id, yaml)) {
          restored++;
        }
      }
    }
    // current profile：优先备份里的那个，失效则退回第一个「启用且有原文」的订阅。
    let current = typeof parsed.currentProfileId === 'string' ? parsed.currentProfileId : '';
    if (current.length === 0 || !ProfileStore.exists(current)) {
      current = '';
      for (const s of subs) {
        if (s.enabled && ProfileStore.exists(s.id)) {
          current = s.id;
          break;
        }
      }
    }
    if (current.length > 0) {
      await ProfileStore.setCurrent(current);
    }
    // 订阅 header 值落在 Asset（preferences 里永远是空的），重装后只能从备份补。
    const sources: SubscriptionCredentialSource[] = [];
    if (Array.isArray(parsed.subscriptionSecrets)) {
      for (const entry of parsed.subscriptionSecrets) {
        if (entry === null || typeof entry !== 'object') {
          continue;
        }
        const id = typeof entry.id === 'string' ? entry.id : '';
        const headerValue = typeof entry.headerValue === 'string' ? entry.headerValue : '';
        if (id.length === 0 || headerValue.length === 0 || !subIds.has(id)) {
          continue;
        }
        const source = new SubscriptionCredentialSource();
        source.id = id;
        source.headerValue = headerValue;
        sources.push(source);
      }
    }
    if (sources.length > 0) {
      await CredentialStore.canonicalize([], sources, true);
    }
    return restored;
  }
}
