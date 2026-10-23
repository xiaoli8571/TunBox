#!/usr/bin/env node
/**
 * 「单节点」虚拟分组退场自检（Single-Node Group Removal Gate）
 *
 * ## 用户口径（2026-10-22）
 *
 * 订阅页「添加订阅 → URL」只收**订阅地址**；单节点链接一律拒绝，并提示用户去
 * 「设置 → 订阅转换」生成 YAML 再以文件方式导入。旧版的「单节点」虚拟分组
 * （`DIRECT_GROUP_ID = 'direct'`）随之整体退场：不再创建、不再展示，
 * 旧版本遗留的直链节点在启动时清理（否则界面看不见、内核配置里却有）。
 *
 * ## 本闸门守什么
 *
 *   A. 服务层：没有 `addDirectNode` / `addDirectNodesText` / `syncDirectGroup` /
 *      `DirectBatchResult` / `DIRECT_GROUP_NAME`；有 `purgeDirectGroup()`，且
 *      init 会调用它并把结果计入 persist 条件。
 *   B. 页面：URL 输入路径里有「拒绝单节点 + 指向订阅转换」的分支；
 *      没有 `importNodeUris` / `addDirectNodesText` 调用；扫码提示同样指向订阅转换。
 *   C. 负对照（`--self-test`）：把拒绝分支删掉 / 把清理逻辑删掉，闸门必须变红。
 *
 * 跑法：
 *   node scripts/verify-single-node-removal.mjs
 *   node scripts/verify-single-node-removal.mjs --self-test
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const serviceFile = path.join(root, 'entry/src/main/ets/commons/services/SubscriptionService.ets');
const pageFile = path.join(root, 'entry/src/main/ets/pages/SubscriptionPage.ets');

let passed = 0;
let failed = 0;
const lines = [];

function ok(condition, message, actual) {
  if (condition) {
    passed += 1;
    return;
  }
  failed += 1;
  lines.push(`  ❌ ${message}${actual === undefined ? '' : ` —— ${actual}`}`);
}

/** 去掉注释行，避免「注释里提到」被当成「代码里还在用」 */
function codeOnly(text) {
  return text.split(/\r?\n/)
    .filter((line) => {
      const t = line.trim();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');
}

function runChecks(serviceSrc, pageSrc) {
  const service = codeOnly(serviceSrc);
  const page = codeOnly(pageSrc);

  // ── A. 服务层：生产者全部退场，只留清理 ──────────────────────────────────
  ok(!/async addDirectNode\(/.test(service), '服务层不再有 addDirectNode（单节点直链导入）');
  ok(!/addDirectNodesText\(/.test(service), '服务层不再有 addDirectNodesText（批量直链导入）');
  ok(!/syncDirectGroup\(/.test(service), '服务层不再有 syncDirectGroup（虚拟分组计数同步）');
  ok(!/class DirectBatchResult/.test(service), '服务层不再有 DirectBatchResult（批量结果类型）');
  ok(!/DIRECT_GROUP_NAME/.test(service), '服务层不再有 DIRECT_GROUP_NAME（"单节点" 名称）');
  ok(!/DIRECT_GROUP_URL/.test(service), '服务层不再有 DIRECT_GROUP_URL（local://direct 占位地址）');
  ok(/private purgeDirectGroup\(\): boolean/.test(service),
    '服务层有 purgeDirectGroup()：启动时清理旧版直链节点与虚拟分组');
  ok(/const purgedDirectGroup = this\.purgeDirectGroup\(\)/.test(service),
    'init 调用 purgeDirectGroup()');
  ok(/renamed \|\| purgedDirectGroup/.test(service),
    '清理结果计入 persist 条件（否则清理只在内存里，重启又回来）');
  ok(!/Subscription\.newSubscription\(DIRECT_GROUP_ID/.test(service),
    'init 不再创建「单节点」虚拟分组');
  // 常量本身保留（历史数据清理要用），但必须写明只剩清理用途
  ok(/export const DIRECT_GROUP_ID = 'direct'/.test(service), 'DIRECT_GROUP_ID 常量保留（用于清理历史数据）');

  // ── B. 页面：URL 输入拒绝单节点，指向订阅转换 ────────────────────────────
  ok(!/addDirectNodesText/.test(page), '页面不再调用 addDirectNodesText');
  ok(!/importNodeUris/.test(page), '页面不再有 importNodeUris（节点链接导入方法）');
  ok(/SubscriptionService\.isNodeUri\(l\)/.test(page),
    'URL 输入按行识别单节点链接（isNodeUri）');
  ok(/单节点链接不支持在这里添加/.test(page),
    'URL 输入拒绝单节点链接，并给出可行动提示');
  ok(/设置 → 订阅转换/.test(page), '提示里指向「设置 → 订阅转换」');
  ok(/扫码只支持 Clash 订阅二维码/.test(page) && /设置 → 订阅转换/.test(page),
    '扫码提示同样指向订阅转换（不再说「+ → URL 里粘贴」）');
  // 订阅地址分支必须还在：拒绝单节点不能顺手把订阅 URL 也拒了
  ok(/isValidSubscriptionUrl\(raw/.test(page), '订阅地址校验分支仍在（拒绝单节点不等于拒绝订阅）');
  ok(/this\.service\.addSubscription\(/.test(page), '订阅添加路径仍在');
}

function selfTest(serviceSrc, pageSrc) {
  const cases = [
    {
      name: 'URL 输入重新接受单节点（拒绝分支被删）',
      run: () => runChecks(serviceSrc,
        pageSrc.replace(/const hasNodeUri = [\s\S]*?\n    \}\n/, ''))
    },
    {
      name: '启动时不再清理旧版直链节点（purgeDirectGroup 调用被删）',
      run: () => runChecks(
        serviceSrc.replace('const purgedDirectGroup = this.purgeDirectGroup();', ''),
        pageSrc)
    },
    {
      name: '「单节点」虚拟分组重新被创建（newSubscription(DIRECT_GROUP_ID) 回来）',
      run: () => runChecks(
        serviceSrc.replace('const purgedDirectGroup = this.purgeDirectGroup();',
          'const purgedDirectGroup = this.purgeDirectGroup();\n'
          + '    this.subscriptions.unshift(Subscription.newSubscription(DIRECT_GROUP_ID, \'单节点\', \'local://direct\'));'),
        pageSrc)
    }
  ];
  let allCaught = true;
  for (const testCase of cases) {
    const beforePassed = passed;
    const beforeFailed = failed;
    const beforeLines = lines.length;
    testCase.run();
    const caught = failed > beforeFailed;
    console.log(`  · ${testCase.name} → 闸门判决 ${passed - beforePassed} passed, ${failed - beforeFailed} failed`);
    console.log(caught ? '    ✅ 被抓住' : '    ❌ 没被抓住（闸门对这个改坏不敏感）');
    if (!caught) {
      allCaught = false;
    }
    passed = beforePassed;
    failed = beforeFailed;
    lines.length = beforeLines;
  }
  return allCaught;
}

function main() {
  const withSelfTest = process.argv.includes('--self-test');
  const serviceSrc = fs.readFileSync(serviceFile, 'utf8');
  const pageSrc = fs.readFileSync(pageFile, 'utf8');
  console.log('── 「单节点」虚拟分组退场自检（URL 输入 + 启动清理）──');
  runChecks(serviceSrc, pageSrc);
  console.log(`  断言：${passed} passed, ${failed} failed`);
  if (failed > 0) {
    for (const line of lines) {
      console.log(line);
    }
  }
  let selfTestOk = true;
  if (withSelfTest) {
    console.log('');
    console.log('── 负对照（故意改坏源码，闸门必须 FAILED）──');
    selfTestOk = selfTest(serviceSrc, pageSrc);
  }
  console.log('');
  console.log(`PASSED=${passed} FAILED=${failed} TOTAL=${passed + failed}`);
  console.log(`RESULT: ${failed === 0 && selfTestOk ? 'SINGLE-NODE REMOVAL PASSED' : 'SINGLE-NODE REMOVAL FAILED'}`);
  process.exit(failed === 0 && selfTestOk ? 0 : 1);
}

main();
