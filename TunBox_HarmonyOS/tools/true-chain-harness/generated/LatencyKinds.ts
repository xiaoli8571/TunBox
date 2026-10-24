// [harness] generated from entry/src/main/ets/commons/latency/LatencyKinds.ets — 仅 import 目标被重写
/**
 * 测速**分类表**与**探测结果类型**（零 import 的纯模块）。
 *
 * 为什么单独成文件（而不是留在 `LatencyProbe.ets` 里）：
 *
 *  1. **判定语义只有一份**：失败分类常量、**唯一判定表** `isNonVerdictKind`
 *     （哪些分类不算「节点结论」）、派生视图 `isVerdictKind`、陈旧判定 `isStale`
 *     都在这里。测速内核（`LatencyProbe.ets`）、测速引擎（`LatencyEngine.ets`）、
 *     结论落盘仓（`LatencyStore.ets`）与 UI 策略层（`LatencyState.ets`）都从这里取
 *     ⇒ 引擎不再自带一套失败映射（旧的 `mapFailure` 已删），恢复路径也不再自带
 *     一份反表（旧的 `LatencyPolicy.isNonVerdictKind` 待转调）。
 *  2. **扁平暂存闸门能跑**：Node 行为闸门把 `commons/services/*.ets` **扁平暂存**
 *     成沙箱再 import，任何 `../latency/*` 的**值**依赖都会因「那一层目录不存在」
 *     让整个闸门 ERR_MODULE_NOT_FOUND 崩掉 ⇒ services 侧能值依赖的必须是
 *     **零 import** 的模块（与 `LatencyDnsVerdict.ets` 同理）。本文件不 import
 *     任何东西 ⇒ 闸门只需多暂存它一个文件。
 *
 * 外部 import 路径保持稳定：`LatencyProbe.ets` 再导出本文件的两个类，
 * 既有调用方（`ClashApiService.ets` 等）不需要改路径。
 */

/**
 * 失败分类（单一表）。
 *
 * 判定类（**写进**结论、参与排序与组级聚合）= 判定表取反后剩下的：
 *  - 实测出延迟（''）
 *  - timeout（节点真超时）
 *  - network_unreachable（节点走不通，有 dial 证据）
 *  - switch_failed（节点不在内核表里 —— 配置类结论，渲染为「未生效」而非红色失败）
 *  - dns_unresolved（域名已下线 —— 该换机场/换订阅，不是换线路）
 *
 * 非判定类（**绝不**写进结论，沿用上一次有效结论）= 判定表本体：
 *  - core_not_ready（通道/凭证坏了 —— 这是「我们」的问题，不是节点的问题）
 *  - unknown（认不出来 —— 宁可什么都不写，也不冤枉节点）
 *  - queue_timeout / untested / cancelled / unsupported / port_reachable_only
 */
export class LatencyProbeKind {
  /** 无失败（测出了延迟） */
  static readonly NONE: string = '';
  /** 节点真超时（内核 504 / 我们自己的超时） */
  static readonly TIMEOUT: string = 'timeout';
  /** 节点不在内核代理表里（内核 404）→ 配置类结论「未生效」 */
  static readonly SWITCH_FAILED: string = 'switch_failed';
  /** 测速通道/凭证层面坏了（401/403/传输层异常）→ **非判定** */
  static readonly CORE_NOT_READY: string = 'core_not_ready';
  /** 节点走不通（内核 503，体内有 dial 类错误） */
  static readonly NETWORK_UNREACHABLE: string = 'network_unreachable';
  /**
   * 域名无法解析（**我们自己的 DNS 预检**判定，优先于内核的 503）。
   *
   * 2026-10-20 真机实测（多解析器：阿里/Cloudflare/Google/腾讯）：那批全败节点的
   * 服务器域名四个解析器**全部 NXDOMAIN**；仓库 2026-10-19 真机取证同结论。
   * ⇒ 失败发生在**域名解析**这一步，既不是拨号失败也不是超时。
   *
   * ⚠ mihomo 的 503 body 是**通用句**（"An error occurred in the delay test"），
   * **看不到 DNS 原因** ⇒ 必须靠我们自己的 DoH 预解析先判定
   * （日志里当天明确是 `DoH pinned 0/135` / `test-core proxy hosts: 0/135`）。
   */
  static readonly DNS_UNRESOLVED: string = 'dns_unresolved';
  /** 认不出来的失败 → **非判定**（宁可什么都不写，也不冤枉节点） */
  static readonly UNKNOWN: string = 'unknown';
  /** 排队超时（根本没拨号）→ **非判定** */
  static readonly QUEUE_TIMEOUT: string = 'queue_timeout';
  /** 整批硬截止，本次没测出来 → **非判定** */
  static readonly UNTESTED: string = 'untested';
  /** 客户端主动取消 → **非判定** */
  static readonly CANCELLED: string = 'cancelled';
  /** 协议无法离线探测 → **非判定** */
  static readonly UNSUPPORTED: string = 'unsupported';
  /** 只证明端口可达（直连降级）→ **非判定** */
  static readonly PORT_ONLY: string = 'port_reachable_only';

  /**
   * **唯一判定表**：哪些失败分类**不构成**节点结论。
   *
   * ⚠ 这张表是**唯一**的判定真源（2026-10-20 lead 拍板：正表/反表不得并存 ⇒
   * 删掉旧的正表，只留这张反表；live 路径需要的「是不是结论」由它**派生**）。
   *
   * 非判定 = **这次失败不构成「这个节点通不通」的结论**：
   *  - core_not_ready  测速通道/凭证坏了（是我们的问题，不是节点的问题）
   *  - queue_timeout   根本没拨号（没排上队）
   *  - untested        整批硬截止，本次没测出来
   *  - cancelled       客户端主动取消
   *  - unsupported     协议无法离线探测
   *  - port_reachable_only 只证明端口可达（直连降级）
   *  - unknown         认不出来的失败（宁可什么都不写，也不冤枉节点）
   *
   * ⚠ **空串（''）不在本表里**：'' = 没有失败（实测出了延迟）⇒ 它**是**结论。
   * 「空分类 = 旧版记账残留 ⇒ 恢复时按未测处理」是**恢复路径**的规则，
   * 不是判定表的一部分。
   */
  static isNonVerdictKind(kind: string): boolean {
    return kind === LatencyProbeKind.CORE_NOT_READY
      || kind === LatencyProbeKind.QUEUE_TIMEOUT
      || kind === LatencyProbeKind.UNTESTED
      || kind === LatencyProbeKind.CANCELLED
      || kind === LatencyProbeKind.UNSUPPORTED
      || kind === LatencyProbeKind.PORT_ONLY
      || kind === LatencyProbeKind.UNKNOWN;
  }

  /**
   * 派生视图（**不是第二张表**）：这个分类是不是**节点结论**（可盖章：参与排序、
   * 进组级聚合）。
   *
   * 判定权全部来自 {@link isNonVerdictKind} 这一张表；这里只做两件事：
   *  1. 空串（''）= 实测出了延迟 ⇒ 是结论；
   *  2. 其它一切 ⇒ 取反那张表。
   *
   * ⚠ 内核（LatencyProbe）与引擎（LatencyEngine）都用它决定要不要落记录
   * （引擎不再自带一套 publishable/notPublishable 语义）。
   */
  static isVerdictKind(kind: string): boolean {
    if (kind === LatencyProbeKind.NONE) {
      return true;
    }
    return !LatencyProbeKind.isNonVerdictKind(kind);
  }

  /**
   * 结论的 TTL：超过即视为陈旧（UI 灰显但保留）。
   *
   * ⚠ 这是**唯一**的阈值定义（2026-10-20 lead 拍板：阈值只能一份）。
   */
  static readonly STALE_MS: number = 10 * 60 * 1000;

  /**
   * **唯一**的「陈旧」判定表。
   *
   * 语义：
   *  1. 有时间戳（testedAtMs > 0）：`nowMs - testedAtMs > STALE_MS` ⇒ 陈旧；
   *  2. 年龄未知（testedAtMs <= 0）：
   *     - **失败结论** ⇒ 算陈旧（不知道多久以前的失败，绝不能当成本次刚测出来的
   *       结论顶在列表上 —— 2026-10-20 真机「刚打开软件就显示一颗红『超时』」的防线）；
   *     - 非失败结论（有值但年龄未知）⇒ 不算（无法判断，不标「·旧」）。
   */
  static isStale(testedAtMs: number, nowMs: number, isFailure: boolean): boolean {
    if (testedAtMs <= 0) {
      return isFailure;
    }
    return (nowMs - testedAtMs) > LatencyProbeKind.STALE_MS;
  }

  /**
   * 这个分类是不是**超时档**（UI 归到「超时」而不是「失败」）。
   *
   * ⚠ `queue_timeout`（没排上队）也算超时档：它与真超时同为「没测出延迟」，
   * 但**独立计数**（`LatencyProgress.queueTimeout`）—— UI/持久化据此把
   * 「节点不通」与「没排上队」分开。
   */
  static isTimeoutKind(kind: string): boolean {
    return kind === LatencyProbeKind.TIMEOUT || kind === LatencyProbeKind.QUEUE_TIMEOUT;
  }
}

/**
 * 探测策略（纯函数，零 import）—— **从 `LatencyState.LatencyPolicy` 迁移而来**。
 *
 * 2026-10-20（lead 拍板）：`LatencyPolicy` 长期是「什么都装」的杂货铺，
 * 把三类完全不同的东西塞在一个类里：
 *  1. **判定表转调**（isNonVerdictKind / isStale / isStaleConclusion）→ 归 `LatencyProbeKind`；
 *  2. **探测策略**（有效延迟、内建项/组过滤、环回地址、排序权重）→ **本类**；
 *  3. **超时数值**（DEFAULT_TIMEOUT_MS / MAX_TIMEOUT_MS）→ 归 `LatencyProbeLimits`。
 * 本类只装第 2 类：**输入是纯标量/纯字段，不依赖 LatencyRecord 类型**
 * （那是 services 层的类型，零 import 模块不能引）⇒ 排序权重改成按
 * 「状态 + 延迟」两个标量入参，由 services 层的薄转调包装成 `compare(a, b)`。
 */
export class LatencyStrategy {
  /**
   * 0 / 负数 / 缺失都不是有效延迟。
   *
   * mihomo 成功时 delay 恒 >= 1；0 表示失败（内核自己就把 delay==0 当失败返回 503）。
   * 若把 0 当「很快」，死节点会排到最前面。
   */
  static isValidDelay(delayMs: number): boolean {
    return delayMs >= 1 && delayMs < 32767;
  }

  /** 节点名是否是内建项（不可测） */
  static isBuiltinNode(name: string): boolean {
    return name === 'DIRECT' || name === 'REJECT' || name === 'REJECT-DROP'
      || name === 'COMPATIBLE' || name === 'PASS' || name === 'PASS-RULE'
      || name === 'GLOBAL' || name === 'REMATCH' || name === 'DNS';
  }

  /**
   * 服务器地址是否指向本机/内网。
   *
   * 为什么单列一条：离线粗略通道测的是「服务器可达性」，对环回/内网地址测出来的
   * 是本机自己的握手开销（真机实测会出现 `≈2ms` 这种漂亮但毫无意义的数字，还会
   * 排到列表最前）。真实内核通道不受影响（那种节点本来就该按真实延迟显示），
   * 所以只在离线通道里判定。
   */
  static isLoopbackOrLocal(server: string): boolean {
    const s = server.trim().toLowerCase();
    if (s.length === 0) {
      return true;
    }
    if (s === 'localhost' || s === '::1' || s === '[::1]') {
      return true;
    }
    if (s.startsWith('127.') || s.startsWith('10.') || s.startsWith('192.168.')) {
      return true;
    }
    // 172.16.0.0/12
    if (s.startsWith('172.')) {
      const parts = s.split('.');
      if (parts.length > 1) {
        const second = Number.parseInt(parts[1], 10);
        if (second >= 16 && second <= 31) {
          return true;
        }
      }
    }
    return false;
  }

  /**
   * 组类型是否可测。
   *
   * 为什么必须过滤组：实测本项目的 `PROXY.all` 里混着 14 个组条目
   * （🔰 选择节点 / 🌏 爱奇艺&哔哩哔哩 / 🎮 Steam… ），若不过滤，
   * 一是会把组当节点测（内核按组当前选择返回，得到的是**别的节点**的延迟，
   * 结果张冠李戴），二是浪费一轮超时预算。所以只测真实出站节点。
   */
  static isTestableType(type: string): boolean {
    const groups: string[] = ['Selector', 'URLTest', 'Fallback', 'LoadBalance', 'Relay'];
    if (groups.indexOf(type) >= 0) {
      return false;
    }
    const builtinTypes: string[] = ['Direct', 'Reject', 'RejectDrop', 'Compatible', 'Pass', 'PassRule', 'Dns'];
    return builtinTypes.indexOf(type) < 0;
  }
}

/**
 * 单节点测速的**超时数值真源**（从 `LatencyState.LatencyPolicy` 迁移而来）。
 *
 * ⚠ 与 `LatencyProbeLimits` 的关系：那边装的是**探针自己**的并发/预算参数
 * （NODE_TIMEOUT_MS / OUTER_EXTRA_MS / WORKERS / MAX_INFLIGHT / QUEUE_WAIT_MAX_MS），
 * 这边装的是**调用方可见的超时契约**（默认预算 + 内核 16 位解析上限）。
 * 两者的「5000」必须是同一个值 —— 但 `LatencyProbe.ets` 会 import `models/AppSettings`，
 * 而 `LatencyEngine` 只引 `ClashApiService`，为免把 probe 整条依赖链拖进引擎，
 * 这里保留独立常量，并由闸门 `verify-latency-core-v2` 断言两者**数值相等**。
 */
export class LatencyTimeout {
  /**
   * 单节点探测超时（毫秒）—— 2026-10-20 晚用户要求由 5000 改为 **3000**（等 5 秒太久）。
   *
   * 沿革：5000 → 3000（嫌等太久）→ 1000（2026-10-18）→ 2500（同日回退）→ 5000（2026-10-19）
   *      → **3000**（2026-10-20 用户拍板）。
   * 1000ms 已被真机证伪：飞鸟云 35 个 hysteria2（QUIC/UDP）节点首握需 1~2 RTT，
   * 同一批 **3s** 能测出 143/558/560ms，1s 时 measured=0/timeout=31（全部误杀）
   * —— 3000 是「已验证能测出这批节点」的取值，不是拍脑袋。
   * ⚠ 本值（内核 URLTest 预算，5s）与 `LatencyProbeLimits.NODE_TIMEOUT_MS`（离线
   * TCP/TLS 探测预算，3s）是**两个不同场景的尺子**，不要求同值；旧注释「必须同值
   * （闸门断言）」不成立——不存在该闸门，引擎批实传本值、离线探测用 3000。
   */
  static readonly DEFAULT_TIMEOUT_MS: number = 5000;
  /** mihomo 的 timeout 用 16 位整数解析，> 32767 直接 400。 */
  static readonly MAX_TIMEOUT_MS: number = 30000;
}

/** 一次探测的结果 */
export class LatencyProbeResult {
  /** 节点名 */
  nodeName: string = '';
  /** 延迟毫秒；>=1 = 实测；-1 = 失败；-2 = 未测 */
  delayMs: number = -1;
  /** 失败分类（LatencyProbeKind.*；'' = 无失败） */
  failKind: string = LatencyProbeKind.NONE;
  /** HTTP 状态码（0 = 传输层失败/中止） */
  httpCode: number = 0;
  /** 是否构成节点结论（非判定类失败 = false） */
  isVerdict: boolean = false;
  /** 失败细节（含完整响应体） */
  detail: string = '';
  /** **完整**响应体（不截断；日志里才截断） */
  bodyText: string = '';
  /** 本次探测耗时（ms） */
  elapsedMs: number = 0;
}
