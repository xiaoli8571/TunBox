#!/usr/bin/env node
/**
 * 配置校验闸门 × **真实内核** 交叉验证（C23/C23b/C23c 的最终判据）
 *
 * ## 为什么需要这道闸门
 *
 * 方案文档 §9.3.3 诚实写明：那份根因清单的**行号**来自自写 yaml.v3 仿真器，
 * 「未在真机内核复现」—— 也就是说，当时的结论是**推演**出来的，不是内核判的。
 *
 * 本机其实**有真实内核**：mihomo-build 目录下的 mihomo-smart-…/mihomo.exe
 * （Mihomo Meta 1.10.0，与 App 内置的是同一份构建）。
 * `mihomo.exe -t -d <home> -f <cfg>` 就是**真判决**：通过 = 内核能加载整份配置，
 * 失败 = 整份拒载（与用户报障的 `parse config:yaml: unmarshal errors:...` 同一种形态）。
 *
 * 于是本脚本做三件事（**不碰真机、纯离线**）：
 *   ① 对每份样例配置，用真实内核判「接受 / 拒载 + 错误文本」；
 *   ② 用真实 `ConfigValidator.ets` 判「阻塞 / 可降级 / 降级后文本」；
 *   ③ 断言二者**一致**：
 *      - 校验器说阻塞的 → 内核必须真的拒载（不能漏拦）；
 *      - 校验器说通过的 → 内核必须真的接受（不能误拦正常配置）；
 *      - 降级后的文本 → 内核必须真的接受（降级不能把配置改坏）。
 *
 * ## 找不到内核时
 *
 * 打印 SKIP 并以 0 退出（这台机器没有内核二进制时不应让整条门禁变红），
 * 但会在输出里明确写出「未做内核交叉验证」。
 *
 * 跑法：node scripts/verify-config-validator-kernel.mjs
 * 可用环境变量：MIHOMO_BIN（指定内核可执行文件路径）
 * 退出码：0 = 全绿（或 SKIP）；1 = 有断言失败
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// ── 找内核 ──────────────────────────────────────────────────────────────
function findMihomo() {
  if (process.env.MIHOMO_BIN && fs.existsSync(process.env.MIHOMO_BIN)) {
    return process.env.MIHOMO_BIN;
  }
  const candidates = [];
  // 与 App 内置内核同源的 Windows 构建（prepare.mjs 钉死的那一份）
  candidates.push('C:\\Worker\\TunBox\\TunBox-Window\\extra\\sidecar\\mihomo-smart.exe');
  const buildRoot = 'C:\\Worker\\TunBox\\mihomo-build';
  if (fs.existsSync(buildRoot)) {
    for (const dir of fs.readdirSync(buildRoot)) {
      candidates.push(path.join(buildRoot, dir, 'mihomo.exe'));
      candidates.push(path.join(buildRoot, dir, 'mihomo'));
    }
  }
  for (const c of candidates) {
    if (fs.existsSync(c)) {
      return c;
    }
  }
  return null;
}

const mihomo = findMihomo();
if (!mihomo) {
  console.log('SKIP: 本机没有找到 mihomo 内核可执行文件');
  console.log('      （未做「校验器 × 真实内核」交叉验证；可用 MIHOMO_BIN 环境变量指定路径）');
  console.log('RESULT: SKIPPED (no kernel binary)');
  process.exit(0);
}

// ── 暂存真实 ConfigValidator 源码（只换 import，逻辑一字不改）────────────
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'cfgv-kernel-'));
const vPath = path.join(root, 'entry/src/main/ets/commons/services/ConfigValidator.ets');
const vCode = fs.readFileSync(vPath, 'utf8')
  .replace(/import\s+\{\s*AppLogger\s*\}\s+from\s+'[^']+';\s*/,
    'const AppLogger = { warn() {}, info() {}, error() {} };\n');
const vFile = path.join(stage, 'ConfigValidator.ts');
fs.writeFileSync(vFile, vCode, 'utf8');
const { ConfigValidator, ConfigIssueKind } = await import(pathToFileURL(vFile).href);

// ── 真判决：让内核自己判 ───────────────────────────────────────────────
const home = path.join(stage, 'home');
fs.mkdirSync(home, { recursive: true });
let verdictCount = 0;
function kernelVerdict(text) {
  const cfg = path.join(stage, `cfg-${verdictCount++}.yaml`);
  fs.writeFileSync(cfg, text, 'utf8');
  let out = '';
  let code = 0;
  try {
    out = execFileSync(mihomo, ['-t', '-d', home, '-f', cfg], {
      encoding: 'utf8', timeout: 60000, stdio: ['ignore', 'pipe', 'pipe']
    });
  } catch (e) {
    code = typeof e.status === 'number' ? e.status : 1;
    out = String(e.stdout || '') + String(e.stderr || '');
  }
  const accepted = out.includes('test is successful');
  // 日志里的 msg 是被转义过的引号包裹字段：msg="yaml: unmarshal errors:\n  line 4: mapping key \"cipher\" already defined"
  // → 取值时要允许 \" 这种转义引号，否则会被截断。
  const errMatch = /msg="((?:[^"\\]|\\.)*)"/.exec(out);
  let errorText = errMatch ? errMatch[1] : '';
  if (errorText.includes('unmarshal errors')) {
    errorText = errorText.replace(/\\"/g, '"');
  }
  return { accepted, code, errorText };
}

let passed = 0;
let failed = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}\n       期望 ${e}\n       实际 ${a}`); }
}

console.log('===== 配置校验闸门 × 真实内核交叉验证 =====');
console.log(`[INFO] 内核: ${mihomo}`);
try {
  const v = execFileSync(mihomo, ['-v'], { encoding: 'utf8' }).split('\n')[0];
  console.log(`[INFO] 版本: ${v}`);
} catch (e) {
  console.log('[INFO] 版本: (无法读取)');
}

const BASE = [
  'mixed-port: 7890',
  'mode: rule',
  'log-level: warning',
  'proxies:',
  '  - {name: "n1", type: ss, server: a.test, port: 8389, cipher: aes-256-gcm, password: "p"}',
  'rules:',
  '  - MATCH,DIRECT'
];

console.log('── 1. 基准：正常配置 → 内核接受，校验器放行 ──');
{
  const text = BASE.join('\n');
  const k = kernelVerdict(text);
  ok(k.accepted, `内核接受（${k.errorText || '无错误'}）`);
  const v = ConfigValidator.validate(text);
  ok(v.ok, '校验器放行');
  eq(v.issues.length, 0, '校验器零问题');
}

console.log('── 2. flow map 内重复键（R0）→ 内核整份拒载，校验器拦得住 ──');
{
  const text = [
    'mixed-port: 7890',
    'mode: rule',
    'proxies:',
    '  - {name: "n1", type: ss, server: a.test, port: 8389, cipher: aes-256-gcm,'
      + ' cipher: aes-128-gcm, password: "p"}',
    'rules:',
    '  - MATCH,DIRECT'
  ].join('\n');
  const k = kernelVerdict(text);
  ok(!k.accepted, '内核整份拒载');
  ok(k.errorText.includes('already defined'), `内核报「重复键」形态：${k.errorText.slice(0, 90)}`);
  const v = ConfigValidator.validate(text);
  ok(!v.ok, '校验器判为阻塞');
  ok(v.issues.some((i) => i.kind === ConfigIssueKind.DUPLICATE_KEY_FLOW), '检出 flow map 重复键');
  const rep = ConfigValidator.repair(text);
  ok(rep.ok, '降级后不再阻塞');
  const k2 = kernelVerdict(rep.text);
  ok(k2.accepted, `降级产物被内核接受（${k2.errorText || '无错误'}）`);
}

console.log('── 3. 顶层重复键（R2/R5）→ 内核整份拒载 ──');
{
  const text = ['mixed-port: 7890', 'mode: rule', 'mode: global', 'rules:', '  - MATCH,DIRECT'].join('\n');
  const k = kernelVerdict(text);
  ok(!k.accepted, '内核整份拒载');
  const v = ConfigValidator.validate(text);
  ok(v.issues.some((i) => i.kind === ConfigIssueKind.DUPLICATE_KEY), '检出顶层重复键');
  const rep = ConfigValidator.repair(text);
  const k2 = kernelVerdict(rep.text);
  ok(k2.accepted, `降级产物被内核接受（${k2.errorText || '无错误'}）`);
}

console.log('── 4. 嵌套 flow map 重复键（R0b：ws-opts）→ 内核拒载 ──');
{
  const text = [
    'mixed-port: 7890',
    'mode: rule',
    'proxies:',
    '  - {name: "n1", type: vmess, server: a.test, port: 443, uuid: "u", alterId: 0,'
      + ' cipher: auto, ws-opts: {path: /a, path: /b}}',
    'rules:',
    '  - MATCH,DIRECT'
  ].join('\n');
  const k = kernelVerdict(text);
  ok(!k.accepted, '内核整份拒载');
  const v = ConfigValidator.validate(text);
  ok(v.issues.some((i) => i.kind === ConfigIssueKind.DUPLICATE_KEY_FLOW), '检出嵌套 flow map 重复键');
  const rep = ConfigValidator.repair(text);
  const k2 = kernelVerdict(rep.text);
  ok(k2.accepted, `降级产物被内核接受（${k2.errorText || '无错误'}）`);
}

console.log('── 5. rules 嵌套 seq（R6）→ 内核拒载（校验器判阻塞且不可降级）──');
{
  const text = ['mixed-port: 7890', 'mode: rule', 'rules:', '  - - DOMAIN,example.com,DIRECT'].join('\n');
  const k = kernelVerdict(text);
  ok(!k.accepted, '内核整份拒载');
  ok(k.errorText.includes('!!seq'), `内核报「!!seq into string」形态：${k.errorText.slice(0, 90)}`);
  const v = ConfigValidator.validate(text);
  ok(v.issues.some((i) => i.kind === ConfigIssueKind.NESTED_SEQ), '检出 rules 嵌套 seq');
  ok(!v.ok, '判为阻塞（该形态无法安全降级 → 必须拦下并保留上一份配置）');
}

console.log('── 6. 布尔字面量：**以内核实测为准** ──');
{
  // 6a. 不带引号的 yes/no/on/off —— 内核接受 → 校验器不得拦
  const yesText = ['mixed-port: 7890', 'mode: rule', 'allow-lan: yes', 'rules:', '  - MATCH,DIRECT'].join('\n');
  const kYes = kernelVerdict(yesText);
  ok(kYes.accepted, `内核接受 allow-lan: yes（${kYes.errorText || '无错误'}）`);
  const vYes = ConfigValidator.validate(yesText);
  ok(vYes.ok, '校验器放行（不得误拦）');
  eq(vYes.issues.length, 0, '校验器零问题');

  // 6b. 带引号的 "true" —— 内核拒载 → 校验器必须拦并能降级
  const quotedText = ['mixed-port: 7890', 'mode: rule', 'allow-lan: "true"', 'rules:', '  - MATCH,DIRECT'].join('\n');
  const kQ = kernelVerdict(quotedText);
  ok(!kQ.accepted, '内核整份拒载 allow-lan: "true"');
  ok(kQ.errorText.includes('into bool'), `内核报「!!str into bool」形态：${kQ.errorText.slice(0, 90)}`);
  const vQ = ConfigValidator.validate(quotedText);
  ok(vQ.issues.some((i) => i.kind === ConfigIssueKind.BOOL_AS_STR), '校验器检出带引号布尔');
  const repQ = ConfigValidator.repair(quotedText);
  const kQ2 = kernelVerdict(repQ.text);
  ok(kQ2.accepted, `降级产物被内核接受（${kQ2.errorText || '无错误'}）`);

  // 6c. flow map 里的带引号布尔
  const flowText = ['mixed-port: 7890', 'mode: rule', 'dns: {enable: "true"}', 'rules:', '  - MATCH,DIRECT'].join('\n');
  const kF = kernelVerdict(flowText);
  ok(!kF.accepted, '内核整份拒载 dns: {enable: "true"}');
  const vF = ConfigValidator.validate(flowText);
  ok(vF.issues.some((i) => i.kind === ConfigIssueKind.BOOL_AS_STR), '校验器检出 flow map 内带引号布尔');
  const repF = ConfigValidator.repair(flowText);
  const kF2 = kernelVerdict(repF.text);
  ok(kF2.accepted, `降级产物被内核接受（${kF2.errorText || '无错误'}）`);

  // 6d. 裸写数字落进 bool 字段（!!int into bool）—— 同样致命
  const intText = ['mixed-port: 7890', 'mode: rule', 'allow-lan: 1', 'rules:', '  - MATCH,DIRECT'].join('\n');
  const kI = kernelVerdict(intText);
  ok(!kI.accepted, '内核整份拒载 allow-lan: 1');
  ok(kI.errorText.includes('!!int'), `内核报「!!int into bool」形态：${kI.errorText.slice(0, 90)}`);
  const vI = ConfigValidator.validate(intText);
  ok(vI.issues.some((i) => i.kind === ConfigIssueKind.BOOL_AS_STR), '校验器检出裸写数字');
  const repI = ConfigValidator.repair(intText);
  ok(repI.text.includes('allow-lan: true'), '裸 1 归一为 true');
  const kI2 = kernelVerdict(repI.text);
  ok(kI2.accepted, `降级产物被内核接受（${kI2.errorText || '无错误'}）`);
}

console.log('── 7. 已知缺口（如实记录，不假装覆盖）──');
{
  // 数值字段的值非法（port: on / port: 8389x）→ 由 mihomo 自己的 proxy 解析器报错，
  // 不是 yaml 层错误，**校验器目前不覆盖**这一类（要覆盖需要逐协议字段表，超出本轮范围）。
  const text = [
    'mixed-port: 7890',
    'mode: rule',
    'proxies:',
    '  - {name: "n1", type: ss, server: a.test, port: on, cipher: aes-256-gcm, password: "p"}',
    'rules:',
    '  - MATCH,DIRECT'
  ].join('\n');
  const k = kernelVerdict(text);
  ok(!k.accepted, '内核拒载 port: on（证明这一类确实会炸）');
  const v = ConfigValidator.validate(text);
  ok(v.issues.length === 0, '校验器当前**不**覆盖数值字段的非法值（如实记录为已知缺口）');
  console.log('     ↳ 缺口处置：生成侧对节点字段做类型化产出（端口/密码等一律用数值/字符串形态），'
    + '写盘闸门只负责 yaml 层形态；真机验收时关注此类报错。');
}

console.log('── 8. 交叉验证总结：校验器口径与内核一致 ──');
{
  const summary = [];
  for (const name of ['allow-lan: yes', 'allow-lan: "true"', 'allow-lan: 1']) {
    const text = ['mixed-port: 7890', 'mode: rule', name, 'rules:', '  - MATCH,DIRECT'].join('\n');
    summary.push({ name, kernel: kernelVerdict(text).accepted, validator: ConfigValidator.validate(text).ok });
  }
  eq(summary, [
    { name: 'allow-lan: yes', kernel: true, validator: true },
    { name: 'allow-lan: "true"', kernel: false, validator: false },
    { name: 'allow-lan: 1', kernel: false, validator: false }
  ], '「内核接不接受」与「校验器放不放行」逐例一致');
}

fs.rmSync(stage, { recursive: true, force: true });
console.log('-----------------------------------------');
console.log(`RESULT: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
