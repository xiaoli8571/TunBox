#!/usr/bin/env node
/**
 * 订阅拉取层与 FlClash 对齐的闸门（Subscription Fetch Parity Gate）
 *
 * 覆盖两处 2026-10-22 新增的 FlClash 等价行为 —— 它们都是**纯字符串/URL 处理**，
 * 不需要真机也不需要网络，所以能在这里逐条对拍：
 *
 *   A. `authTarget()`：URL 里的 `user:pass@` 剥出来转 `Authorization: Basic`
 *      （FlClash `lib/common/request.dart:150-165` 的 `downloadTarget`）。
 *      同时断言 `isValidSubscriptionUrl()` 接受这种地址 —— 旧规则
 *      （authority 里含 `@` 直接拒绝）会让带 Basic 凭据的订阅链接根本进不来。
 *   B. `fileNameFromDisposition()`：`content-disposition` → 订阅名
 *      （FlClash `getFileNameForDisposition`，`filename*` 优先、其次 `filename`）。
 *
 * 加载方式：把真源码 `SubscriptionFetchPolicy.ets` stage 到临时目录，
 * 只把它的 kit import 换成垫片（http/connection/url/util），其余逻辑一行不改。
 *
 *   node scripts/verify-sub-fetch-parity.mjs              # 正常跑
 *   node scripts/verify-sub-fetch-parity.mjs --self-test  # 附带负对照
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const srcFile = path.join(root, 'entry/src/main/ets/commons/services/SubscriptionFetchPolicy.ets');
const codecFile = path.join(root, 'entry/src/main/ets/commons/subscription/HttpBodyCodec.ets');

let passed = 0;
let failed = 0;
const lines = [];

function ok(condition, message, actual) {
  if (condition) {
    passed += 1;
    return;
  }
  failed += 1;
  const suffix = actual === undefined ? '' : ` — 实际=${String(actual)}`;
  lines.push(`  ❌ ${message}${suffix}`);
}

const SHIM_NETWORK = `export const http = {
  createHttp: () => { throw new Error('shim: 网络不参与本闸门'); }
};
export const connection = {};
`;

const SHIM_ARKTS = `
class Encoder {
  static create(_enc) { return new Encoder(); }
  encodeInto(input) { return new TextEncoder().encode(input === undefined ? '' : input); }
}
class Decoder {
  static create(_enc) { return new Decoder(); }
  decodeToString(bytes) { return new TextDecoder().decode(bytes); }
}
class Base64Helper {
  encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); }
}
export const util = { TextEncoder: Encoder, TextDecoder: Decoder, Base64Helper };
// ArkTS 的 url.URL.parseURL：host 里**带 userinfo**（源码里 authority.includes('@')
// 这条防御就是这么写的），Node 的 URL.host 不带 —— 垫片按 ArkTS 语义还原。
export const url = {
  URL: {
    parseURL(value) {
      const parsed = new URL(value);
      const cred = parsed.username === '' && parsed.password === ''
        ? ''
        : parsed.username + ':' + parsed.password + '@';
      return {
        protocol: parsed.protocol,
        host: cred + parsed.host,
        hostname: parsed.hostname,
        port: parsed.port
      };
    }
  }
};
`;

/**
 * Node 的类型剥离模式不支持 `enum`（SubscriptionFetchErrorKind），
 * 这里把它降级成等价的对象字面量（仓库其它闸门用同样的做法：
 * 见 verify-mihomo-alignment.mjs 的 stripEnums）。
 */
function stripEnums(text) {
  return text.replace(/export enum (\w+) \{([\s\S]*?)\n\}/g, (whole, name, body) => {
    const pairs = body
      .split(',')
      .map((item) => item.trim())
      .filter((item) => item.length > 0)
      .map((item) => {
        const eq = item.indexOf('=');
        if (eq < 0) {
          return `${item}: '${item}'`;
        }
        return `${item.substring(0, eq).trim()}: ${item.substring(eq + 1).trim()}`;
      });
    return `export const ${name} = { ${pairs.join(', ')} };`;
  });
}

function stageModule(sourceTransform) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'tunbox-fetch-parity-'));
  fs.writeFileSync(path.join(tmp, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');
  fs.mkdirSync(path.join(tmp, 'shims'));
  fs.mkdirSync(path.join(tmp, 'services'));
  fs.mkdirSync(path.join(tmp, 'utils'));
  fs.mkdirSync(path.join(tmp, 'subscription'));
  fs.writeFileSync(path.join(tmp, 'shims/network.ts'), SHIM_NETWORK, 'utf8');
  fs.writeFileSync(path.join(tmp, 'shims/arkts.ts'), SHIM_ARKTS, 'utf8');
  fs.writeFileSync(path.join(tmp, 'services/AppProxyRoute.ts'), `export class AppProxyRoute {
  static activePort() { return -1; }
}
`, 'utf8');
  fs.writeFileSync(path.join(tmp, 'services/LocalSubConverter.ts'), `export class LocalSubConverter {
  static isLocalUrl(_value) { return false; }
  static idOf(_value) { return ''; }
  static render(_id) { return { ok: false, reason: 'shim' }; }
}
`, 'utf8');
  fs.writeFileSync(path.join(tmp, 'utils/AppLogger.ts'), `export class AppLogger {
  static info(_tag, _msg) {}
  static warn(_tag, _msg) {}
  static errText(e) { return e && e.message ? e.message : String(e); }
}
`, 'utf8');
  fs.writeFileSync(path.join(tmp, 'utils/AppInfo.ts'), `export class AppInfo {
  static version() { return '0.0.0-test'; }
}
`, 'utf8');
  const codecText = fs.readFileSync(codecFile, 'utf8');
  fs.writeFileSync(path.join(tmp, 'subscription/HttpBodyCodec.ts'), codecText, 'utf8');
  const text = fs.readFileSync(srcFile, 'utf8');
  const patched = text
    .replace("from '@kit.NetworkKit'", "from '../shims/network.ts'")
    .replace("from '@kit.ArkTS'", "from '../shims/arkts.ts'")
    .replace("from './AppProxyRoute'", "from './AppProxyRoute.ts'")
    .replace("from './LocalSubConverter'", "from './LocalSubConverter.ts'")
    .replace("from '../utils/AppLogger'", "from '../utils/AppLogger.ts'")
    .replace("from '../utils/AppInfo'", "from '../utils/AppInfo.ts'")
    .replace("from '../subscription/HttpBodyCodec'", "from '../subscription/HttpBodyCodec.ts'");
  const finalText = stripEnums(sourceTransform === undefined ? patched : sourceTransform(patched));
  fs.writeFileSync(path.join(tmp, 'services/SubscriptionFetchPolicy.ts'), finalText, 'utf8');
  return { dir: tmp, source: text };
}

async function load(target) {
  const url = pathToFileURL(path.join(target.dir, 'services/SubscriptionFetchPolicy.ts')).href;
  return import(url);
}

function runChecks(Policy) {
  // ── A. Basic 鉴权 ──
  const withAuth = Policy.authTarget('https://user:pa%40ss@panel.example:8443/sub?x=1#f');
  ok(withAuth.url === 'https://panel.example:8443/sub?x=1#f',
    '带 userinfo 的地址 ⇒ 请求地址剥掉 user:pass@，路径/端口/查询/锚点原样', withAuth.url);
  ok(withAuth.header === `Basic ${Buffer.from('user:pa@ss').toString('base64')}`,
    'userinfo ⇒ Authorization: Basic base64(user:pass)，百分号解码后再编码', withAuth.header);

  const noAuth = Policy.authTarget('https://panel.example/sub');
  ok(noAuth.url === 'https://panel.example/sub' && noAuth.header === '',
    '不带 userinfo ⇒ 地址原样、不发 Authorization', `${noAuth.url}|${noAuth.header}`);

  const userOnly = Policy.authTarget('https://onlyuser@panel.example/sub');
  ok(userOnly.header === `Basic ${Buffer.from('onlyuser:').toString('base64')}`,
    '只有用户名 ⇒ Basic base64("user:")（与 FlClash 的 userinfo 拼接一致）', userOnly.header);

  // 校验必须接受这种地址（旧规则 authority 含 '@' 直接拒 ⇒ 带 Basic 的订阅链接进不来）
  ok(Policy.isValidSubscriptionUrl('https://user:pass@panel.example/sub'),
    '带 Basic 凭据的订阅地址 ⇒ 校验通过（否则 authTarget 永远用不上）');
  ok(Policy.isValidSubscriptionUrl('https://user:pass@panel.example/sub', true),
    'https + Basic 凭据 ⇒ 校验通过');
  ok(!Policy.isValidSubscriptionUrl('http://user:pass@panel.example/sub'),
    '默认仍禁用明文 http（带凭据也不例外）');
  ok(Policy.isValidSubscriptionUrl('http://user:pass@panel.example/sub', true),
    '允许明文 http 时，带凭据的 http 地址也通过');
  ok(!Policy.isValidSubscriptionUrl('https://user:pass@192.168.1.10/sub'),
    '带凭据也不能绕开私网地址守卫');
  ok(!Policy.isValidSubscriptionUrl('https://user:pass@localhost/sub'),
    '带凭据也不能绕开 localhost 守卫');

  // ── B. content-disposition → 订阅名 ──
  const rfc5987 = "attachment; filename*=UTF-8''%E6%B5%8B%E8%AF%95%E6%9C%BA%E5%9C%BA.yaml";
  ok(Policy.fileNameFromDisposition(rfc5987) === '测试机场.yaml',
    'filename*=UTF-8\'\'<pct> ⇒ 百分号解码成中文文件名',
    Policy.fileNameFromDisposition(rfc5987));
  ok(Policy.fileNameFromDisposition('attachment; filename="abc.yml"') === 'abc.yml',
    'filename="..." ⇒ 去掉引号', Policy.fileNameFromDisposition('attachment; filename="abc.yml"'));
  ok(Policy.fileNameFromDisposition('attachment; filename=plain.yml') === 'plain.yml',
    'filename 不带引号 ⇒ 原样取', Policy.fileNameFromDisposition('attachment; filename=plain.yml'));
  ok(Policy.fileNameFromDisposition("attachment; filename=plain.yml; filename*=UTF-8''ext.yml") === 'ext.yml',
    'filename 与 filename* 同时出现 ⇒ filename* 优先（FlClash 同规则）',
    Policy.fileNameFromDisposition("attachment; filename=plain.yml; filename*=UTF-8''ext.yml"));
  ok(Policy.fileNameFromDisposition('attachment') === '',
    '只有 disposition 类型、没有文件名 ⇒ 空串（调用方保留现有名称）',
    Policy.fileNameFromDisposition('attachment'));
  ok(Policy.fileNameFromDisposition('') === '', '空响应头 ⇒ 空串');
  const quotedSemicolon = 'attachment; filename="a;b.yml"';
  ok(Policy.fileNameFromDisposition(quotedSemicolon) === 'a;b.yml',
    '引号里的分号不切参数', Policy.fileNameFromDisposition(quotedSemicolon));
  ok(Policy.fileNameFromDisposition("attachment; filename*=UTF-8''%E4%B8%AD.yml") === '中.yml',
    'filename* 的 UTF-8 多字节文件名解码正确',
    Policy.fileNameFromDisposition("attachment; filename*=UTF-8''%E4%B8%AD.yml"));

  // ── C. 大小上限（顺带确认没被改动） ──
  ok(Policy.isResponseSizeAllowed(8 * 1024 * 1024), '响应体 8 MiB 上限内允许');
  ok(!Policy.isResponseSizeAllowed(8 * 1024 * 1024 + 1), '响应体超过 8 MiB 拒绝');
  ok(Policy.redactUrl('https://user:pass@panel.example/sub') === 'panel.example',
    '日志脱敏只留 host（不泄露 user:pass）',
    Policy.redactUrl('https://user:pass@panel.example/sub'));
}

/** ── 负对照：改坏源码，闸门必须红 ─────────────────────────────────────── */

async function selfTest() {  const cases = [
    {
      name: 'authTarget 退化成"原样返回"（Basic 凭据从不发出）',
      apply: (text) => text.replace('    out.url = urlStr.substring(0, authorityStart) + hostPart + urlStr.substring(authorityEnd);',
        '    out.url = urlStr;')
    },
    {
      name: 'fileNameFromDisposition 退化成"永远空串"（标题只用默认名）',
      apply: (text) => text.replace('  static fileNameFromDisposition(disposition: string): string {',
        '  static fileNameFromDisposition(disposition: string): string {\n    if (disposition.length >= 0) { return \'\'; }')
    },
    {
      name: 'URL 校验重新拒绝带 userinfo 的地址（Basic 订阅进不来）',
      apply: (text) => text.replace('    const target = SubscriptionFetchPolicy.authTarget(urlStr).url;',
        '    const target = urlStr;')
    }
  ];
  let allCaught = true;
  for (const testCase of cases) {
    const staged = stageModule(testCase.apply);
    let mod = null;
    try {
      mod = await load(staged);
    } catch (err) {
      ok(false, `负对照「${testCase.name}」⇒ 改坏后仍能加载（语法被改坏不算数）：${err.message}`);
      allCaught = false;
      continue;
    }
    const beforePassed = passed;
    const beforeFailed = failed;
    const beforeLines = lines.length;
    runChecks(mod.SubscriptionFetchPolicy);
    const caught = failed > beforeFailed;
    console.log(`  · ${testCase.name} → 闸门判决 ${passed - beforePassed} passed, ${failed - beforeFailed} failed`);
    if (caught) {
      console.log('    ✅ 被抓住');
    } else {
      allCaught = false;
      console.log('    ❌ 没被抓住（闸门对这个改坏不敏感）');
    }
    // 回滚本次负对照产生的计数与失败行，避免污染正向结果
    passed = beforePassed;
    failed = beforeFailed;
    lines.length = beforeLines;
  }
  return allCaught;
}

async function main() {
  const withSelfTest = process.argv.includes('--self-test');
  const staged = stageModule(undefined);
  let mod;
  try {
    mod = await load(staged);
  } catch (err) {
    console.error('加载 SubscriptionFetchPolicy.ets（垫片 stage）失败：', err && err.message);
    process.exit(1);
  }
  console.log('── 订阅拉取层 FlClash 对齐闸门（Basic 鉴权 / content-disposition 标题）──');
  runChecks(mod.SubscriptionFetchPolicy);
  console.log(`  断言：${passed} passed, ${failed} failed`);
  if (failed > 0) {
    for (const line of lines) {
      console.log(line);
    }
  }
  let selfTestOk = true;
  if (withSelfTest) {
    console.log('');
    console.log('── 负对照（故意改坏 SubscriptionFetchPolicy.ets，闸门必须 FAILED）──');
    selfTestOk = await selfTest();
    if (!selfTestOk) {
      console.log('  ❌ 负对照失败：闸门对改坏不敏感');
    }
  }
  console.log('');
  console.log(`PASSED=${passed} FAILED=${failed} TOTAL=${passed + failed}`);
  console.log(`RESULT: ${failed === 0 && selfTestOk ? 'SUB FETCH PARITY PASSED' : 'SUB FETCH PARITY FAILED'}`);
  process.exit(failed === 0 && selfTestOk ? 0 : 1);
}

await main();
