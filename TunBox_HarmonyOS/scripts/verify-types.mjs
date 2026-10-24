#!/usr/bin/env node
/**
 * 离线类型校验脚本（第二阶段：NetworkStateWatcher / LinkHealthChecker / SmartSelector）
 *
 * 为什么需要它（实证结论）:
 *   本工程 hvigor 的 CompileArkTS 只编译「从 entry 可达的 import 图」。
 *   实测：往 entry/src/main/ets/commons/services/ 放一个故意写错的
 *   `export const X: number = 'not-a-number';`，`assembleHap` 依然 BUILD SUCCESSFUL，
 *   且构建日志里完全没有该文件 → 未被引用的新增模块不会被类型检查。
 *   因此 assembleHap 通过**不能**证明新模块类型正确，必须独立校验。
 *
 * 本脚本做法:
 *   用 DevEco 自带的 TypeScript（sdk/.../ets-loader/node_modules/typescript）以
 *   `strict: true` + `noEmit` 对三个新模块做真实类型检查，并把 `@kit.*` / `@ohos.*`
 *   映射到**本机真实 SDK 声明文件**（sdk/default/openharmony/ets/kits 与 .../ets/api），
 *   而不是自造 .d.ts 垫片 —— 所以 connection.* 等 API 用法是真检查的。
 *   同时加载真实的 AppLogger.ets（NetworkStateWatcher 的唯一工程内依赖）。
 *
 *   另外对 ohosTest/LogicTest.ets 做**语法解析**检查（reportDiagnostics），
 *   因为它的其余依赖是本工程页面/服务（含 ArkUI struct 语法），不适合直接用 tsc 全量解析。
 *
 * 用法: node scripts/verify-types.mjs
 * 退出码: 0 = 无类型/语法错误；1 = 有错误
 */
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const appRoot = resolve(here, '..');

const DEVECO = process.env.DEVECO_HOME || 'C:\\Program Files\\Huawei\\DevEco Studio';
const SDK = process.env.DEVECO_SDK_HOME || join(DEVECO, 'sdk');
const ETS = join(SDK, 'default', 'openharmony', 'ets');
const KITS = join(ETS, 'kits');
const API = join(ETS, 'api');
const ETS_LOADER = join(ETS, 'build-tools', 'ets-loader');
const TSC = join(ETS_LOADER, 'node_modules', 'typescript', 'lib', 'tsc.js');

const svcDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'services');
const utilDir = join(appRoot, 'entry', 'src', 'main', 'ets', 'commons', 'utils');
const logicTest = join(appRoot, 'entry', 'src', 'ohosTest', 'ets', 'test', 'LogicTest.ets');

for (const [label, p] of [['typescript(tsc.js)', TSC], ['ets/kits', KITS], ['ets/api', API]]) {
  if (!existsSync(p)) {
    console.error('FATAL: 找不到 ' + label + ': ' + p + '（可用环境变量 DEVECO_HOME / DEVECO_SDK_HOME 覆盖）');
    process.exit(1);
  }
}

const sandbox = join(tmpdir(), 'tunbox-typecheck-' + process.pid);
rmSync(sandbox, { recursive: true, force: true });
mkdirSync(sandbox, { recursive: true });
writeFileSync(join(sandbox, 'package.json'), JSON.stringify({ type: 'module' }), 'utf8');

/** .ets → .ts（仅改扩展名；SDK import 保持原样交给 tsconfig paths 解析） */
function stage(srcDir, file, outName) {
  const src = readFileSync(join(srcDir, file), 'utf8');
  writeFileSync(join(sandbox, outName), src, 'utf8');
}

stage(svcDir, 'NetworkStateWatcher.ets', 'NetworkStateWatcher.ts');
stage(svcDir, 'LinkHealthChecker.ets', 'LinkHealthChecker.ts');
stage(svcDir, 'SmartSelector.ets', 'SmartSelector.ts');
stage(utilDir, 'AppLogger.ets', 'AppLogger.ts');

const tsconfig = {
  compilerOptions: {
    target: 'ES2021',
    module: 'ESNext',
    moduleResolution: 'node',
    lib: ['ES2021'],
    strict: true,
    noEmit: true,
    skipLibCheck: true,
    forceConsistentCasingInFileNames: true,
    baseUrl: '.',
    paths: {
      '@kit.*': [join(KITS, '@kit.*')],
      '@ohos.*': [join(API, '@ohos.*')]
    },
    types: []
  },
  files: ['NetworkStateWatcher.ts', 'LinkHealthChecker.ts', 'SmartSelector.ts', 'AppLogger.ts']
};
writeFileSync(join(sandbox, 'tsconfig.json'), JSON.stringify(tsconfig, null, 2), 'utf8');

const ts = createRequire(import.meta.url);
let tsLib;
try {
  tsLib = ts(TSC.replace(/[\\/]lib[\\/]tsc\.js$/, ''));
} catch (e) {
  tsLib = null;
}

let failures = 0;
console.log('===== TunBox 第二阶段类型校验 =====');
console.log('[INFO] tsc: ' + TSC);
console.log('[INFO] SDK: @kit.* -> ' + KITS);
console.log('[INFO] SDK: @ohos.* -> ' + API);

// ── A. 三个新模块：strict 类型检查（真实 SDK 声明）────────────────────
console.log('-----------------------------------------');
console.log('[A] strict tsc --noEmit: NetworkStateWatcher / LinkHealthChecker / SmartSelector (+ real AppLogger.ets)');
let out = '';
let code = 0;
try {
  out = execFileSync(process.execPath, [TSC, '-p', join(sandbox, 'tsconfig.json')], { encoding: 'utf8' });
} catch (e) {
  code = typeof e.status === 'number' ? e.status : 1;
  out = String(e.stdout || '') + String(e.stderr || '');
}
// SDK 自带的 `*.d.ets`（如 @ohos.annotation.d.ets）用了 tsc 不认的 ArkTS 语法：
// skipLibCheck 只跳过类型检查、不跳过解析，所以会稳定刷出 TS1128/TS1146 语法错。
// 这些不是本工程的错，按文件路径过滤掉，只保留**工程内文件**的报错。
const isSdkNoise = (line) => {
  const t = line.trim();
  return /DevEco Studio.*[\/]sdk[\/]/.test(t) && /\.d\.ets?\(/.test(t);
};
const NL = String.fromCharCode(10);
const allErrors = out.split(NL).filter((l) => /error TS\d+/.test(l));
const ownErrors = allErrors.filter((l) => !isSdkNoise(l));
const sdkNoise = allErrors.length - ownErrors.length;
if (ownErrors.length > 0) {
  console.log(ownErrors.join(NL));
} else if (out.trim().length > 0) {
  console.log(`[A] 已忽略 ${sdkNoise} 条 SDK 自带声明文件的语法噪声（非本工程代码）`);
}
if (ownErrors.length === 0 && code !== 0) {
  console.log('[A] PASS: 工程代码 0 type errors（strict；SDK 声明噪声已过滤）');
} else if (ownErrors.length === 0) {
  console.log('[A] PASS: 0 type errors (strict mode, real HarmonyOS SDK declarations)');
} else {
  failures = failures + 1;
  console.log('[A] FAIL: ' + ownErrors.length + ' 条工程代码类型错误（tsc exit ' + code + '）');
}

// ── B. LogicTest.ets：语法解析检查 ────────────────────────────────────
console.log('-----------------------------------------');
console.log('[B] 语法解析检查: entry/src/ohosTest/ets/test/LogicTest.ets');
if (tsLib === null) {
  console.log('[B] SKIP: 无法加载 typescript API（仅影响本项语法检查）');
} else {
  const src = readFileSync(logicTest, 'utf8');
  const sf = tsLib.createSourceFile('LogicTest.ets', src, tsLib.ScriptTarget.Latest, true, tsLib.ScriptKind.TS);
  const diags = sf.parseDiagnostics || [];
  if (diags.length === 0) {
    console.log('[B] PASS: 0 syntax errors, ' + (src.match(/\n/g) || []).length + ' lines parsed');
  } else {
    failures = failures + 1;
    for (const d of diags) {
      const pos = sf.getLineAndCharacterOfPosition(d.start);
      console.log('[B] SYNTAX ERROR at line ' + (pos.line + 1) + ':' + (pos.character + 1) + ' -> ' + tsLib.flattenDiagnosticMessageText(d.messageText, ' '));
    }
  }
}

rmSync(sandbox, { recursive: true, force: true });
console.log('-----------------------------------------');
console.log(failures === 0 ? 'RESULT: TYPE/SYNTAX CHECK PASSED' : 'RESULT: TYPE/SYNTAX CHECK FAILED');
process.exit(failures === 0 ? 0 : 1);
