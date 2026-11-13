/*
 * RawProxyYaml —— Clash 订阅原文的 proxies 透传（2026-10-21）
 *
 * 目的：让节点定义**原样**进入运行配置，不再经 App 的 ProxyNode 模型重发射。
 * 三家参照客户端（FlClash / Verge Rev / CMFA）都是「原文交给内核解析」，
 * App 侧只拿节点名做 UI 与测速。这里用最小代价对齐：
 *   - 不改内核交互方式（仍是静态 proxies，`/proxies/{name}/delay` 照常可用）；
 *   - 不落盘明文凭据（原文只在内存里，进程内有效）；
 *   - 任何一步对不上（条数、名字、格式）都自动退回原来的解析发射，不会让配置变坏。
 *
 * 为什么是「文本切片」而不是再解析一遍：
 * 解析再序列化必然丢字段（anytls 类新协议、插件参数、未识别键），这正是本仓库
 * 反复踩的坑。切片保留每个节点条目的原始文本，内核拿到的就是机场写的那份。
 */

/** 一个原始节点条目：kv 为「当前名字」，text 为原文片段（含缩进） */
export class RawProxyItem {
  name: string = '';
  text: string = '';
}

export class RawProxyYaml {
  /**
   * 从订阅原文里切出 `proxies:` 列表的每个条目（保留原文与缩进）。
   * 只认顶层 `proxies:`；`proxy-providers:` / `proxy-groups:` 里的同名键不受影响。
   */
  static extractProxies(body: string): RawProxyItem[] {
    const items: RawProxyItem[] = [];
    if (body.length === 0) {
      return items;
    }
    const lines: string[] = body.split('\n');
    let i = 0;
    // 1) 找到顶层 proxies: 行
    let inside = false;
    let indentOfDash = -1;
    let cur: string[] = [];
    for (; i < lines.length; i++) {
      const raw = lines[i];
      const line = raw.replace(/\r$/, '');
      if (!inside) {
        if (/^proxies\s*:/.test(line)) {
          const rest = line.substring(line.indexOf(':') + 1).trim();
          if (rest === '[]' || rest.length > 0) {
            // 行内写法（proxies: [] 或 proxies: [{...}]）不切片，交给解析链
            return items;
          }
          inside = true;
        }
        continue;
      }
      // 2) 顶层新键 → proxies 段结束
      if (/^[A-Za-z0-9_-]+\s*:/.test(line)) {
        break;
      }
      const dash = line.match(/^(\s*)-\s/);
      if (dash !== null) {
        if (indentOfDash < 0) {
          indentOfDash = dash[1].length;
        }
        if (dash[1].length === indentOfDash) {
          if (cur.length > 0) {
            const item = RawProxyYaml.makeItem(cur);
            if (item !== null) {
              items.push(item);
            }
          }
          cur = [line];
          continue;
        }
      }
      if (cur.length > 0) {
        cur.push(line);
      }
    }
    if (cur.length > 0) {
      const item = RawProxyYaml.makeItem(cur);
      if (item !== null) {
        items.push(item);
      }
    }
    return items;
  }

  private static makeItem(lines: string[]): RawProxyItem | null {
    const text = lines.join('\n');
    const name = RawProxyYaml.readName(text);
    if (name.length === 0) {
      return null;
    }
    const item = new RawProxyItem();
    item.name = name;
    item.text = text;
    return item;
  }

  /**
   * 读条目里的 name。两种写法都要认：
   *   - name: 香港01          （块式）
   *   - {name: 香港01, ...}   （流式，机场最爱用）
   */
  static readName(itemText: string): string {
    const first = itemText.split('\n')[0];
    const flow = first.match(/^\s*-\s*\{\s*name\s*:\s*([^,}]*)/);
    if (flow !== null) {
      return RawProxyYaml.unquote(flow[1].trim());
    }
    const block = itemText.match(/^\s*-?\s*name\s*:\s*(.*)$/m);
    if (block === null) {
      return '';
    }
    return RawProxyYaml.unquote(block[1].trim());
  }

  /** 只替换 name 字段，其他字段一个字节都不动（块式/流式都支持） */
  static renameItem(itemText: string, newName: string): string {
    const lines: string[] = itemText.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (i === 0) {
        // 流式：- {name: X, server: ...}
        const flow = lines[i].match(/^(\s*-\s*\{\s*)name\s*:\s*[^,}]*(.*)$/);
        if (flow !== null) {
          lines[i] = `${flow[1]}name: ${RawProxyYaml.quote(newName)}${flow[2]}`;
          break;
        }
      }
      const m = lines[i].match(/^(\s*-?\s*)name\s*:\s*(.*)$/);
      if (m !== null) {
        lines[i] = `${m[1]}name: ${RawProxyYaml.quote(newName)}`;
        break;
      }
    }
    return lines.join('\n');
  }

  /**
   * 把条目的基准缩进归一到 target（默认 2 空格）。
   * 必需：各机场原文的缩进不统一（吹雪云 4 空格、NexPanel 2 空格），
   * 混进同一个 `proxies:` 列表就是非法 YAML —— 真机上表现为内核读配置即 stop
   * （`yaml: line N: did not find expected '-' indicator`）。
   */
  static reindent(itemText: string, target: number = 2): string {
    const lines: string[] = itemText.split('\n');
    let cur = -1;
    for (const line of lines) {
      const m = line.match(/^(\s*)-/);
      if (m !== null) {
        cur = m[1].length;
        break;
      }
    }
    if (cur < 0 || cur === target) {
      return itemText;
    }
    const delta = target - cur;
    const out: string[] = [];
    for (const line of lines) {
      if (line.length === 0) {
        out.push(line);
        continue;
      }
      if (delta > 0) {
        out.push(' '.repeat(delta) + line);
      } else {
        let strip = -delta;
        let i = 0;
        while (i < strip && i < line.length && line.charAt(i) === ' ') {
          i++;
        }
        out.push(line.substring(i));
      }
    }
    return out.join('\n');
  }

  private static unquote(s: string): string {
    if (s.length >= 2) {
      const a = s.charAt(0);
      const b = s.charAt(s.length - 1);
      if ((a === '"' && b === '"') || (a === '\'' && b === '\'')) {
        return s.substring(1, s.length - 1);
      }
    }
    return s;
  }

  private static quote(s: string): string {
    if (/^[A-Za-z0-9_.\-]+$/.test(s)) {
      return s;
    }
    return `"${s.replace(/"/g, '\\"')}"`;
  }
}

/**
 * 订阅原文缓存（进程内）。刷新拿到 body 时写入，生成配置时读取。
 * 只在内存：不落盘 → 不新增明文凭据面；冷启动后未刷新过则自动退回解析链。
 */
export class RawBodyCache {
  private static bodies: Map<string, string> = new Map<string, string>();

  static put(subscriptionId: string, body: string): void {
    if (subscriptionId.length === 0 || body.length === 0) {
      return;
    }
    RawBodyCache.bodies.set(subscriptionId, body);
  }

  static get(subscriptionId: string): string {
    const b = RawBodyCache.bodies.get(subscriptionId);
    return b === undefined ? '' : b;
  }

  static drop(subscriptionId: string): void {
    RawBodyCache.bodies.delete(subscriptionId);
  }

  static clear(): void {
    RawBodyCache.bodies.clear();
  }

  static size(): number {
    return RawBodyCache.bodies.size;
  }
}
