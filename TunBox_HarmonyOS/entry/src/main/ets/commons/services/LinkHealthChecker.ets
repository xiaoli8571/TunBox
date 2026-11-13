/**
 * 分阶段链路自检（自包含服务，第二阶段）
 *
 * 背景:
 *   用户反馈「点了连接没反应 / 显示已连接但打不开网页」时，缺少一个可一键执行的
 *   诊断链路，只能靠猜。本模块把「从订阅到出口」的全部关键环节拆成 10 个独立检查，
 *   逐项给出可读原因、可执行建议与一个有限的修复动作序列。
 *
 * 设计约束:
 *   1) 每项检查独立 try/catch + 独立超时：单点失败/挂死绝不阻断其余检查
 *      （因此不能用 Promise.all 一把梭——一项挂死会拖垮整份报告）。
 *   2) 总耗时上限可配置：超预算后剩余检查标记为 skip（而不是 fail），
 *      报告 truncated=true，避免把「没来得及查」误报成「坏了」。
 *   3) 依赖项全部构造注入（LinkHealthProbes 接口式）：无真机也能单测，
 *      真机由集成层提供真实探针实现。
 *   4) 修复动作是**有限、有序、枚举化**的，最多 N 步，天然禁止无限重试/重连风暴。
 *   5) 本模块为纯逻辑：不 import 任何 HarmonyOS SDK，便于离线校验。
 *
 * 检查项顺序（= 报告顺序 = 修复动作优先级）:
 *   subscription → node → vpn-auth → tun → core → clash-api → dns → egress-ipv4
 *   → ipv6(可选) → intent-consistency
 */

/** 单项检查状态 */
export class HealthStatus {
  static readonly PASS: string = 'pass';
  static readonly FAIL: string = 'fail';
  /** 不适用 / 被预算截断 / 需真机但环境不支持 —— 不计入失败 */
  static readonly SKIP: string = 'skip';
}

/** 报告总体状态 */
export class HealthOverall {
  /** 全部通过 */
  static readonly OK: string = 'ok';
  /** 无失败但有跳过项，或报告为空（无法证明是好的） */
  static readonly DEGRADED: string = 'degraded';
  /** 至少一项失败 */
  static readonly BROKEN: string = 'broken';
}

/** 检查项稳定 id */
export class CheckIds {
  static readonly SUBSCRIPTION: string = 'subscription';
  static readonly NODE: string = 'node';
  static readonly VPN_AUTH: string = 'vpn-auth';
  static readonly TUN: string = 'tun';
  static readonly CORE: string = 'core';
  static readonly CLASH_API: string = 'clash-api';
  static readonly DNS: string = 'dns';
  static readonly EGRESS_IPV4: string = 'egress-ipv4';
  static readonly IPV6: string = 'ipv6';
  static readonly INTENT: string = 'intent-consistency';
}

/**
 * 可自动执行的修复动作枚举（有限）。
 * 顺序即执行顺序；同一次自检最多返回 DEFAULT_MAX_REPAIR_STEPS 步。
 */
export class RepairActions {
  static readonly REFRESH_SUBSCRIPTION: string = 'refresh-subscription';
  static readonly RESELECT_NODE: string = 'reselect-node';
  static readonly GRANT_VPN_PERMISSION: string = 'grant-vpn-permission';
  static readonly REBUILD_TUN: string = 'rebuild-tun';
  static readonly RESTART_CORE: string = 'restart-core';
  static readonly RESTART_CLASH_API: string = 'restart-clash-api';
  static readonly FIX_DNS: string = 'fix-dns';
  static readonly CHECK_UPLINK: string = 'check-uplink';
  static readonly RECONCILE_INTENT: string = 'reconcile-intent';
  /** 引导用户开启通知（后台保活/卡片状态依赖通知） */
  static readonly ENABLE_NOTIFICATIONS: string = 'enable-notifications';
}

/** 默认总耗时上限（ms） */
export const DEFAULT_TOTAL_BUDGET_MS: number = 8000;
/** 默认单项超时（ms） */
export const DEFAULT_PER_CHECK_TIMEOUT_MS: number = 1500;
/** 默认最多返回的修复步数 */
export const DEFAULT_MAX_REPAIR_STEPS: number = 3;

/** 检查 id → 默认修复动作（探针未显式给出 repair 时的兜底） */
export function repairForCheck(checkId: string): string {
  switch (checkId) {
    case CheckIds.SUBSCRIPTION:
      return RepairActions.REFRESH_SUBSCRIPTION;
    case CheckIds.NODE:
      return RepairActions.RESELECT_NODE;
    case CheckIds.VPN_AUTH:
      return RepairActions.GRANT_VPN_PERMISSION;
    case CheckIds.TUN:
      return RepairActions.REBUILD_TUN;
    case CheckIds.CORE:
      return RepairActions.RESTART_CORE;
    case CheckIds.CLASH_API:
      return RepairActions.RESTART_CLASH_API;
    case CheckIds.DNS:
      return RepairActions.FIX_DNS;
    case CheckIds.EGRESS_IPV4:
      return RepairActions.CHECK_UPLINK;
    case CheckIds.INTENT:
      return RepairActions.RECONCILE_INTENT;
    default:
      return '';
  }
}

/** 异常对象 → 可读文本（绝不抛；BusinessError 形态 {code,message} 也要正确提取，本文件保持零 SDK 依赖） */
function errText(e: Object): string {
  if (e === null || e === undefined) {
    return 'unknown error';
  }
  const biz = e as Record<string, Object>;
  const msgVal = biz.message;
  if (typeof msgVal === 'string' && (msgVal as string).length > 0) {
    return msgVal as string;
  }
  const text = String(e);
  return (text.length === 0 || text === '[object Object]') ? 'unknown error' : text;
}

/**
 * 单个探针的结论。
 * 探针实现方（集成层）只需产出本对象，不需要知道报告结构。
 */
export class ProbeOutcome {
  /** 检查是否通过 */
  ok: boolean = false;
  /** 是否适用；false → 报告里记为 skip（如设备/网络不支持 IPv6） */
  applicable: boolean = true;
  /** 可读证据/原因 */
  detail: string = '';
  /** 可执行建议（给用户看的一句话） */
  advice: string = '';
  /** 建议的修复动作 id（空 = 用 repairForCheck 兜底） */
  repair: string = '';
  /** 附加量：版本号、IP、节点名等（已脱敏，仅用于展示） */
  value: string = '';

  static pass(detail: string, value: string = ''): ProbeOutcome {
    const o = new ProbeOutcome();
    o.ok = true;
    o.applicable = true;
    o.detail = detail;
    o.value = value;
    return o;
  }

  static fail(detail: string, advice: string, repair: string = ''): ProbeOutcome {
    const o = new ProbeOutcome();
    o.ok = false;
    o.applicable = true;
    o.detail = detail;
    o.advice = advice;
    o.repair = repair;
    return o;
  }

  static skip(detail: string): ProbeOutcome {
    const o = new ProbeOutcome();
    o.ok = false;
    o.applicable = false;
    o.detail = detail;
    return o;
  }
}

/**
 * 链路探针集合（构造注入）。
 * 集成层实现本接口：订阅/授权/TUN/内核走本进程状态与文件，Clash API / DNS /
 * 出口连通性走 http/socket。所有方法必须 resolve，不得 reject（checker 也会兜底）。
 */
export interface LinkHealthProbes {
  probeSubscription(): Promise<ProbeOutcome>;
  probeNode(): Promise<ProbeOutcome>;
  probeVpnAuth(): Promise<ProbeOutcome>;
  probeTun(): Promise<ProbeOutcome>;
  probeCore(): Promise<ProbeOutcome>;
  probeClashApi(): Promise<ProbeOutcome>;
  probeDns(): Promise<ProbeOutcome>;
  probeIpv4Egress(): Promise<ProbeOutcome>;
  probeIpv6(): Promise<ProbeOutcome>;
  probeIntentConsistency(): Promise<ProbeOutcome>;
}

/** 报告中的单项 */
export class LinkHealthItem {
  id: string = '';
  label: string = '';
  status: string = HealthStatus.SKIP;
  detail: string = '';
  advice: string = '';
  /** 已解析出的修复动作（可能为空） */
  repair: string = '';
  value: string = '';
  durationMs: number = 0;

  static make(id: string, label: string, outcome: ProbeOutcome, durationMs: number): LinkHealthItem {
    const item = new LinkHealthItem();
    item.id = id;
    item.label = label;
    item.detail = outcome.detail;
    item.value = outcome.value;
    item.advice = outcome.advice;
    item.repair = outcome.repair.length > 0 ? outcome.repair : repairForCheck(id);
    if (!outcome.applicable) {
      item.status = HealthStatus.SKIP;
      item.advice = '';
      item.repair = '';
    } else {
      item.status = outcome.ok ? HealthStatus.PASS : HealthStatus.FAIL;
      if (outcome.ok) {
        item.advice = '';
        item.repair = '';
      }
    }
    item.durationMs = durationMs >= 0 ? durationMs : 0;
    return item;
  }

  static skipped(id: string, label: string, reason: string): LinkHealthItem {
    return LinkHealthItem.make(id, label, ProbeOutcome.skip(reason), 0);
  }
}

/** 结构化报告 */
export class LinkHealthReport {
  items: LinkHealthItem[] = [];
  /** 自检开始时刻（ms，由注入时钟给出） */
  startedAt: number = 0;
  /** 自检总耗时（ms） */
  totalMs: number = 0;
  /** 是否因总耗时上限而截断（剩余项为 skip） */
  truncated: boolean = false;

  item(id: string): LinkHealthItem | null {
    for (const it of this.items) {
      if (it.id === id) {
        return it;
      }
    }
    return null;
  }
}

/** summarize 的结果 */
export class LinkHealthSummary {
  overall: string = HealthOverall.DEGRADED;
  passCount: number = 0;
  failCount: number = 0;
  skipCount: number = 0;
  /** 首要失败项 id（按报告顺序的第一个 fail）；无失败为 '' */
  firstFailId: string = '';
  firstFailLabel: string = '';
  firstFailDetail: string = '';
  firstFailAdvice: string = '';

  isOk(): boolean {
    return this.overall === HealthOverall.OK;
  }

  isBroken(): boolean {
    return this.overall === HealthOverall.BROKEN;
  }
}

/**
 * 纯函数：汇总报告。
 *   - 空报告 → degraded（没查过就不能说 ok）
 *   - 有 fail → broken，firstFail* 取报告顺序里的第一个 fail
 *   - 无 fail 但有 skip → degraded
 *   - 全 pass → ok
 */
export function summarize(report: LinkHealthReport): LinkHealthSummary {
  const s = new LinkHealthSummary();
  if (report === null || report === undefined || report.items.length === 0) {
    s.overall = HealthOverall.DEGRADED;
    return s;
  }
  for (const item of report.items) {
    if (item.status === HealthStatus.PASS) {
      s.passCount = s.passCount + 1;
    } else if (item.status === HealthStatus.FAIL) {
      s.failCount = s.failCount + 1;
      if (s.firstFailId.length === 0) {
        s.firstFailId = item.id;
        s.firstFailLabel = item.label;
        s.firstFailDetail = item.detail;
        s.firstFailAdvice = item.advice;
      }
    } else {
      s.skipCount = s.skipCount + 1;
    }
  }
  if (s.failCount > 0) {
    s.overall = HealthOverall.BROKEN;
  } else if (s.skipCount > 0) {
    s.overall = HealthOverall.DEGRADED;
  } else {
    s.overall = HealthOverall.OK;
  }
  return s;
}

/**
 * 纯函数：由报告推导「有限、有序、可自动执行」的修复动作序列。
 *   - 只取 fail 项；按报告顺序（= 链路自底向上顺序）
 *   - 动作去重
 *   - 最多 maxSteps 步（<=0 视为 0 → 返回空）
 * 因此天然不会出现无限重试/重连风暴：步数有上限，动作集合是枚举。
 */
export function repairSteps(report: LinkHealthReport, maxSteps: number = DEFAULT_MAX_REPAIR_STEPS): string[] {
  const out: string[] = [];
  if (report === null || report === undefined) {
    return out;
  }
  const cap = maxSteps > 0 ? maxSteps : 0;
  if (cap === 0) {
    return out;
  }
  for (const item of report.items) {
    if (item.status !== HealthStatus.FAIL) {
      continue;
    }
    const action = item.repair.length > 0 ? item.repair : repairForCheck(item.id);
    if (action.length === 0) {
      continue;
    }
    if (out.includes(action)) {
      continue;
    }
    out.push(action);
    if (out.length >= cap) {
      break;
    }
  }
  return out;
}

/** 检查项定义（id + 展示名 + 探针调用） */
class CheckSpec {
  id: string = '';
  label: string = '';
  run: (probes: LinkHealthProbes) => Promise<ProbeOutcome> = (p: LinkHealthProbes): Promise<ProbeOutcome> => {
    return Promise.resolve(ProbeOutcome.skip('not implemented'));
  };

  constructor(id: string, label: string, run: (probes: LinkHealthProbes) => Promise<ProbeOutcome>) {
    this.id = id;
    this.label = label;
    this.run = run;
  }
}

/** 固定的 10 项检查管线（顺序即报告顺序） */
export function buildCheckSpecs(): CheckSpec[] {
  const specs: CheckSpec[] = [];
  specs.push(new CheckSpec(CheckIds.SUBSCRIPTION, '订阅可用性',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeSubscription()));
  specs.push(new CheckSpec(CheckIds.NODE, '节点有效性',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeNode()));
  specs.push(new CheckSpec(CheckIds.VPN_AUTH, 'VPN 授权',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeVpnAuth()));
  specs.push(new CheckSpec(CheckIds.TUN, 'TUN 状态',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeTun()));
  specs.push(new CheckSpec(CheckIds.CORE, '内核存活',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeCore()));
  specs.push(new CheckSpec(CheckIds.CLASH_API, 'Clash API 可达与版本',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeClashApi()));
  specs.push(new CheckSpec(CheckIds.DNS, 'DNS 解析',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeDns()));
  specs.push(new CheckSpec(CheckIds.EGRESS_IPV4, 'IPv4 出口连通 (generate_204)',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeIpv4Egress()));
  specs.push(new CheckSpec(CheckIds.IPV6, 'IPv6 可用性（IPv4-only 规格，恒为 skip）',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeIpv6()));
  specs.push(new CheckSpec(CheckIds.INTENT, '意图与真实状态一致性',
    (p: LinkHealthProbes): Promise<ProbeOutcome> => p.probeIntentConsistency()));
  return specs;
}

/** 单项超时包装：p 先落地就用其结果，超时/异常返回 fallback（绝不 reject） */
export function withOutcomeTimeout(p: Promise<ProbeOutcome>, timeoutMs: number, fallback: ProbeOutcome): Promise<ProbeOutcome> {
  return new Promise<ProbeOutcome>((resolve) => {
    let done = false;
    const finish = (v: ProbeOutcome): void => {
      if (!done) {
        done = true;
        resolve(v);
      }
    };
    const timer = setTimeout((): void => {
      finish(fallback);
    }, timeoutMs);
    p.then((v: ProbeOutcome): void => {
      clearTimeout(timer);
      finish(v);
    }).catch((e: Object): void => {
      clearTimeout(timer);
      finish(fallback);
    });
  });
}

/**
 * 链路自检执行器。
 * 依赖全部构造注入；时间源可注入（便于单测断言耗时）。
 */
export class LinkHealthChecker {
  private probes: LinkHealthProbes;
  private totalBudgetMs: number;
  private perCheckTimeoutMs: number;
  private nowFn: () => number;

  constructor(probes: LinkHealthProbes,
    totalBudgetMs: number = DEFAULT_TOTAL_BUDGET_MS,
    perCheckTimeoutMs: number = DEFAULT_PER_CHECK_TIMEOUT_MS,
    nowFn?: () => number) {
    this.probes = probes;
    this.totalBudgetMs = totalBudgetMs > 0 ? totalBudgetMs : DEFAULT_TOTAL_BUDGET_MS;
    this.perCheckTimeoutMs = perCheckTimeoutMs > 0 ? perCheckTimeoutMs : DEFAULT_PER_CHECK_TIMEOUT_MS;
    this.nowFn = nowFn === undefined ? (): number => Date.now() : nowFn;
  }

  /** 总耗时上限（ms） */
  budgetMs(): number {
    return this.totalBudgetMs;
  }

  /** 单项超时（ms） */
  perCheckMs(): number {
    return this.perCheckTimeoutMs;
  }

  /** 依次执行全部检查；单项失败/超时不影响其余项 */
  async run(): Promise<LinkHealthReport> {
    const report = new LinkHealthReport();
    report.startedAt = this.nowFn();
    const specs = buildCheckSpecs();
    for (const spec of specs) {
      const used = this.nowFn() - report.startedAt;
      if (used >= this.totalBudgetMs) {
        report.items.push(LinkHealthItem.skipped(spec.id, spec.label, '达到总耗时上限，跳过剩余检查'));
        report.truncated = true;
        continue;
      }
      const item = await this.runOne(spec);
      report.items.push(item);
    }
    report.totalMs = this.nowFn() - report.startedAt;
    return report;
  }

  /** 执行单项：同步异常 / 异步 reject / 超时 三种失败都被收敛成 fail 项 */
  private async runOne(spec: CheckSpec): Promise<LinkHealthItem> {
    const t0 = this.nowFn();
    let outcome: ProbeOutcome;
    try {
      const timeoutOutcome = ProbeOutcome.fail(
        '检查超时（' + this.perCheckTimeoutMs + 'ms 未返回）',
        '该项可能挂死，请检查网络或内核状态后重试',
        repairForCheck(spec.id));
      // callProbe 已把「同步抛错 / 异步 reject」收敛为 fail，这里只需再兜超时
      outcome = await withOutcomeTimeout(this.callProbe(spec), this.perCheckTimeoutMs, timeoutOutcome);
    } catch (e) {
      outcome = ProbeOutcome.fail('检查执行异常: ' + errText(e),
        '请重试；若持续失败请重启应用', repairForCheck(spec.id));
    }
    const elapsed = this.nowFn() - t0;
    return LinkHealthItem.make(spec.id, spec.label, outcome, elapsed);
  }

  /** 调用探针并把「同步抛错 / 异步 reject」统一转成 fail 结论（永不 reject） */
  private callProbe(spec: CheckSpec): Promise<ProbeOutcome> {
    return new Promise<ProbeOutcome>((resolve) => {
      try {
        spec.run(this.probes)
          .then((v: ProbeOutcome): void => {
            if (v === null || v === undefined) {
              resolve(ProbeOutcome.fail('探针返回空结果', '请重试', repairForCheck(spec.id)));
            } else {
              resolve(v);
            }
          })
          .catch((e: Object): void => {
            resolve(ProbeOutcome.fail('检查执行异常: ' + errText(e),
              '请重试；若持续失败请重启应用', repairForCheck(spec.id)));
          });
      } catch (e) {
        resolve(ProbeOutcome.fail('检查执行异常: ' + errText(e),
          '请重试；若持续失败请重启应用', repairForCheck(spec.id)));
      }
    });
  }
}

/** 便捷入口：跑一次自检（集成层常用） */
export async function runLinkHealthCheck(probes: LinkHealthProbes,
  totalBudgetMs: number = DEFAULT_TOTAL_BUDGET_MS,
  perCheckTimeoutMs: number = DEFAULT_PER_CHECK_TIMEOUT_MS): Promise<LinkHealthReport> {
  const checker = new LinkHealthChecker(probes, totalBudgetMs, perCheckTimeoutMs);
  return checker.run();
}

/** 便捷入口：一条龙「自检 + 汇总 + 修复动作」 */
export async function diagnose(probes: LinkHealthProbes): Promise<LinkHealthSummary> {
  const report = await runLinkHealthCheck(probes);
  return summarize(report);
}
