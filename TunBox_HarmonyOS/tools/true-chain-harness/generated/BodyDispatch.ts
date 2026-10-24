// [harness] generated from entry/src/main/ets/commons/subscription/BodyDispatch.ets — 仅 import 目标被重写
/**
 * 订阅正文的分派（Body Dispatch）：先解码，再判"是不是 YAML 文档"。
 *
 * ## 要修的真 bug
 *
 * 原分派只看**明文**正文里有没有 `proxies:` 段：
 *
 * ```
 * const structuredYaml = YamlMerger.proxyItemGroups(body).length > 0;
 * if (structuredYaml) { …YAML 路径… } else { …链接列表路径… }
 * ```
 *
 * 于是**base64 包裹的 Clash YAML**（机场很常见：把整份 YAML 做一次 base64）
 * 会掉进链接列表分支：那个分支会把 base64 解码后**逐行当分享链接**解析，
 * YAML 的每一行都不是链接 ⇒ 全部判"无效链接" ⇒ **整份订阅 0 节点**
 * （用户看到的就是"导入失败"）。
 *
 * ## 正确口径
 *
 * > 先解码，再判是不是 YAML 文档，最后才决定走哪条路径。
 *
 * 判定顺序：
 * 1. 明文正文里有 `proxies:` 段 ⇒ YAML 路径（原文即用）；
 * 2. 明文像 base64 ⇒ 解码；解码后有 `proxies:` 段 ⇒ YAML 路径（**用解码后的正文**）；
 * 3. 否则 ⇒ 链接列表路径（base64 链接列表由解析器自己解，不在这里插手）。
 *
 * 本文件是**纯函数**，不 import 任何 kit（YamlMerger 只依赖 @kit.ArkTS，
 * Node 侧测试台有现成的 shim 模式），所以能直接被单测覆盖。
 */
import { YamlMerger } from './YamlMerger.ts';
import { UriNodeParser } from './UriNodeParser.ts';

/** 正文体裁 */
export class BodyKind {
  /** Clash YAML（含 base64 包裹后解码得到的） */
  static readonly YAML: string = 'yaml';
  /** 分享链接列表（明文或整段 base64） */
  static readonly URI: string = 'uri';
}

/** 分派结果 */
export class BodyDispatchResult {
  /** 体裁 */
  kind: string = BodyKind.URI;
  /** 实际用于解析的正文（base64 包裹的 YAML → 解码后的明文） */
  body: string = '';
  /** 正文是否经过 base64 解码 */
  decoded: boolean = false;
  /** 原文看起来是否是 base64 */
  wasBase64: boolean = false;
}

export class BodyDispatch {
  /**
   * 判定正文体裁，并给出**真正该拿去解析的正文**。
   *
   * @param body 订阅原文（未解码）
   */
  static classify(body: string): BodyDispatchResult {
    const out = new BodyDispatchResult();
    out.body = body;
    // 1) 明文就是 Clash YAML
    if (/^(?:\uFEFF)?(?:proxies|proxy-groups|proxy-providers)\s*:/m.test(body)) {
      out.kind = BodyKind.YAML;
      return out;
    }
    // 2) 疑似 base64 → 解码后再判一次是不是 YAML 文档
    const compact = body.replace(/\s+/g, '');
    if (compact.length === 0 || !UriNodeParser.isBase64Text(compact)) {
      return out;
    }
    out.wasBase64 = true;
    const decoded = UriNodeParser.base64Decode(compact);
    if (decoded.length === 0) {
      return out;
    }
    if (/^(?:\uFEFF)?(?:proxies|proxy-groups|proxy-providers)\s*:/m.test(decoded)) {
      out.kind = BodyKind.YAML;
      out.decoded = true;
      out.body = decoded;
      return out;
    }
    // 解码出来不是 YAML（多半是 base64 的链接列表）→ 交回链接列表路径自己解
    return out;
  }
}
