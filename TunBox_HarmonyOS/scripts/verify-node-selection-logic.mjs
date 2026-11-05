#!/usr/bin/env node
/**
 * 「选了 A 节点、连上却走 B 节点」回归门禁（2026-10-28）。
 *
 * ## 用户报障原文
 *   切换订阅 + 手动指定节点 → 正常；
 *   **在当前订阅内改选节点** → 程序一直用「切订阅时第一次选中的节点」；
 *   只有在**已连接状态下**在线切换节点才生效。
 *
 * ## 根因（两处，都在这条链上）
 *   ① `ConnectionOrchestrator` 连接阶段用 `leaf === target.name` **逐字节**比较内核
 *      成员名 → App 侧名字与内核名差一个 emoji/空格就判「用户选的不在主组里」，
 *      于是落进「认内核 `now` 旧出口」分支（store-selected 记的就是上次那个节点）。
 *   ② 钉选 PUT 目标若不在规则组**成员表**里（机场只列一部分节点），内核必 400；
 *      旧实现静默换成「组内首个叶子」，用户看到的就是「香港 → 日本」。
 *
 * ## 本脚本守的三条不变量
 *   A. 意图落地判定：命中必须走**精确名**比较，且「替身」（地区自愈/组内首叶子）
 *      一律 `matched = false`，不得被当成用户意图。
 *   B. 优先级：**用户意图 > 内核旧出口**。认内核 `now` 只允许在「没有可用意图」时；
 *      认了之后回写偏好也只允许在「用户本就没选」时 —— 否则 App 会静默改勾选。
 *   C.（已删除）成员注入是自造行为，FlClash 照抄后不复存在 —— 选点=内核成员表精确名，
 *      里但不在规则组成员表时，把它补进组首位；补不进去必须原样返回（绝不交出坏
 *      YAML：内核对同层重复键是整份拒载）。
 *
 * 跑法：node scripts/verify-node-selection-logic.mjs（退出码 0 = 全绿）
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');

// .ets 含 enum，Node 的类型剥离模式不支持 → 自带旗重启（与其它 verify 脚本一致）
if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_NSL_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_NSL_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

let pass = 0;
let fail = 0;
function ok(name, cond, detail) {
  if (cond) {
    pass++;
    console.log(`  ✅ ${name}`);
  } else {
    fail++;
    console.log(`  ❌ ${name}${detail ? `\n       ${detail}` : ''}`);
  }
}
function section(t) { console.log(`\n${t}`); }

const ETS = path.join(root, 'entry', 'src', 'main', 'ets');
const read = (rel) => fs.readFileSync(path.join(ETS, rel), 'utf8');

// ── A. 静态不变量（源码契约）───────────────────────────────────────────────
section('A. 连接路径的意图判定（源码契约）');

const ORCH = 'commons/services/ConnectionOrchestrator.ets';
const BUILDER = 'commons/config/RuntimeConfigBuilder.ets';
const MERGER = 'commons/tunbox/ProfileConfigMerger.ets';
const orch = read(ORCH);
const builder = read(BUILDER);
const merger = read(MERGER);

ok('A1 内核成员名不再逐字节比较（禁止 `leaf === target.name`）',
  !/leaf\s*===\s*target\.name/.test(orch),
  '发现逐字节比较：emoji/空格差异会误判「用户选的节点不在组里」');

ok('A2 命中内核成员走 RuntimeConfigBuilder.kernelLeafFor',
  orch.includes('RuntimeConfigBuilder.kernelLeafFor('),
  '缺少归一化命中入口');

ok('A3 kernelLeafFor 精确匹配，未命中返回空串',
  /static kernelLeafFor\(members: string\[\], preferred: string\): string \{[\s\S]*?if \(m === want\)[\s\S]*?return '';\s*\}/.test(builder)
    && !builder.slice(builder.indexOf('static kernelLeafFor('),builder.indexOf('static proxyNameInYaml(')).includes('nodeKey('),
  '内核名称不能通过地区/emoji 归一化替换');

ok('A4 ConnectionTarget 暴露 matched（意图是否落地）',
  /matched: boolean = false;/.test(builder) && /out\.matched = preferred\.length > 0/.test(builder),
  'resolvePinTarget 未标注 matched');

ok('A5 RuntimeConfigResult 暴露 pinMatched 并真实赋值',
  /pinMatched: boolean = false;/.test(builder) && /result\.pinMatched = resolvedPin\.matched;/.test(builder),
  'pinMatched 缺失或未赋值');

ok('A6 替身（地区自愈/组内首叶子）不得判为 matched',
  /out\.matched = preferred\.length > 0 && out\.nodeName === preferred;/.test(builder),
  'matched 必须精确名判等，不能因「同地区」就置 true');

section('B. 优先级：用户意图 > 内核旧出口');

ok('B1 intentLive 来自 built.pinMatched',
  /const intentLive: boolean = built\.pinMatched && target\.name\.length > 0;/.test(orch),
  '缺少 intentLive 判定');

ok('B2 认内核 now 的分支带 !intentLive 闸门',
  /if \(!pinned && !intentLive && kernelSel !== null && kernelSel\.nowIsLeaf\)/.test(orch),
  '认内核旧出口必须先确认「没有可用用户意图」');

ok('B3 显式钉选（pinTargetName）排在认内核之前',
  orch.indexOf('await this.api.selectNodeInGroup(startupGroupName, pinTargetName, selectionCurrent)') > 0
    && orch.indexOf('await this.api.selectNodeInGroup(startupGroupName, pinTargetName, selectionCurrent)')
      < orch.indexOf('adoptedByKernel = true'),
  '顺序错误：内核旧出口会盖掉本次用户选择');

ok('B4 认内核后回写偏好只在「用户没选」时',
  /adoptedByKernel && target\.name\.length === 0/.test(orch),
  '有偏好时会静默改掉勾选');

ok('B5 候选兜底回写偏好带 !intentLive 闸门',
  /if \(!intentLive\) \{\s*try \{\s*await SettingsService\.patchSettings/.test(orch)
  || /if \(!intentLive\) \{\n\s*try \{\n\s*await SettingsService\.patchSettings/.test(orch),
  '缺 !intentLive 闸门：钉不上候选节点时会覆盖用户选择');

ok('B6 偏好自愈仅限自动模式的未命中目标',
  /if \(built\.smartGroupName\.length === 0 && effectiveName !== target\.name && !built\.pinMatched\s*&& settings\.autoSelectMode === AutoSelectModes\.AUTO\)/.test(orch),
  '手动选择或意图还在配置里时不得改写偏好');

section(`\n结果：${pass} 通过 / ${fail} 失败`);
process.exit(fail === 0 ? 0 : 1);
