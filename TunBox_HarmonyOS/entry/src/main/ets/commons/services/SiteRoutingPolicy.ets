/** 网站分流编辑策略：域名格式与配置生成器保持一致；不默默丢弃坏条目。 */
export class SiteRoutingPolicy {
  static readonly MAX_SITES: number = 500;

  static normalize(value: string): string {
    let domain = value.trim().toLowerCase();
    while (domain.endsWith('.')) { domain = domain.substring(0, domain.length - 1); }
    return domain;
  }

  static domainError(value: string): string {
    const domain = SiteRoutingPolicy.normalize(value);
    if (domain.length === 0 || domain.length > 253) { return '域名长度须为 1–253 个字符'; }
    const labels = domain.split('.');
    for (const label of labels) {
      if (label.length === 0 || label.length > 63 || label.startsWith('-') || label.endsWith('-')
        || !new RegExp('^[a-z0-9-]+$').test(label)) {
        return '请输入纯域名，不含协议、路径、端口或通配符；中文域名请使用 Punycode';
      }
    }
    if (new RegExp('^[0-9.]+$').test(domain)) { return '请输入网站域名，不是 IP 地址'; }
    return '';
  }

  static normalizeList(values: string[]): string[] {
    const result: string[] = [];
    for (const value of values) {
      const domain = SiteRoutingPolicy.normalize(value);
      if (!result.includes(domain)) { result.push(domain); }
    }
    return result;
  }

  static parseInput(text: string): string[] {
    return SiteRoutingPolicy.normalizeList(text.split(new RegExp('\\r?\\n')).filter((line: string) => line.trim().length > 0));
  }

  static validationError(proxy: string[], direct: string[], block: string[] = []): string {
    const proxyList = SiteRoutingPolicy.normalizeList(proxy);
    const directList = SiteRoutingPolicy.normalizeList(direct);
    const blockList = SiteRoutingPolicy.normalizeList(block);
    for (const list of [proxyList, directList, blockList]) {
      if (list.length > SiteRoutingPolicy.MAX_SITES) { return '每份网站名单最多 500 项，请减少后保存；不会自动截断'; }
      for (const domain of list) {
        const error = SiteRoutingPolicy.domainError(domain);
        if (error.length > 0) { return `${domain || '（空域名）'}：${error}`; }
      }
    }
    // 拦截名单优先级最高：同时出现在拦截与 DIRECT/PROXY 时，DNS 层拒绝先生效，
    // 与另一份名单的意图冲突 —— 与两份名单互斥同一套校验语义，保存前拒绝。
    const blockOverlap = blockList.find((domain: string) =>
      proxyList.includes(domain) || directList.includes(domain));
    if (blockOverlap !== undefined) {
      return `${blockOverlap} 同时位于拦截名单与代理/直连名单，请移除一侧后保存`;
    }
    const overlap = proxyList.find((domain: string) => directList.includes(domain));
    return overlap === undefined ? '' : `${overlap} 同时位于两份名单，请移除一侧后保存`;
  }
}
