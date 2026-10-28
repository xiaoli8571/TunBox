/**
 * 桌面服务卡片状态同步。
 *
 * 统一负责：真实状态轻量校准、结构化 BindingData、全部卡片广播、
 * formId 串行增删和失效 ID 批量清理。这里仅读取本地状态与持久化数据，
 * 不刷新订阅、不访问公网，也不做秒级轮询。
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { UnifiedScheduler } from './UnifiedScheduler';
import { preferences } from '@kit.ArkData';
import { ConnectionOrchestrator, ConnState } from './ConnectionOrchestrator';
import { SettingsService } from './SettingsService';
import { SubscriptionService } from './SubscriptionService';
import { ProxyNode } from '../models/ProxyNode';
import { AppLogger } from '../utils/AppLogger';
import { FormInfoMetrics } from './FormInfoMetrics';
import { TunBoxNotifier } from './TunBoxNotifier';

const TAG = 'FormStateSync';
const FORM_PREF = 'tunbox_forms';
const FORM_IDS_KEY = 'form_ids';
const FORM_RECORDS_KEY = 'form_records';
export const TOGGLE_FORM_NAME = 'TunBoxToggleCard';
export const INFO_FORM_NAME = 'TunBoxInfoCard';
const INFO_REFRESH_INTERVAL_MS = 3000;
/** 权威对账间隔：内核崩溃/心跳超时后最长 3s 内卡片即变为已断开 */
const RECONCILE_INTERVAL_MS = 3000;

class FormRecord {
  formId: string = '';
  formName: string = TOGGLE_FORM_NAME;
}

export enum FormStateCode {
  DISCONNECTED = 'disconnected',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  DISCONNECTING = 'disconnecting',
  RECOVERING = 'recovering',
  NO_NODE = 'no_node',
  FAILED = 'failed'
}

/** 使用 class 避免 ArkTS 无类型对象字面量，同时直接作为 Form BindingData。 */
export class FormStateSnapshot {
  stateCode: string = FormStateCode.DISCONNECTED;
  stateLabel: string = '未连接';
  nodeName: string = '未选择节点';
  actionLabel: string = '连接';
  busy: boolean = false;
  memoryText: string = '--';
  publicIp: string = '--';
  uploadSpeedText: string = '0 B/s';
  downloadSpeedText: string = '0 B/s';
  connectionDurationText: string = '00:00:00';
  accessibilityLabel: string = 'TunBox，未连接，未选择节点，连接';
}

export class FormStateSync {
  /** preferences 清单变更串行化，防止 add/remove/失效清理并发覆盖。 */
  private static idMutationTail: Promise<void> = Promise.resolve();
  /** 状态发布串行化，避免较早的异步广播晚于新状态落地。 */
  private static publishTail: Promise<void> = Promise.resolve();
  /** 仅有信息卡片登记时运行的低频指标刷新器。 */
  private static infoRefreshTimer: number = -1;
  private static infoRefreshContext: Context | null = null;
  /** 防止一次指标刷新超过 5s 后与下一轮重叠，避免重复请求和内存峰值。 */
  private static infoRefreshRunning: boolean = false;
  /** 权威对账定时器：卡片进程存活期间持续把真实状态纠偏回全部卡片。 */
  private static reconcileTimer: number = -1;
  private static reconcileContext: Context | null = null;
  /** 慢设备或存储繁忙时禁止 3s 对账任务重入。 */
  private static reconcileRunning: boolean = false;

  static disconnected(nodeName: string = ''): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.DISCONNECTED, nodeName);
  }

  static connecting(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.CONNECTING, nodeName);
  }

  static connected(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.CONNECTED, nodeName);
  }

  static disconnecting(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.DISCONNECTING, nodeName);
  }

  static recovering(nodeName: string): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.RECOVERING, nodeName);
  }

  static noNode(): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.NO_NODE, '未选择节点');
  }

  static failed(nodeName: string = ''): FormStateSnapshot {
    return FormStateSync.createSnapshot(FormStateCode.FAILED, nodeName);
  }

  /**
   * 为 onAddForm 的同步返回提供即时状态。只读取进程状态和本地心跳，
   * 不执行异步初始化；完整权威判定由随后的 calibrate()/reconcile() 回填。
   * 注意：这里绝不凭进程内 state 报"已连接" —— 新进程 state 恒为 DISCONNECTED，
   * 唯一可信证据是心跳新鲜/存活标记。
   */
  static immediate(context: Context): FormStateSnapshot {
    const orchestrator = ConnectionOrchestrator.instance();
    orchestrator.init(context);
    if (orchestrator.state === ConnState.CONNECTING) {
      return FormStateSync.connecting('');
    }
    if (orchestrator.state === ConnState.DISCONNECTING) {
      return FormStateSync.disconnecting('');
    }
    if (orchestrator.state === ConnState.RECOVERING) {
      return FormStateSync.recovering('');
    }
    // 心跳新鲜或存活标记存在 = 内核确实在跑（与持久化意图一致地报已连接）。
    if (orchestrator.state === ConnState.CONNECTED || orchestrator.isTunnelAlive()) {
      return FormStateSync.connected('');
    }
    if (orchestrator.lastError.length > 0) {
      return FormStateSync.failed('');
    }
    return FormStateSync.disconnected('');
  }

  /**
   * 读取本地持久化节点和隧道心跳，生成真实快照。
   * 可安全用于 onAddForm/onUpdateForm/onChangeFormVisibility。
   */
  static async calibrate(context: Context): Promise<FormStateSnapshot> {
    try {
      await SettingsService.init(context);
      const subscriptions = SubscriptionService.instance();
      await subscriptions.init(context);
      const settings = await SettingsService.load();
      // 作用域化：跨订阅旧偏好不再上卡片；fallbackConnectionNode 已滤信息条目。
      // 2026-10-27：name+id 双锚解析，避免连接自愈只保留 name 时卡片变空。
      const selected: ProxyNode | null = subscriptions.resolveUserPreference(
        settings.preferredNodeId, settings.preferredNodeName)
        ?? subscriptions.fallbackConnectionNode();
      const nodeName = selected === null ? '' : selected.name;
      const orchestrator = ConnectionOrchestrator.instance();
      orchestrator.init(context);

      // 进行中的显式过渡态优先（避免连接/断开中途闪烁为终态）
      if (orchestrator.state === ConnState.CONNECTING) {
        return FormStateSync.connecting(nodeName);
      }
      if (orchestrator.state === ConnState.DISCONNECTING) {
        return FormStateSync.disconnecting(nodeName);
      }
      if (orchestrator.state === ConnState.RECOVERING) {
        return FormStateSync.recovering(nodeName);
      }
      // 权威判定：持久化意图 ∧ 内核存活证据。内核退出/心跳超时 → 立即已断开。
      const authority = await orchestrator.authorityState();
      if (authority.connected) {
        return FormStateSync.connected(nodeName);
      }
      if (selected === null) {
        return FormStateSync.noNode();
      }
      // 用户期望连接但内核已死：明确报"已断开"，不再残留「已连接/断开」按钮。
      if (authority.desiredConnected) {
        AppLogger.warn(TAG, `tunnel lost (${authority.reason}); publishing disconnected`);
        return FormStateSync.disconnected(nodeName);
      }
      if (orchestrator.lastError.length > 0) {
        return FormStateSync.failed(nodeName);
      }
      return FormStateSync.disconnected(nodeName);
    } catch (error) {
      AppLogger.warn(TAG, `calibrate failed: ${AppLogger.errText(error)}`);
      return FormStateSync.disconnected();
    }
  }

  /**
   * 权威状态对账：任何一个入口（卡片冷启动/页面 onPageShow/通知刷新）都可调用。
   * 它把"持久化意图 + 内核存活证据"算出的真实状态广播给全部卡片，并在内核
   * 退出 / 心跳超时 / 用户已断开时立即把卡片更新为已断开，同时撤销常驻通知 ——
   * 这是卡片路径进程（QuickToggleAbility 自毁后）唯一仍能持续纠偏的通道。
   */
  static async reconcile(context: Context): Promise<FormStateSnapshot> {
    const snapshot = await FormStateSync.calibrate(context);
    await FormStateSync.publish(context, snapshot);
    if (snapshot.stateCode !== FormStateCode.CONNECTED) {
      // 隧道已不可用：撤销常驻通知，避免"卡片已断开但通知还挂着"。
      TunBoxNotifier.cancel().catch((): void => {
      });
    }
    return snapshot;
  }

  /** EntryFormAbility 新增卡片时按 formId/formName 登记。 */
  static addForm(context: Context, formId: string, formName: string): Promise<void> {
    return FormStateSync.enqueueIdMutation(async (): Promise<void> => {
      const records = await FormStateSync.readFormRecords(context);
      let found = false;
      for (const record of records) {
        if (record.formId === formId) {
          record.formName = FormStateSync.normalizeFormName(formName);
          found = true;
          break;
        }
      }
      if (!found) {
        const record = new FormRecord();
        record.formId = formId;
        record.formName = FormStateSync.normalizeFormName(formName);
        records.push(record);
      }
      await FormStateSync.writeFormRecords(context, records);
      FormStateSync.reconcileInfoRefresh(context, records);
    });
  }

  /** 兼容已有调用，旧登记默认视为快捷开关卡片。 */
  static addFormId(context: Context, formId: string): Promise<void> {
    return FormStateSync.addForm(context, formId, TOGGLE_FORM_NAME);
  }

  /** EntryFormAbility 移除卡片时销账。 */
  static removeFormId(context: Context, formId: string): Promise<void> {
    return FormStateSync.removeFormIds(context, [formId]);
  }

  /** 单卡片更新，生命周期校准使用。 */
  static async updateOne(formId: string, snapshot: FormStateSnapshot): Promise<void> {
    await formProvider.updateForm(formId, formBindingData.createFormBindingData(snapshot));
  }

  /** 按卡片类型补充信息字段。普通生命周期仅读内存和公网 IP 缓存。 */
  static async updateRegisteredOne(context: Context, formId: string,
    snapshot: FormStateSnapshot): Promise<void> {
    const formName = await FormStateSync.formNameForId(context, formId);
    const payload = formName === INFO_FORM_NAME
      ? await FormStateSync.withInfoMetrics(context, snapshot) : snapshot;
    await FormStateSync.updateOne(formId, payload);
  }

  /** 广播结构化状态到全部登记卡片。 */
  static publish(context: Context, snapshot: FormStateSnapshot): Promise<void> {
    const task = FormStateSync.publishTail.then(async (): Promise<void> => {
      let records: FormRecord[] = [];
      try {
        records = await FormStateSync.readFormRecords(context);
      } catch (error) {
        AppLogger.warn(TAG,
          `read form records failed: ${AppLogger.errText(error)}`);
        return;
      }
      if (records.length === 0) {
        // headless 路径（快捷方式/卡片进程）且没有任何登记卡片时，
        // 完全不要触碰 FormKit 这类 UI-only API —— 无卡片可更新，
        // 徒增 js_form_provider 噪声与无界面进程里的窗口/表单耦合风险。
        return;
      }
      const invalidIds: string[] = [];
      let infoSnapshot: FormStateSnapshot | null = null;
      for (const record of records) {
        try {
          let payload = snapshot;
          if (record.formName === INFO_FORM_NAME) {
            if (infoSnapshot === null) {
              infoSnapshot = await FormStateSync.withInfoMetrics(context, snapshot);
            }
            payload = infoSnapshot;
          }
          await FormStateSync.updateOne(record.formId, payload);
        } catch (error) {
          invalidIds.push(record.formId);
          AppLogger.warn(TAG, `updateForm failed: formId=${record.formId}`);
        }
      }
      if (invalidIds.length > 0) {
        await FormStateSync.removeFormIds(context, invalidIds);
      }
    });
    FormStateSync.publishTail = task.catch((): void => {
    });
    return task;
  }

  /** 兼容无需 await 的状态发布调用点；错误不影响 VPN 主流程。 */
  static push(context: Context, snapshot: FormStateSnapshot): void {
    FormStateSync.publish(context, snapshot).catch((error: Error): void => {
      AppLogger.warn(TAG, `publish failed: ${error.message}`);
    });
  }

  private static createSnapshot(stateCode: FormStateCode, nodeName: string): FormStateSnapshot {
    const snapshot = new FormStateSnapshot();
    snapshot.stateCode = stateCode;
    snapshot.nodeName = nodeName.length > 0 ? nodeName : '未选择节点';
    if (stateCode === FormStateCode.CONNECTING) {
      snapshot.stateLabel = '连接中';
      snapshot.actionLabel = '连接中';
      snapshot.busy = true;
    } else if (stateCode === FormStateCode.CONNECTED) {
      snapshot.stateLabel = '已连接';
      snapshot.actionLabel = '断开';
    } else if (stateCode === FormStateCode.DISCONNECTING) {
      snapshot.stateLabel = '断开中';
      snapshot.actionLabel = '断开中';
      snapshot.busy = true;
    } else if (stateCode === FormStateCode.RECOVERING) {
      snapshot.stateLabel = '恢复中';
      snapshot.actionLabel = '请稍候';
      snapshot.busy = true;
    } else if (stateCode === FormStateCode.NO_NODE) {
      snapshot.stateLabel = '无可用节点';
      snapshot.actionLabel = '打开应用';
    } else if (stateCode === FormStateCode.FAILED) {
      snapshot.stateLabel = '连接失败';
      snapshot.actionLabel = '重试';
    } else {
      snapshot.stateLabel = '未连接';
      snapshot.actionLabel = '连接';
    }
    snapshot.accessibilityLabel = `TunBox，${snapshot.stateLabel}，当前节点${snapshot.nodeName}，${snapshot.actionLabel}`;
    return snapshot;
  }

  private static enqueueIdMutation(operation: () => Promise<void>): Promise<void> {
    const task = FormStateSync.idMutationTail.then(operation);
    FormStateSync.idMutationTail = task.catch((): void => {
    });
    return task;
  }

  private static removeFormIds(context: Context, removedIds: string[]): Promise<void> {
    return FormStateSync.enqueueIdMutation(async (): Promise<void> => {
      const current = await FormStateSync.readFormRecords(context);
      const kept: FormRecord[] = [];
      for (const record of current) {
        if (!removedIds.includes(record.formId)) {
          kept.push(record);
        }
      }
      await FormStateSync.writeFormRecords(context, kept);
      FormStateSync.reconcileInfoRefresh(context, kept);
    });
  }

  /** Ability 销毁时停止刷新，避免后台残留定时器。 */
  static stopInfoRefresh(): void {
    if (FormStateSync.infoRefreshTimer >= 0) {
      UnifiedScheduler.clear(FormStateSync.infoRefreshTimer);
      FormStateSync.infoRefreshTimer = -1;
    }
    FormStateSync.infoRefreshContext = null;
    FormStateSync.infoRefreshRunning = false;
    FormStateSync.stopReconcile();
  }

  /**
   * 启动权威对账定时器（卡片进程保活期间的有效纠偏通道）。
   * 卡片路径连接后 QuickToggleAbility 自毁，UI 侧监控随之消失；只要
   * EntryFormAbility 进程仍在，本定时器就按 3s 周期重算权威状态 —— 内核退出 /
   * 心跳超时后立即把卡片与通知更新为已断开（修复"卡片仍显示已连接"）。
   */
  static startReconcile(context: Context): void {
    FormStateSync.reconcileContext = context;
    if (FormStateSync.reconcileTimer >= 0) {
      return;
    }
    FormStateSync.reconcileTimer = UnifiedScheduler.every((): void => {
      const active = FormStateSync.reconcileContext;
      if (active === null || FormStateSync.reconcileRunning) {
        return;
      }
      FormStateSync.reconcileRunning = true;
      FormStateSync.reconcile(active).catch((error: Error): void => {
        AppLogger.warn(TAG, `reconcile failed: ${error.message}`);
      }).finally((): void => {
        FormStateSync.reconcileRunning = false;
      });
    }, RECONCILE_INTERVAL_MS);
  }

  static stopReconcile(): void {
    if (FormStateSync.reconcileTimer >= 0) {
      UnifiedScheduler.clear(FormStateSync.reconcileTimer);
      FormStateSync.reconcileTimer = -1;
    }
    FormStateSync.reconcileContext = null;
    FormStateSync.reconcileRunning = false;
  }

  static isReconcileRunning(): boolean {
    return FormStateSync.reconcileTimer >= 0;
  }

  private static reconcileInfoRefresh(context: Context, records: FormRecord[]): void {
    let hasInfoForm = false;
    for (const record of records) {
      if (record.formName === INFO_FORM_NAME) {
        hasInfoForm = true;
        break;
      }
    }
    if (!hasInfoForm) {
      FormStateSync.stopInfoRefresh();
      return;
    }
    FormStateSync.infoRefreshContext = context;
    if (FormStateSync.infoRefreshTimer >= 0) {
      return;
    }
    FormStateSync.infoRefreshTimer = UnifiedScheduler.every((): void => {
      const activeContext = FormStateSync.infoRefreshContext;
      if (activeContext === null || FormStateSync.infoRefreshRunning) {
        return;
      }
      FormStateSync.infoRefreshRunning = true;
      FormStateSync.refreshInfoForms(activeContext).catch((error: Error): void => {
        AppLogger.warn(TAG, `info refresh failed: ${error.message}`);
      }).finally((): void => {
        FormStateSync.infoRefreshRunning = false;
      });
    }, INFO_REFRESH_INTERVAL_MS);
  }

  private static async refreshInfoForms(context: Context): Promise<void> {
    const records = await FormStateSync.readFormRecords(context);
    const infoRecords: FormRecord[] = [];
    for (const record of records) {
      if (record.formName === INFO_FORM_NAME) {
        infoRecords.push(record);
      }
    }
    if (infoRecords.length === 0) {
      FormStateSync.stopInfoRefresh();
      return;
    }
    const calibrated = await FormStateSync.calibrate(context);
    const payload = await FormStateSync.withInfoMetrics(context, calibrated);
    const invalidIds: string[] = [];
    for (const record of infoRecords) {
      try {
        await FormStateSync.updateOne(record.formId, payload);
      } catch (error) {
        invalidIds.push(record.formId);
      }
    }
    if (invalidIds.length > 0) {
      await FormStateSync.removeFormIds(context, invalidIds);
    }
  }

  private static async formNameForId(context: Context, formId: string): Promise<string> {
    const records = await FormStateSync.readFormRecords(context);
    for (const record of records) {
      if (record.formId === formId) {
        return record.formName;
      }
    }
    return TOGGLE_FORM_NAME;
  }

  private static async withInfoMetrics(context: Context,
    source: FormStateSnapshot): Promise<FormStateSnapshot> {
    const snapshot = FormStateSync.copySnapshot(source);
    snapshot.memoryText = await FormInfoMetrics.memoryText();
    snapshot.publicIp = await FormInfoMetrics.cachedPublicIp(context);
    const orchestrator = ConnectionOrchestrator.instance();
    snapshot.uploadSpeedText = FormStateSync.formatSpeed(orchestrator.traffic.uploadSpeed);
    snapshot.downloadSpeedText = FormStateSync.formatSpeed(orchestrator.traffic.downloadSpeed);
    const seconds = orchestrator.startedAt > 0 ? Math.max(0, Math.floor((Date.now() - orchestrator.startedAt) / 1000)) : 0;
    const h = Math.floor(seconds / 3600).toString().padStart(2, '0');
    const m = Math.floor((seconds % 3600) / 60).toString().padStart(2, '0');
    const s = (seconds % 60).toString().padStart(2, '0');
    snapshot.connectionDurationText = `${h}:${m}:${s}`;
    return snapshot;
  }

  private static formatSpeed(bytesPerSecond: number): string {
    if (!Number.isFinite(bytesPerSecond) || bytesPerSecond <= 0) {
      return '0 B/s';
    }
    if (bytesPerSecond < 1024) {
      return `${Math.round(bytesPerSecond)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / (1024 * 1024)).toFixed(1)} MB/s`;
  }

  private static copySnapshot(source: FormStateSnapshot): FormStateSnapshot {
    const target = new FormStateSnapshot();
    target.stateCode = source.stateCode;
    target.stateLabel = source.stateLabel;
    target.nodeName = source.nodeName;
    target.actionLabel = source.actionLabel;
    target.busy = source.busy;
    target.memoryText = source.memoryText;
    target.publicIp = source.publicIp;
    target.uploadSpeedText = source.uploadSpeedText;
    target.downloadSpeedText = source.downloadSpeedText;
    target.connectionDurationText = source.connectionDurationText;
    target.accessibilityLabel = source.accessibilityLabel;
    return target;
  }

  private static normalizeFormName(formName: string): string {
    return formName === INFO_FORM_NAME ? INFO_FORM_NAME : TOGGLE_FORM_NAME;
  }

  private static async readFormRecords(context: Context): Promise<FormRecord[]> {
    const store = await preferences.getPreferences(context, { name: FORM_PREF });
    const raw = await store.get(FORM_RECORDS_KEY, '') as string;
    const records = FormStateSync.parseRecords(raw);
    if (records.length > 0 || raw.length > 0) {
      return records;
    }
    const legacyRaw = await store.get(FORM_IDS_KEY, '[]') as string;
    const legacyIds = FormStateSync.parseIds(legacyRaw);
    for (const id of legacyIds) {
      const record = new FormRecord();
      record.formId = id;
      records.push(record);
    }
    return records;
  }

  private static async writeFormRecords(context: Context, records: FormRecord[]): Promise<void> {
    const store = await preferences.getPreferences(context, { name: FORM_PREF });
    await store.put(FORM_RECORDS_KEY, JSON.stringify(records));
    const ids: string[] = records.map((record: FormRecord): string => record.formId);
    await store.put(FORM_IDS_KEY, JSON.stringify(ids));
    await store.flush();
  }

  private static parseRecords(raw: string): FormRecord[] {
    const result: FormRecord[] = [];
    if (raw.length === 0) {
      return result;
    }
    try {
      const values = JSON.parse(raw) as FormRecord[];
      for (const value of values) {
        if (typeof value.formId === 'string' && value.formId.length > 0) {
          const record = new FormRecord();
          record.formId = value.formId;
          record.formName = FormStateSync.normalizeFormName(value.formName);
          result.push(record);
        }
      }
    } catch (error) {
      AppLogger.warn(TAG, 'form record list is invalid; reset to empty');
    }
    return result;
  }

  private static async readFormIds(context: Context): Promise<string[]> {
    const store = await preferences.getPreferences(context, FORM_PREF);
    const raw = await store.get(FORM_IDS_KEY, '[]') as string;
    return FormStateSync.parseIds(raw);
  }

  private static async writeFormIds(context: Context, ids: string[]): Promise<void> {
    const store = await preferences.getPreferences(context, FORM_PREF);
    await store.put(FORM_IDS_KEY, JSON.stringify(ids));
    await store.flush();
  }

  private static parseIds(raw: string): string[] {
    const result: string[] = [];
    try {
      const values = JSON.parse(raw) as string[];
      if (Array.isArray(values)) {
        for (const value of values) {
          if (typeof value === 'string' && value.length > 0 && !result.includes(value)) {
            result.push(value);
          }
        }
      }
    } catch (error) {
      AppLogger.warn(TAG, 'form id list is invalid; reset to empty');
    }
    return result;
  }
}
