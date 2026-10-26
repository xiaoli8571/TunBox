// [harness] generated from entry/src/main/ets/commons/services/AppRoutingPolicy.ets — 仅 import 目标被重写
/** 应用分流的零 SDK 依赖策略：模式显式、保留两份草稿，运行只选择一份。 */
export class AppRoutingModes {
  static readonly ALL: string = 'all';
  static readonly INCLUDE: string = 'include';
  static readonly EXCLUDE: string = 'exclude';
}

/** 用户补充的应用目录项；label 仅用于显示，不能参与系统路由。 */
export class AppRoutingCustomApp {
  bundleName: string = '';
  label: string = '';
}

/** 手动输入解析后的一条应用：「名称|包名」可一次粘贴多行，label 只用于显示。 */
export class AppRoutingEntry {
  bundleName: string = '';
  label: string = '';

  constructor(bundleName: string, label: string) {
    this.bundleName = bundleName;
    this.label = label;
  }
}

/** 一次 VPN 会话的不可降级策略快照；默认状态不能启动。 */
export class AppRoutingRuntime {
  mode: string = '';
  needsReview: boolean = true;
  packages: string[] = [];
}

export class AppRoutingPolicy {
  static readonly MAX_PACKAGES: number = 256;
  static readonly MAX_BUNDLE_LENGTH: number = 127;

  /** 只做无损语义归一化；无效/空包名不丢弃，交给 validationError 显式报错。 */
  static normalizePackages(packages: string[]): string[] {
    const result: string[] = [];
    for (const value of packages) {
      const name = typeof value === 'string' ? value.trim() : '[无效包名] ' + JSON.stringify(value);
      if (result.indexOf(name) < 0) {
        result.push(name);
      }
    }
    return result;
  }

  /** 单个包名是否为合法的鸿蒙 BundleName（输入框即时高亮与保存校验同一口径）。 */
  static isBundleName(value: string): boolean {
    const name = value.trim();
    if (name.length < 3 || name.length > AppRoutingPolicy.MAX_BUNDLE_LENGTH) {
      return false;
    }
    return new RegExp('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$').test(name);
  }

  static packagesError(packages: string[], label: string): string {
    if (!Array.isArray(packages)) {
      return label + '格式无效，请重新确认应用名单';
    }
    const normalized = AppRoutingPolicy.normalizePackages(packages);
    if (normalized.length > AppRoutingPolicy.MAX_PACKAGES) {
      return label + '最多支持 256 个应用，请减少名单后保存（不会自动截断）';
    }
    for (const name of normalized) {
      if (!AppRoutingPolicy.isBundleName(name)) {
        return label + '含无效包名：' + (name.length === 0 ? '（空包名）' : name) +
          '。包名须为 3–127 位字母、数字、下划线及点，禁止逗号和空白';
      }
    }
    return '';
  }

  /** 行内分隔符：半角竖线、全角竖线、制表符。取最靠前的一个，名称里带空格/点号都不受影响。 */
  private static separatorIndex(line: string): number {
    const marks: string[] = ['|', '｜', '	'];
    let found: number = -1;
    for (const mark of marks) {
      const at = line.indexOf(mark);
      if (at > 0 && (found < 0 || at < found)) {
        found = at;
      }
    }
    return found;
  }

  /** 解析手动输入（每行一条），支持：
   *    支付宝|com.alipay.mobile.client   —— 名称在前（推荐）
   *    com.alipay.mobile.client|支付宝   —— 包名在前也能识别
   *    com.alipay.mobile.client          —— 只填包名
   *  两侧都不是合法包名时整行原样当成包名，交给 packagesError 明确报错，绝不静默丢弃。 */
  static parseEntries(text: string, fallbackLabel: string): AppRoutingEntry[] {
    const result: AppRoutingEntry[] = [];
    const lines: string[] = text.split(String.fromCharCode(10));
    const onlyOne: boolean = lines.filter((line: string) => line.trim().length > 0).length === 1;
    for (const raw of lines) {
      const line: string = raw.trim();
      if (line.length === 0) {
        continue;
      }
      const at: number = AppRoutingPolicy.separatorIndex(line);
      let name: string = line;
      let label: string = '';
      if (at > 0) {
        const left: string = line.substring(0, at).trim();
        const right: string = line.substring(at + 1).trim();
        if (AppRoutingPolicy.isBundleName(right)) {
          name = right;
          label = left;
        } else if (AppRoutingPolicy.isBundleName(left)) {
          name = left;
          label = right;
        }
      }
      // 名称备注输入框只对「单条输入」补默认值；多行时以每行自带的名称优先。
      if (label.length === 0 && onlyOne) {
        label = fallbackLabel.trim();
      }
      result.push(new AppRoutingEntry(name, label));
    }
    return result;
  }

  /** 输入框即时预检：全部行都能解析成合法包名才允许提交。 */
  static entriesError(entries: AppRoutingEntry[]): string {
    if (entries.length === 0) {
      return '请至少输入一个包名';
    }
    for (const entry of entries) {
      if (!AppRoutingPolicy.isBundleName(entry.bundleName)) {
        return '不是有效包名：' + entry.bundleName + '（可写成 名称|包名）';
      }
    }
    return '';
  }

  /** UI 保存确认时可传 false 预检；只有保存成功的确认操作才能清除持久化 needsReview。 */
  static validationError(mode: string, included: string[], excluded: string[], needsReview: boolean): string {
    if (mode !== AppRoutingModes.ALL && mode !== AppRoutingModes.INCLUDE && mode !== AppRoutingModes.EXCLUDE) {
      return '应用分流模式未知，请打开应用分流页面重新选择并保存';
    }
    if (needsReview !== false) {
      return '应用分流设置需要确认，请选择模式并保存后再连接';
    }
    const includeError = AppRoutingPolicy.packagesError(included, '仅代理名单');
    if (includeError.length > 0) {
      return includeError;
    }
    const excludeError = AppRoutingPolicy.packagesError(excluded, '绕过名单');
    if (excludeError.length > 0) {
      return excludeError;
    }
    if (mode === AppRoutingModes.INCLUDE && AppRoutingPolicy.normalizePackages(included).length === 0) {
      return '仅代理所选应用模式至少需要选择一个应用';
    }
    return '';
  }

  /** 旧版两份名单不能再用差集猜测意图；冲突交给调用方设置 needsReview。 */
  static legacyMode(included: string[], excluded: string[]): string {
    if (included.length > 0) {
      return AppRoutingModes.INCLUDE;
    }
    return excluded.length > 0 ? AppRoutingModes.EXCLUDE : AppRoutingModes.ALL;
  }

  static runtime(mode: string, included: string[], excluded: string[], needsReview: boolean): AppRoutingRuntime {
    const error = AppRoutingPolicy.validationError(mode, included, excluded, needsReview);
    if (error.length > 0) {
      throw new Error(error);
    }
    const result = new AppRoutingRuntime();
    result.mode = mode;
    result.needsReview = false;
    if (mode === AppRoutingModes.INCLUDE) {
      result.packages = AppRoutingPolicy.normalizePackages(included);
    } else if (mode === AppRoutingModes.EXCLUDE) {
      result.packages = AppRoutingPolicy.normalizePackages(excluded);
    }
    return result;
  }

  /** Want 使用 JSON 单名单，禁止 CSV 分割把一个非法包名变成多个合法应用。 */
  static fromTransport(mode: string, packagesJson: string, needsReview: boolean): AppRoutingRuntime {
    if (typeof packagesJson !== 'string' || packagesJson.length === 0) {
      throw new Error('应用分流参数缺失，已拒绝恢复 VPN，请在应用内重新连接');
    }
    let packages: string[];
    try {
      packages = JSON.parse(packagesJson) as string[];
    } catch (e) {
      throw new Error('应用分流名单参数损坏，已拒绝启动 VPN');
    }
    if (!Array.isArray(packages)) {
      throw new Error('应用分流名单参数格式无效，已拒绝启动 VPN');
    }
    if (mode === AppRoutingModes.ALL && packages.length > 0) {
      throw new Error('全部应用模式携带了冲突名单，已拒绝启动 VPN');
    }
    return AppRoutingPolicy.runtime(mode,
      mode === AppRoutingModes.INCLUDE ? packages : [],
      mode === AppRoutingModes.EXCLUDE ? packages : [], needsReview);
  }

  /** 重建或内核恢复前重验同一会话快照，绝不根据缓存 YAML 推测为 all。 */
  static runtimeError(runtime: AppRoutingRuntime): string {
    if (runtime.mode === AppRoutingModes.ALL && runtime.packages.length > 0) {
      return '全部应用模式携带了冲突名单，已拒绝恢复 VPN';
    }
    return AppRoutingPolicy.validationError(runtime.mode,
      runtime.mode === AppRoutingModes.INCLUDE ? runtime.packages : [],
      runtime.mode === AppRoutingModes.EXCLUDE ? runtime.packages : [], runtime.needsReview);
  }
}
