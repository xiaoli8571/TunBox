/**
 * 不可用节点台账（Unusable Ledger）
 *
 * ## 为什么是「旁挂表」而不是 ProxyNode 字段
 *
 * 不可用节点**不进内核代理表、不进测速集合**，所以它根本不会出现在
 * `SubscriptionService.nodes` 里；而 ProxyNode 又是要落盘持久化的数据模型，
 * 给它加"不可用"字段等于把一次性判定写进持久化结构（重启后还得重新判定，
 * 还会让老数据迁移变复杂）。所以用**旁挂表**：导入期写、UI 读取、导入结束即清。
 *
 * ## 台账里放什么
 *
 * 两条导入路径（分享链接 / Clash YAML）都往这张表写，口径统一：
 *
 * | category | 含义 | 是否进代理表/测速集合 |
 * |---|---|---|
 * | `incomplete` | **定义不完整**（缺必填参数 —— 解析层丢参数，我们的问题） | **否**（整条排除，绝不半条） |
 * | `dns` | **域名无法解析**（定义完整，但域名查不到 —— 机场/线路的问题） | 是（定义没问题，是线路死了） |
 *
 * ## 凭据安全
 *
 * 台账**不存原始 URI**：分享链接里带 uuid/password，落盘或进日志就是凭据泄露。
 * 只留：来源、协议、显示名、服务器地址、端口、分类、原因文案、缺失键清单。
 */
import { DnsState, UnusableCategory } from './NodeUsability';

/** 台账里的一条记录 */
export class UnusableRecord {
  /** 所属订阅 id（直连导入为 'direct' 之类） */
  subscriptionId: string = '';
  /** 来源：'uri'（分享链接）/ 'yaml'（Clash YAML） */
  source: string = '';
  /** 协议 */
  protocol: string = '';
  /** 显示名 */
  name: string = '';
  /** 服务器地址（域名或 IP） */
  server: string = '';
  /** 端口 */
  port: number = 0;
  /** 分类（UnusableCategory） */
  category: string = '';
  /** 是否已被排除出代理表/测速集合 */
  excluded: boolean = false;
  /** 一句话原因（中文，UI 直接展示） */
  reason: string = '';
  /** 补充说明（中文，UI 直接展示） */
  detail: string = '';
  /** 缺失的必填键（仅 incomplete 有值） */
  missing: string[] = [];
  /** DNS 状态（仅 dns 类有值） */
  dnsState: string = DnsState.UNKNOWN;
}

/** 旁挂台账（进程内静态，导入期写、读取后即清） */
export class UnusableLedger {
  private static records: UnusableRecord[] = [];

  /** 写一条 */
  static record(item: UnusableRecord): void {
    UnusableLedger.records.push(item);
  }

  /** 读一份快照（不清空） */
  static list(): UnusableRecord[] {
    return UnusableLedger.records.slice();
  }

  /** 取走并清空 */
  static drain(): UnusableRecord[] {
    const out = UnusableLedger.records.slice();
    UnusableLedger.records = [];
    return out;
  }

  /** 清空 */
  static clear(): void {
    UnusableLedger.records = [];
  }

  /**
   * 清掉某个订阅的旧记录（该订阅重新导入前调用）。
   *
   * 为什么不清全局：并发刷新时全局清会把别的订阅刚写的记录抹掉；
   * 为什么不清空整个表：表是进程级静态，没人读的时候它就该是空的。
   */
  static clearFor(subscriptionId: string): void {
    const kept: UnusableRecord[] = [];
    for (const item of UnusableLedger.records) {
      if (item.subscriptionId !== subscriptionId) {
        kept.push(item);
      }
    }
    UnusableLedger.records = kept;
  }

  /** 某个订阅的记录 */
  static listFor(subscriptionId: string): UnusableRecord[] {
    const out: UnusableRecord[] = [];
    for (const item of UnusableLedger.records) {
      if (item.subscriptionId === subscriptionId) {
        out.push(item);
      }
    }
    return out;
  }

  /** 记录条数 */
  static size(): number {
    return UnusableLedger.records.length;
  }

  /** 只看被排除的（定义不完整） */
  static excludedList(): UnusableRecord[] {
    const out: UnusableRecord[] = [];
    for (const item of UnusableLedger.records) {
      if (item.excluded) {
        out.push(item);
      }
    }
    return out;
  }

  /** 只看 DNS 类的（定义完整但域名查不到） */
  static dnsList(): UnusableRecord[] {
    const out: UnusableRecord[] = [];
    for (const item of UnusableLedger.records) {
      if (item.category === UnusableCategory.DNS) {
        out.push(item);
      }
    }
    return out;
  }

  /**
   * 汇总文案（给 UI 顶部提示用）。
   *
   * 两类原因必须分开说：混成一句「失败」用户就不知道该找谁。
   */
  static summary(): string {
    let incomplete = 0;
    let dns = 0;
    let other = 0;
    for (const item of UnusableLedger.records) {
      if (item.category === UnusableCategory.INCOMPLETE) {
        incomplete = incomplete + 1;
      } else if (item.category === UnusableCategory.DNS) {
        dns = dns + 1;
      } else {
        other = other + 1;
      }
    }
    if (incomplete === 0 && dns === 0) {
      return '';
    }
    const parts: string[] = [];
    if (incomplete > 0) {
      parts.push(`${incomplete} 条定义不完整（参数缺失，已跳过，不参与测速）`);
    }
    if (dns > 0) {
      parts.push(`${dns} 条域名无法解析（参数没问题，是机场线路/入口域名的问题，请找机场换线路或换订阅）`);
    }
    if (other > 0) {
      parts.push(`${other} 条其它原因不可用`);
    }
    return parts.join('；');
  }
}
