/**
 * 内核节点目录服务（Core Catalog Service）
 *
 * 职责：把 mihomo REST `/proxies` 的原始 JSON 变成可复用的目录快照，并封装
 *       「节点选择」这一动作（FlClash `changeProxy` 的对等实现）。
 *
 * 来源：
 *  - FlClash `lib/providers/actions/proxies.dart:114-221`（updateGroups / changeProxy）
 *    → 组/节点来自内核，选点走内核 API，选完重置连接。
 *  - FlClash `core/proxy.go:84-190`（handleGetProxies / handleChangeProxy）
 *  - 规格文档 `docs/FLCLASH_PARITY_SPEC_2026-10-22.md` §三。
 *
 * 口径：
 *  · 缓存只用于 UI 渲染；每次「节点页/订阅页进入」与「测速批次结束」都刷新一次。
 *  · 刷新失败保留上一份快照（返回 null 表示本次失败，UI 不要清空列表）。
 *  · 选点：优先在节点**所在组**里选（FlClash 同构）；不知所属组时按
 *    「第一个能接受的组」逐个尝试（PROXY 组优先）。
 */
import { ClashApiService } from '../services/ClashApiService';
import { AppLogger } from '../utils/AppLogger';
import { CoreCatalog, CoreCatalogModel, CoreGroup, CoreNode } from './CoreCatalog';

const TAG = 'CoreCatalogService';
/** 快照有效期：小于这个间隔的重复请求直接复用（避免页面切换风暴） */
const SNAPSHOT_TTL_MS = 800;

/**
 * 内核内建策略名（不是可测节点）。
 *
 * FlClash 的 `computeRealSelectedProxyState` 对非代理成员返回空 proxyName ⇒ 不参与
 * 测速；本仓库的节点列表与测速目标必须同样排除它们，否则 DIRECT/REJECT 会以
 * 「超时」出现在节点列表里（FlClash 里不会）。
 */
const BUILTIN_POLICIES: string[] = [
  'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE', 'REMAIN', 'GLOBAL'
];

export function isBuiltinPolicy(name: string): boolean {
  return BUILTIN_POLICIES.includes(name);
}

export class CoreCatalogService {
  private static model: CoreCatalogModel | null = null;
  private static fetchedAt: number = 0;
  private static profileId: string = '';
  private static lastError: string = '';

  /** 最近一次成功的快照；从未成功过返回 null。 */
  static current(): CoreCatalogModel | null {
    return CoreCatalogService.model;
  }

  static fetchedAtMs(): number {
    return CoreCatalogService.fetchedAt;
  }

  static profileIdOfSnapshot(): string {
    return CoreCatalogService.profileId;
  }

  static lastFailure(): string {
    return CoreCatalogService.lastError;
  }

  static clear(): void {
    CoreCatalogService.model = null;
    CoreCatalogService.fetchedAt = 0;
    CoreCatalogService.profileId = '';
  }

  /**
   * 刷新快照。`force=false` 时 800ms 内复用上一份（页面反复 onPageShow 不重复打内核）。
   * 返回 null = 本次刷新失败（保留旧快照）。
   */
  static async refresh(api: ClashApiService | null, force: boolean = false,
    profileId: string = ''): Promise<CoreCatalogModel | null> {
    if (api === null) {
      CoreCatalogService.lastError = 'core unavailable';
      return null;
    }
    const now = Date.now();
    if (!force && CoreCatalogService.model !== null && CoreCatalogService.profileId === profileId
      && now - CoreCatalogService.fetchedAt < SNAPSHOT_TTL_MS) {
      return CoreCatalogService.model;
    }
    const json = await api.proxiesJson();
    if (json === null) {
      CoreCatalogService.lastError = 'GET /proxies failed';
      return CoreCatalogService.model;
    }
    const parsed = CoreCatalog.parse(json);
    if (parsed === null) {
      CoreCatalogService.lastError = 'parse /proxies failed';
      AppLogger.warn(TAG, 'parse /proxies failed');
      return CoreCatalogService.model;
    }
    CoreCatalogService.model = parsed;
    // 空 profileId（选点后刷 now、后台测速等强制刷新）**不得**抹掉归属戳：
    // 抹掉后 `profileIdOfSnapshot()` 返回 ''，所有 `coreCatalogFor(subId)` 判假，
    // 「选完节点再开面板」会退化成只有本地节点（丢 now / 延迟）。保留上一次的戳即可，
    // 这些强制刷新的调用方都在「已连上同一份 profile」的前提下执行。
    if (profileId.length > 0) {
      CoreCatalogService.profileId = profileId;
    }
    CoreCatalogService.fetchedAt = now;
    CoreCatalogService.lastError = '';
    return parsed;
  }

  /** 全部可见组（rule 模式下按 hidden 过滤，与 FlClash currentGroupsState 一致）。 */
  static visibleGroups(mode: string): CoreGroup[] {
    const model = CoreCatalogService.model;
    if (model === null) {
      return [];
    }
    if (mode === 'direct') {
      return [];
    }
    if (mode === 'global') {
      return model.groups;
    }
    return model.groups.filter((g: CoreGroup): boolean => !g.hidden);
  }

  /**
   * 拍平成一个「节点列表」视图（订阅页展开区/节点选择页使用）。
   *
   * 顺序：组顺序 → 组内成员顺序；同名节点只保留首次出现（组之间会重复引用同一节点）。
   * 组本身不作为条目（它们不是可测节点）。
   */
  static flattenNodes(mode: string): CoreNode[] {
    const groups = CoreCatalogService.visibleGroups(mode);
    const out: CoreNode[] = [];
    const seen: Set<string> = new Set<string>();
    for (const group of groups) {
      for (const node of group.all) {
        if (node.isGroup || node.name.length === 0 || seen.has(node.name)) {
          continue;
        }
        if (isBuiltinPolicy(node.name)) {
          continue;
        }
        seen.add(node.name);
        out.push(node);
      }
    }
    return out;
  }

  /** 找到包含该节点的组名（优先非 GLOBAL 组）。 */
  static groupOfNode(nodeName: string): string {
    const model = CoreCatalogService.model;
    if (model === null) {
      return '';
    }
    let fallback = '';
    for (const group of model.groups) {
      let hit = false;
      for (const node of group.all) {
        if (node.name === nodeName) {
          hit = true;
          break;
        }
      }
      if (!hit) {
        continue;
      }
      if (group.name === 'GLOBAL') {
        fallback = group.name;
        continue;
      }
      return group.name;
    }
    return fallback;
  }

  /**
   * 选中节点（FlClash `changeProxy` 等价）。
   *
   * 指定 groupName 时只在该组内选；未指定则用 `groupOfNode` 推断，推断失败按
   * PROXY → GLOBAL → 其它组 的顺序逐个尝试（内核会对不属于该组的节点返回 400/404）。
   */
  static async select(api: ClashApiService | null, nodeName: string, groupName: string = ''): Promise<boolean> {
    if (api === null || nodeName.length === 0) {
      return false;
    }
    const candidates: string[] = [];
    if (groupName.length > 0) {
      candidates.push(groupName);
    } else {
      const inferred = CoreCatalogService.groupOfNode(nodeName);
      if (inferred.length > 0) {
        candidates.push(inferred);
      }
      if (!candidates.includes('PROXY')) {
        candidates.push('PROXY');
      }
      if (!candidates.includes('GLOBAL')) {
        candidates.push('GLOBAL');
      }
      const model = CoreCatalogService.model;
      if (model !== null) {
        for (const group of model.groups) {
          if (!candidates.includes(group.name)) {
            candidates.push(group.name);
          }
        }
      }
    }
    for (const target of candidates) {
      const ok = await api.selectProxyInGroup(target, nodeName);
      if (ok) {
        AppLogger.info(TAG, `selected "${nodeName}" in group "${target}"`);
        // 选点后刷新一次快照（now 字段变化），失败不影响选点结论
        await CoreCatalogService.refresh(api, true);
        return true;
      }
    }
    AppLogger.warn(TAG, `select "${nodeName}" failed in every candidate group`);
    return false;
  }
}
