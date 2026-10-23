#!/usr/bin/env node
/**
 * 一键回归门禁：跑完 `scripts/verify-*.mjs` 全部脚本，给出统一结论。
 *
 * ## 为什么需要它（2026-10-19 复盘）
 *
 * 0.4.0 的两个真实事故都**不是**"没有测试"，而是"没有一处能一次跑完的门禁"：
 *   · 公网 IP 链路没有代次保护 → 晚到的失败覆盖正确结果（无任何断言守着）；
 *   · 发布包由脏工作区构建 → 任何 commit 都复现不出，出问题无法定位。
 * 同时还有 4 个脚本在 0.4.0 基线就已常年红，真正回归被噪音掩盖。
 *
 * 本脚本把「全部脚本 + 已知基线失败白名单」收成一条命令，并在最后显式打印
 * **白名单里每一项为什么允许失败**——白名单不是"忽略"，是"已核实的既有缺陷"。
 *
 * ## 用法
 *
 *   node scripts/verify-all.mjs                       # 跑全部（需要 HAP 的脚本用 dist 里最新的）
 *   node scripts/verify-all.mjs --hap <path.hap>      # 显式指定 HAP 给 verify-shipped-dns-fix
 *   node scripts/verify-all.mjs --strict              # 白名单也要求通过（发布前最终闸门）
 *   node scripts/verify-all.mjs --only public-ip,connect  # 只跑名字含关键字的
 *
 * ## 退出码
 *   0 = 除白名单外的脚本全部通过
 *   1 = 有白名单外的脚本失败（或 --strict 下白名单项失败）
 */
import { readdirSync, existsSync, statSync } from 'node:fs';
import { join, dirname, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const project = resolve(here, '..');
const repoRoot = resolve(project, '..');
const scriptsDir = here;

/**
 * 已知基线失败白名单。
 *
 * 每一项都**在本仓库 HEAD 的历史版本上复跑确认过同样失败**（不是本次改动引入），
 * 因此不阻塞发布；但也不允许悄悄扩大——新增条目必须在注释里写清原因与复现命令。
 */
const KNOWN_BASELINE_FAILURES = {
  'verify-types.mjs': {
    reason: 'SDK 自带的 @ohos.annotation.d.ets 用了 tsc 不认的语法，属于 SDK 缺陷而非本仓库代码问题；'
      + '[B] 段（真实源码语法解析）是通过的',
    howToConfirm: 'node scripts/verify-types.mjs 在任何历史版本上都报同样的 @ohos.annotation.d.ets TS1128/TS1146/TS1434'
  },
  'verify-subscription-fidelity.mjs': {
    reason: '需要真实订阅 fixture（test/fixtures/real-subscription.yaml），仓库不含该文件；'
      + '脚本按设计在"没跑"时返回失败，避免把"没验证"当成"通过"',
    howToConfirm: '无 fixture 时脚本自身打印「0 passed, 0 failed, 0 run — 视为失败」'
  },
  // 2026-10-20：旧实现清退闸门**已达成**（LP01..LP13 全绿，LP14/LP15 为永久豁免）
  // ⇒ 已从白名单里删除，不再豁免。
};

/** 需要额外参数的脚本：给它们准备好参数，否则它们会因为"用法错误"失败。 */
const ARG_BUILDERS = {
  'verify-shipped-dns-fix.mjs': (hap) => (hap === null ? null : [hap]),
  'verify-flclash-profile.mjs': (_hap, args) => (args.strict ? ['--require-mihomo'] : []),
  'verify-smart-active-chains.mjs': () => [] // 无设备时脚本自身会打印 SKIP 并 exit 0
};

function parseArgs(argv) {
  const out = { hap: null, strict: false, only: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--strict') { out.strict = true; continue; }
    if (a === '--hap') { out.hap = argv[++i] ?? null; continue; }
    if (a === '--only') {
      out.only = (argv[++i] ?? '').split(',').map((s) => s.trim()).filter((s) => s.length > 0);
      continue;
    }
    if (a === '-h' || a === '--help') {
      console.log('用法: node scripts/verify-all.mjs [--hap <path.hap>] [--strict] [--only a,b]');
      process.exit(0);
    }
  }
  return out;
}

/** dist 下最新的 .hap（按 mtime），找不到返回 null。 */
function newestHap() {
  const dist = join(repoRoot, 'dist');
  if (!existsSync(dist)) {
    return null;
  }
  const haps = readdirSync(dist)
    .filter((n) => n.endsWith('.hap'))
    .map((n) => join(dist, n))
    .filter((p) => {
      try { return statSync(p).isFile(); } catch (e) { return false; }
    })
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
  return haps.length > 0 ? haps[0] : null;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const hap = args.hap ?? newestHap();

  let scripts = readdirSync(scriptsDir)
    .filter((n) => /^verify-.*\.mjs$/.test(n))
    .filter((n) => n !== 'verify-all.mjs')
    .sort();
  if (args.only !== null) {
    scripts = scripts.filter((n) => args.only.some((k) => n.includes(k)));
  }

  console.log('===== TunBox 回归门禁 =====');
  console.log(`工程: ${project}`);
  console.log(`HAP : ${hap ?? '(未找到 dist/*.hap；verify-shipped-dns-fix 将记为跳过)'}`);
  console.log(`模式: ${args.strict ? 'strict（白名单也要求通过）' : 'normal（白名单允许既有失败）'}`);
  console.log(`脚本: ${scripts.length} 个`);
  console.log('');

  const results = [];
  for (const name of scripts) {
    const extra = ARG_BUILDERS[name] !== undefined ? ARG_BUILDERS[name](hap, args) : [];
    if (extra === null) {
      results.push({ name, code: 0, skipped: true, tail: '未提供 HAP，跳过' });
      console.log(`SKIP ${name}（未提供 HAP）`);
      continue;
    }
    const r = spawnSync(process.execPath, [join(scriptsDir, name), ...extra], {
      cwd: project,
      encoding: 'utf8',
      maxBuffer: 32 * 1024 * 1024
    });
    const stdout = (r.stdout ?? '') + (r.stderr ?? '');
    const tail = stdout.trim().split('\n').slice(-3).join(' | ').slice(0, 200);
    results.push({ name, code: r.status ?? 1, skipped: false, tail });
    console.log(`${r.status === 0 ? 'PASS' : 'FAIL'} ${name}`);
  }

  const failed = results.filter((r) => !r.skipped && r.code !== 0);
  const whitelisted = failed.filter((r) => KNOWN_BASELINE_FAILURES[r.name] !== undefined);
  const realFailures = failed.filter((r) => KNOWN_BASELINE_FAILURES[r.name] === undefined);

  console.log('');
  console.log('-----------------------------------------');
  console.log(`PASS=${results.filter((r) => r.skipped || r.code === 0).length}`
    + ` FAIL=${failed.length}`
    + ` (白名单 ${whitelisted.length} / 真失败 ${realFailures.length})`
    + ` SKIP=${results.filter((r) => r.skipped).length}`);

  if (whitelisted.length > 0) {
    console.log('');
    console.log('已知基线失败（不阻塞，但每项都有核实记录）：');
    for (const r of whitelisted) {
      console.log(`  · ${r.name}`);
      console.log(`      原因: ${KNOWN_BASELINE_FAILURES[r.name].reason}`);
      console.log(`      复核: ${KNOWN_BASELINE_FAILURES[r.name].howToConfirm}`);
    }
  }

  if (realFailures.length > 0) {
    console.log('');
    console.log('真实失败（必须修）：');
    for (const r of realFailures) {
      console.log(`  ✗ ${r.name}`);
      console.log(`      ${r.tail}`);
    }
  }

  if (args.strict && whitelisted.length > 0) {
    console.log('');
    console.log('RESULT: STRICT 模式下白名单项也失败 —— 发布前必须先解决');
    process.exitCode = 1;
    return;
  }
  if (realFailures.length > 0) {
    console.log('');
    console.log('RESULT: 存在真实失败 —— 不得发布');
    process.exitCode = 1;
    return;
  }
  console.log('');
  console.log('RESULT: 全部通过（白名单项已核实为既有缺陷）');
  process.exitCode = 0;
}

main();
