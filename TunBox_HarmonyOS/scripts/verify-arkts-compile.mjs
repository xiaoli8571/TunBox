#!/usr/bin/env node
/**
 * ArkTS **真编译**闸门（把 DevEco 的 hvigor 编译器拉进总闸）
 *
 * ## 为什么必须有这道闸门（2026-10-20 真实踩坑）
 *
 * 本仓库原有的类型门禁（`scripts/verify-types.mjs`、`scripts/verify-remediation-types.mjs`）
 * 都是**用 SDK 自带的 tsc 跑**。但 ArkTS ≠ TypeScript：ArkTS 有一批**编译器专属规则**
 * （`arkts-no-untyped-obj-literals`、`arkts-no-any-unknown`、`arkts-no-destruct`…），
 * **tsc 完全不检查**。
 *
 * 于是出现过这一串：tsc 门禁全绿 → `scripts/verify-all.mjs` 全绿 → **DevEco 里 run 直接编译失败**：
 * ```
 * ERROR: 10605038 ArkTS Compiler Error
 * Object literal must correspond to some explicitly declared class or interface
 *   (arkts-no-untyped-obj-literals)
 * At File: entry/src/main/ets/commons/services/ConfigValidator.ets:52:32
 * ```
 * 根因：`export const ConfigIssueKind = { DUPLICATE_KEY: 'DUPLICATE_KEY', ... }`
 * —— 未标注类型的对象字面量在 ArkTS 里是**编译错误**（TS 里完全合法）。
 *
 * ⇒ 教训：**tsc 门禁不能代表「能编译」**。本脚本用**真的 hvigor 编译器**做判决。
 *
 * ## 口径
 *
 * - 跑 DevEco 的 `hvigorw.js` → `assembleHap`（含 `CompileArkTS` 任务）。
 * - **判失败**：出现 `ArkTS Compiler Error` / `ERROR: 10605xxx` / `Failed :entry:default@CompileArkTS`。
 * - **不判失败**：与本次代码无关的环境问题（如签名缺失）—— 但仍会原样打印出来供人看。
 * - 找不到 DevEco（node.exe / hvigorw.js / sdk / jbr 任一缺失）→ **跳过**（退出码 0 并打印说明），
 *   以免在没装 DevEco 的机器上把门禁打成红的。
 *
 * ## 跑法
 *
 * node scripts/verify-arkts-compile.mjs
 * 可用环境变量：DEVECO_HOME（默认 `C:\Program Files\Huawei\DevEco Studio`）、
 * DEVECO_SDK_HOME（默认 `<DEVECO_HOME>/sdk`）、JAVA_HOME（默认 `<DEVECO_HOME>/jbr`）。
 */
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

const deveco = process.env.DEVECO_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio';
const nodeExe = path.join(deveco, 'tools', 'node', 'node.exe');
const hvigorw = path.join(deveco, 'tools', 'hvigor', 'bin', 'hvigorw.js');
const sdkHome = process.env.DEVECO_SDK_HOME || path.join(deveco, 'sdk');
const javaHome = process.env.JAVA_HOME || path.join(deveco, 'jbr');

function missing(p) {
  return !fs.existsSync(p);
}
const gaps = [];
if (missing(nodeExe)) gaps.push(`node.exe: ${nodeExe}`);
if (missing(hvigorw)) gaps.push(`hvigorw.js: ${hvigorw}`);
if (missing(sdkHome)) gaps.push(`SDK: ${sdkHome}`);
if (missing(path.join(javaHome, 'bin', 'java.exe'))) gaps.push(`jbr: ${javaHome}`);

if (gaps.length > 0) {
  console.log('── ArkTS 真编译闸门：跳过（本机找不到完整的 DevEco 工具链）──');
  for (const g of gaps) console.log(`  · 缺 ${g}`);
  console.log('  ⇒ 本门禁只在装有 DevEco Studio 的机器上生效；tsc 门禁无法替代它（ArkTS 规则专属）。');
  console.log('');
  console.log('RESULT: 0 passed, 0 failed (skipped)');
  process.exit(0);
}

console.log('── ArkTS 真编译闸门（DevEco hvigor / assembleHap）──');
console.log(`   DevEco : ${deveco}`);
console.log(`   SDK    : ${sdkHome}`);
console.log('');

const env = {
  ...process.env,
  DEVECO_SDK_HOME: sdkHome,
  JAVA_HOME: javaHome,
  // Windows 的 PATH 分隔符是 ';'（在 bash 里手拼 ';' 才不会被 MSYS 转换坏）
  PATH: `${path.join(javaHome, 'bin')};${process.env.PATH || ''}`
};

const args = [
  hvigorw,
  '--mode', 'module',
  '-p', 'module=entry@default',
  '-p', 'product=default',
  '-p', 'requiredDeviceType=tablet',
  'assembleHap',
  '--analyze=normal',
  '--parallel',
  '--incremental'
];

/**
 * 跑一次真编译。
 *
 * 返回 { out, arktsErrors, buildOk }。
 *
 * ⚠ 2026-10-20（settings-ui 实测反馈）：**ArkTS 错误数为 0 但打包/签名阶段失败**是工具链偶发
 *   （实测一次 `Sign lib error msg : null AT entry : libs/arm64-v8a/libtunbox_core_napi.so`，
 *   紧接着重跑一次就 BUILD SUCCESSFUL）⇒ 这种「不是代码问题」的失败要**自动重试一次**再判红，
 *   否则会把工具链抖动误报成代码回归（用户看到「编译红了」会去查代码，实际代码是干净的）。
 */
function runOnce() {
  const r = spawnSync(nodeExe, args, {
    env,
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 128 * 1024 * 1024
  });
  const out = `${r.stdout || ''}\n${r.stderr || ''}`;
  const arktsErrors = out
    .split('\n')
    .filter((l) => /ArkTS Compiler Error|ERROR: 10605\d+|arkts-no-|Failed :entry:default@CompileArkTS|CompileArkTS.*error/i.test(l));
  const buildOk = /BUILD SUCCESSFUL/.test(out);
  return { out, arktsErrors, buildOk };
}

let run = runOnce();
if (run.arktsErrors.length === 0 && !run.buildOk) {
  console.log('  ⟳ ArkTS 错误数 = 0 但构建失败（签名/打包阶段）⇒ 自动重试一次（工具链偶发，不判红）');
  run = runOnce();
}
const out = run.out;

// ArkTS 编译错误 = 真失败（与签名/打包等环境问题区分开）
const arktsErrors = run.arktsErrors;
const compiled = /Finished :entry:default@CompileArkTS|UP-TO-DATE :entry:default@CompileArkTS/.test(out);
const buildOk = run.buildOk;

let passed = 0;
let failed = 0;
function ok(cond, label) {
  if (cond) { passed++; console.log(`  ✅ ${label}`); }
  else { failed++; console.log(`  ❌ ${label}`); }
}

ok(compiled, 'CompileArkTS 任务执行到（无 ArkTS 编译错误）');
ok(arktsErrors.length === 0, `无 ArkTS 编译错误${arktsErrors.length ? '：' + arktsErrors.slice(0, 5).join(' | ') : ''}`);
ok(buildOk, 'assembleHap 整体成功（含签名打包）');

if (!buildOk) {
  console.log('');
  console.log('  ⚠ 完整构建未成功，但**编译阶段已通过** —— 下面是与编译无关的失败（通常是签名/打包环境）：');
  for (const l of out.split('\n').filter((x) => /ERROR|Error Code|ENOENT/.test(x)).slice(0, 8)) {
    console.log('    ' + l.trim());
  }
}
console.log('');
console.log(`RESULT: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
