#!/usr/bin/env node
/**
 * 检查已构建的 UI 资源编号，防止增量编译缓存沿用旧编号而显示其他图标。
 * 2026-10-23：530 中电源引用 ic_nodes、主页引用 ic_chevron_down（编译缓存与 ResourceTable 错位）。
 * 必须在真正编译过之后运行；没有 compile 产物时明确 SKIP，不假装通过。
 *
 * 注意：CompileArkTS 的产物按模式分目录（esmodule/debug 与 esmodule/release）。
 * 只查 debug 会让 release 包的错位漏检，反之亦然；因此所有存在的模式目录都必须通过。
 */
import { existsSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const build = resolve(root, 'entry/build/default');
const tablePath = resolve(build, 'intermediates/res/default/ResourceTable.txt');
const modes = ['release', 'debug']
  .map((mode) => ({ mode, dir: resolve(build, `cache/default/default@CompileArkTS/esmodule/${mode}/entry/src/main/ets/components`) }))
  .filter((entry) => existsSync(entry.dir));

if (!existsSync(tablePath) || modes.length === 0) {
  console.log('SKIP UI resource bindings: 尚未编译（先 assembleHap/assembleApp，再运行本门禁）');
  process.exit(0);
}

let failed = false;
let checked = 0;
function check(label, name, actual, table) {
  const expected = table.get(name);
  if (expected === undefined || actual !== expected) {
    console.error(`FAIL ${label}: ${name} compiled=${actual} table=${expected}; run a clean build`);
    failed = true;
  } else {
    console.log(`PASS ${label}: ${name}=${actual}`);
  }
}
try {
  const table = new Map([...readFileSync(tablePath, 'utf8')
    .matchAll(/^media\s+(\w+)\s+(0x[\da-f]+)\s*$/gmi)]
    .map((m) => [m[1], Number(m[2])]));
  const dockSource = readFileSync(resolve(root, 'entry/src/main/ets/components/FloatingBottomBar.ets'), 'utf8');
  const tabs = [...dockSource.matchAll(/title:\s*'([^']+)'\s*,\s*icon:\s*\$r\('app\.media\.(\w+)'\)/g)];
  if (tabs.length !== 3) throw new Error('Cannot identify the three navigation resource references');
  const powerSource = readFileSync(resolve(root, 'entry/src/main/ets/components/CelestialPowerOrb.ets'), 'utf8');
  const powerRefs = [...powerSource.matchAll(/Image\(\$r\('app\.media\.(\w+)'\)\)/g)];
  if (powerRefs.length !== 1) throw new Error('Cannot identify the power resource reference');

  for (const { mode, dir } of modes) {
    const dockPath = resolve(dir, 'FloatingBottomBar.ts');
    const powerPath = resolve(dir, 'CelestialPowerOrb.ts');
    if (!existsSync(dockPath) || !existsSync(powerPath)) {
      console.error(`FAIL [${mode}]: 编译产物缺少 FloatingBottomBar/CelestialPowerOrb`);
      failed = true;
      continue;
    }
    const dockCompiled = readFileSync(dockPath, 'utf8');
    for (const [, title, name] of tabs) {
      const escaped = title.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const match = dockCompiled.match(new RegExp(`title:\\s*'${escaped}'\\s*,\\s*icon:\\s*\\{\\s*"id":\\s*(\\d+)`));
      check(`${title}[${mode}]`, name, match ? Number(match[1]) : undefined, table);
      checked++;
    }
    const powerCompiled = readFileSync(powerPath, 'utf8');
    const powerImages = [...powerCompiled.matchAll(/Image\.create\(\{\s*"id":\s*(\d+)\s*,\s*"type":\s*20000/g)];
    if (powerImages.length !== 1) {
      console.error(`FAIL [${mode}]: 电源按钮编译产物中媒体引用数量=${powerImages.length}`);
      failed = true;
      continue;
    }
    check(`电源[${mode}]`, powerRefs[0][1], Number(powerImages[0][1]), table);
    checked++;
  }
  if (checked === 0) throw new Error('没有任何模式目录被实际校验');
} catch (error) {
  console.error(`FAIL UI resource bindings: ${error.message}`);
  failed = true;
}
process.exitCode = failed ? 1 : 0;
