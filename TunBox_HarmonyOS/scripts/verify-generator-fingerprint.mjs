#!/usr/bin/env node
/**
 * 配置生成器指纹闸门（把 `scripts/latency-gen-fingerprint.json` 纳入总闸）
 *
 * ## 为什么单独抽一个脚本
 *
 * 指纹检查原本只存在于 `scripts/test-latency-engine.js`（一个 `test-` 前缀的脚本）里，
 * 而 `scripts/verify-all.mjs` **只自动发现 `verify-*.mjs`** →
 * 意味着「总闸全绿」并不代表指纹过了（这是一个真实的盲区，2026-10-20 被踩到：
 * 生成器改了、指纹没刷，verify-all 照样全绿）。
 *
 * 本脚本把同一条检查抽出来，让它进入总闸；两处共用同一份指纹文件与同一条算法
 * （先统一换行符为 LF，再取 SHA-256 前 16 位十六进制），不会出现「两套口径」或平台换行差异。
 *
 * ## 规则
 *
 * `ClashConfigGenerator.ets` 是「延迟测试重做不得改动」的禁区：
 * 改它必须同步更新 `scripts/latency-gen-fingerprint.json` 并在 `docs/latency-redesign.md`
 * 写明原因（该文档的「指纹变更说明」小节是它的台账）。
 *
 * 跑法：node scripts/verify-generator-fingerprint.mjs
 * 退出码：0 = 指纹一致；1 = 不一致（生成器被改了但指纹没更新）。
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const genPath = path.join(root, 'entry/src/main/ets/commons/services/ClashConfigGenerator.ets');
const fpPath = path.join(here, 'latency-gen-fingerprint.json');

let passed = 0;
let failed = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}

console.log('── 配置生成器指纹 ──');
const gen = fs.readFileSync(genPath, 'utf8').replace(/\r\n/g, '\n');
const actual = crypto.createHash('sha256').update(gen, 'utf8').digest('hex').slice(0, 16);
let expected = '';
try {
  expected = JSON.parse(fs.readFileSync(fpPath, 'utf8')).sha256_16 || '';
} catch (e) {
  expected = '';
}
ok(expected.length > 0, '指纹文件可读且含 sha256_16');
ok(actual === expected,
  `生成器指纹一致（实际 ${actual} / 期望 ${expected || '(缺失)'}）`);
if (actual !== expected) {
  console.log('');
  console.log('  提示：生成器被改动且指纹未更新。若是有意改动，请：');
  console.log('    1) 更新 scripts/latency-gen-fingerprint.json 的 sha256_16；');
  console.log('    2) 在 docs/latency-redesign.md 的「指纹变更说明」小节写明原因与改动项。');
}
console.log('');
console.log(`RESULT: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
