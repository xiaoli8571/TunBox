#!/usr/bin/env node
/**
 * 去广告规则集安全闸门（Rule Provider Safety Gate）—— 2026-10-23 用户报障
 *
 * ## 报障
 *
 * 「0.5.4 手动更新去广告规则后 VPN 就启动失败，删掉规则集就启动正常。」
 *
 * ## 根因（本闸门守的就是这几条）
 *
 * 1. 手动更新走 GitHub 加速前缀（gh-proxy / ghfast）。代理返回的 **HTML/JSON 错误页**
 *    体积常超过 1KB，而旧校验只有 `size > 0`（就绪判定）与 `byteLength > 1024`
 *    （下载校验）→ 错误页被当成 `.mrs` 落盘。
 * 2. 内核加载 rule-provider 时 zstd 解不开 / 内层头不是 `MRS\x01` / behavior 不匹配
 *    → **config.Parse 整份失败 → 隧道起不来**。删掉文件后 `ruleProviderReady=false`，
 *    配置里不声明 RULE-SET，于是又能连 —— 与用户观察完全一致。
 * 3. 原有失败处理只会「回滚配置」，而配置文本是好的、坏的是 provider 文件本身，
 *    回滚后的配置照样引用同一个坏文件 → 用户永远连不上。
 *
 * ## 契约
 *
 * A. 下载校验：体积下限 + **zstd 魔数**（合法 .mrs 前 4 字节 0x28 0xB5 0x2F 0xFD）。
 * B. 就绪判定同源：`isRuleProviderReady()` 必须走 `ruleSetFileOk()`（体积 + 魔数），
 *    坏文件 = 未就绪 = 本轮配置不带 RULE-SET → 隧道照常能起。
 * C. 启动失败自愈：错误文本指向规则集时，先回滚 `.good` 副本，没有副本则隔离成
 *    `.bad-<时间戳>`；连接成功后要把当前规则集快照成 `.good`。
 * D. 删除规则集时连 `.good` 一起删（否则自愈会把它"复活"）。
 * E. 负对照：把魔数校验删掉 / 就绪判定退回 size>0 / 去掉自愈 —— 闸门必须变红。
 *
 * 跑法：
 *   node scripts/verify-rule-provider-safety.mjs
 *   node scripts/verify-rule-provider-safety.mjs --self-test
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const ORCH = path.join(root, 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets');

let passed = 0;
let failed = 0;
const failures = [];

function ok(cond, label, actual) {
  if (cond) {
    passed += 1;
    return;
  }
  failed += 1;
  failures.push(`  ❌ ${label}${actual === undefined ? '' : ` —— ${actual}`}`);
}

/** 取出某个方法体（从签名行到大括号配平），用于断言方法内部实现 */
function methodBody(src, signature) {
  const start = src.indexOf(signature);
  if (start < 0) {
    return '';
  }
  let i = src.indexOf('{', start);
  if (i < 0) {
    return '';
  }
  let depth = 0;
  for (let j = i; j < src.length; j += 1) {
    const ch = src[j];
    if (ch === '{') {
      depth += 1;
    } else if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        return src.slice(i, j + 1);
      }
    }
  }
  return '';
}

function checkSource(src) {
  ok(/const RULE_SET_MIN_BYTES = 1024;/.test(src), '体积下限常量 RULE_SET_MIN_BYTES 存在');
  ok(/const ZSTD_MAGIC: number\[\] = \[0x28, 0xB5, 0x2F, 0xFD\];/.test(src),
    'zstd 魔数常量（合法 .mrs 是 zstd frame）');
  ok(/const RULE_SET_GOOD_SUFFIX = '\.good';/.test(src), 'last-good 副本后缀常量存在');

  // 2026-10-23：下载实现按 PR #5 拆成「单航班入口 + 真正执行体」，校验逻辑在后者的方法体里。
  const download = methodBody(src, 'private async performRuleProviderDownload(source: string): Promise<boolean>')
    || methodBody(src, 'private async downloadRuleProviderAsset(source: string): Promise<boolean>');
  ok(download.length > 0, '找到 downloadRuleProviderAsset 方法');
  ok(/bufferMagicOk\(buf, ZSTD_MAGIC\)/.test(download),
    '下载校验必须检查 zstd 魔数（挡住代理错误页）');
  ok(!/buf\.byteLength > 1024;/.test(download),
    '下载校验不再只查体积（错误页也 >1KB）');
  ok(/RULE_SET_MIN_BYTES/.test(download), '下载校验使用体积下限常量');

  const ready = methodBody(src, 'private isRuleProviderReady(): boolean');
  ok(/ruleSetFileOk\(\)/.test(ready), 'isRuleProviderReady 走 ruleSetFileOk（与下载同口径）');

  const fileOk = methodBody(src, 'private ruleSetFileOk(): boolean');
  ok(/RULE_SET_MIN_BYTES/.test(fileOk), 'ruleSetFileOk 校验体积下限');
  ok(/bufferMagicOk\(head, ZSTD_MAGIC\)/.test(fileOk), 'ruleSetFileOk 校验 zstd 魔数');
  ok(/fs\.readSync/.test(fileOk), 'ruleSetFileOk 真的读文件头（不是只看 stat）');

  const heal = methodBody(src, 'private healRuleSet(reason: string): string');
  ok(heal.length > 0, '找到 healRuleSet 自愈方法');
  ok(/return 'restored';/.test(heal) && /return 'quarantined';/.test(heal),
    '自愈两级：先回滚 last-good，再隔离坏文件');
  ok(/RULE_SET_GOOD_SUFFIX/.test(heal), '自愈使用 last-good 副本');

  const snapshot = methodBody(src, 'private snapshotRuleSetGood(): void');
  ok(/ruleSetFileOk\(\)/.test(snapshot), '只把「本体校验通过」的文件快照成 last-good');
  ok(/copyFileSync/.test(snapshot), '快照用复制（保留原文件给内核用）');

  ok(/this\.snapshotRuleSetGood\(\);\s*\n\s*\/\/|this\.snapshotRuleSetGood\(\);/.test(src),
    '连接成功路径调用 snapshotRuleSetGood');
  const successRegion = src.slice(src.indexOf("this.confirmProfileApplied('tunnel')"),
    src.indexOf("this.confirmProfileApplied('tunnel')") + 400);
  ok(/snapshotRuleSetGood\(\)/.test(successRegion),
    'snapshotRuleSetGood 紧跟「隧道配置已生效」之后（确有成功才快照）');

  const looksLike = methodBody(src, 'private looksLikeRuleSetFailure(errorText: string): boolean');
  ok(/mrs/.test(looksLike) && /invalid behavior/.test(looksLike) && /zstd/.test(looksLike),
    '失败识别覆盖 mrs / invalid behavior / zstd 三类措辞');
  ok(/ruleSetFileExists\(\)/.test(looksLike),
    '只有在规则集文件存在时才认作规则集故障（不误伤别的原因）');

  const healCall = /looksLikeRuleSetFailure\(errorText\)/.test(src)
    && /this\.healRuleSet\('kernel rejected rule-provider'\)/.test(src);
  ok(healCall, '启动失败 catch 里接入自愈（不再只回滚配置）');

  const del = methodBody(src, 'deleteGeoAsset(id: string): string');
  ok(/RULE_SET_GOOD_SUFFIX/.test(del), '删除规则集时一并删掉 last-good 副本');
}

/** 校验逻辑的 JS 移植（与 ArkTS 侧 bufferMagicOk + ruleSetFileOk 同判据） */
const ZSTD_MAGIC = [0x28, 0xb5, 0x2f, 0xfd];
const MIN_BYTES = 1024;

function magicOk(buf, magic) {
  if (buf.length < magic.length) {
    return false;
  }
  for (let i = 0; i < magic.length; i += 1) {
    if (buf[i] !== magic[i]) {
      return false;
    }
  }
  return true;
}

function fileOk(buf) {
  return buf.length >= MIN_BYTES && magicOk(buf, ZSTD_MAGIC);
}

function checkBehaviour() {
  const zstdHead = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);
  const valid = Buffer.concat([zstdHead, Buffer.alloc(4096, 0x11)]);
  ok(fileOk(valid), '行为：合法 zstd 头的 .mrs 判定可用');

  const html = Buffer.from(`<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head>`
    + `<body>${'x'.repeat(2048)}</body></html>`);
  ok(!fileOk(html), '行为：代理返回的 HTML 错误页被拒绝（体积 >1KB 也拒绝）');

  const json = Buffer.from(JSON.stringify({ message: 'rate limited', pad: 'y'.repeat(2048) }));
  ok(!fileOk(json), '行为：JSON 错误响应被拒绝');

  const truncated = Buffer.from([0x28, 0xb5, 0x2f]);
  ok(!fileOk(truncated), '行为：半截 zstd 头被拒绝');

  const tiny = Buffer.from([0x28, 0xb5, 0x2f, 0xfd, 0x00]);
  ok(!fileOk(tiny), '行为：体积低于下限（半截下载）被拒绝');

  const wrongMagic = Buffer.alloc(4096, 0x00);
  wrongMagic[0] = 0x1f;
  wrongMagic[1] = 0x8b;
  ok(!fileOk(wrongMagic), '行为：gzip 头（不是 MRS 的 zstd 形态）被拒绝');

  ok(magicOk(Buffer.from('MRS'.concat('\x01')), Buffer.from('MRS'.concat('\x01'))),
    '行为：magicOk 对相同前缀返回 true（判据本身不误杀）');

  // 旧实现判据（只查体积）必须与新版产生差异 —— 证明这道闸门真的在拦东西
  const oldOk = (buf) => buf.length > MIN_BYTES;
  ok(oldOk(html) && !fileOk(html),
    '行为：旧判据(size>1024)会放行的错误页，新判据拒绝（回归得到覆盖）');
}

function selfTest(baseSrc) {
  const cases = [
    {
      name: '下载校验退回只查体积',
      mutate: (s) => s.replace(
        /\(buf: ArrayBuffer\): boolean => buf\.byteLength >= RULE_SET_MIN_BYTES\s*\n\s*&& ConnectionOrchestrator\.bufferMagicOk\(buf, ZSTD_MAGIC\)/,
        '(buf: ArrayBuffer): boolean => buf.byteLength > 1024')
    },
    {
      name: '就绪判定退回 size>0',
      mutate: (s) => s.replace('private isRuleProviderReady(): boolean {\n    return this.ruleSetFileOk();',
        'private isRuleProviderReady(): boolean {\n    return true;')
    },
    {
      name: '去掉启动失败自愈',
      mutate: (s) => s.replace("this.healRuleSet('kernel rejected rule-provider')", "''")
    }
  ];
  let allCaught = true;
  for (const testCase of cases) {
    const mutated = testCase.mutate(baseSrc);
    const changed = mutated !== baseSrc;
    const beforePassed = passed;
    const beforeFailed = failed;
    const beforeFailures = failures.length;
    checkSource(mutated);
    const caught = failed > beforeFailed;
    console.log(`  · ${testCase.name} → 判决 ${passed - beforePassed} passed, ${failed - beforeFailed} failed`
      + `${changed ? '' : '（注：变异未生效）'}`);
    console.log(caught ? '    ✅ 被抓住' : '    ❌ 没抓住（闸门不敏感）');
    if (!caught) {
      allCaught = false;
    }
    passed = beforePassed;
    failed = beforeFailed;
    failures.length = beforeFailures;
  }
  return allCaught;
}

function main() {
  const withSelfTest = process.argv.includes('--self-test');
  const src = fs.readFileSync(ORCH, 'utf8');
  console.log('── 去广告规则集安全自检（下载校验 / 就绪判定 / 失败自愈）──');
  checkSource(src);
  checkBehaviour();
  console.log(`  断言：${passed} passed, ${failed} failed`);
  for (const line of failures) {
    console.log(line);
  }
  let selfTestOk = true;
  if (withSelfTest) {
    console.log('');
    console.log('── 负对照（故意改坏源码，闸门必须 FAILED）──');
    selfTestOk = selfTest(src);
  }
  console.log('');
  console.log(`PASSED=${passed} FAILED=${failed} TOTAL=${passed + failed}`);
  console.log(`RESULT: ${failed === 0 && selfTestOk ? 'RULE PROVIDER SAFETY PASSED' : 'RULE PROVIDER SAFETY FAILED'}`);
  process.exit(failed === 0 && selfTestOk ? 0 : 1);
}

main();
