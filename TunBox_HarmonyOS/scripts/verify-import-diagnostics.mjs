#!/usr/bin/env node
/**
 * 失败原因透传闸门（Import Diagnostics Gate）
 *
 * ## 为什么要有这道闸门
 *
 * 用户反复报「导入失败 / 订阅解析失败 / 刷新失败 / 测速失败」。核对代码后确认：
 * 判词其实**已经算出来了**（空响应字节数、校验失败原因、HTTP 状态码、BusinessError code），
 * 但三个 catch 分支把它丢掉，只弹一句通用文案：
 *
 *   · `importYamlFile`      → `导入失败，请重试`
 *   · `importFromConvert`   → `转换或导入失败，请重试`
 *   · `refreshOne`          → `刷新失败：<订阅名>`（message/advice 都不展示）
 *   · `refreshAll`          → 无条件 `✓ 全部订阅已刷新`（全失败也报成功）
 *
 * 后果：用户无法自查，只能反复重试；支持方也拿不到可复现的判词。
 * 本闸门同时钉住「原因必须到达用户」与「原因的单点实现」，并防止有人把
 * 已定案的 Clash-only 订阅口径顺手放开（那是产品定案，不属于本批）。
 *
 * ## 断言
 *
 *   A. `ImportFailureSummary` 行为：空白归一、限长加省略号、无原因不留分隔符
 *   B. 三个入口都引用单点实现，且失败分支不再出现通用文案
 *   C. `refreshAll` 按失败集合统计，不再无条件成功
 *   D. 本地导入的扩展名/文件名/节点数口径
 *   E. 负对照：Clash-only 守卫仍在（`isClashBody` + `NON_CLASH_ADVICE`）
 *
 * 退出码：0 = 全过；1 = 有断言失败。
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const src = path.join(root, 'entry/src/main/ets');
const read = (p) => fs.readFileSync(path.join(src, p), 'utf8');

let passed = 0;
const failures = [];
function ok(name, condition) {
  if (condition) {
    passed += 1;
    console.log(`PASS ${name}`);
  } else {
    failures.push(name);
    console.log(`FAIL ${name}`);
  }
}

// ── A. 单点实现的行为（执行生产 .ets，纯函数无 kit 依赖）────────────────
const ctx = vm.createContext({ console });
const code = read('commons/services/ImportFailureSummary.ets')
  .replace(/^import\b[\s\S]*?;\r?\n/gm, '')
  .replace(/^export /gm, '');
const loaded = vm.runInContext(
  stripTypeScriptTypes(`(()=>{${code}\nreturn {ImportFailureSummary}})()`, { mode: 'transform' }), ctx);
const S = loaded.ImportFailureSummary;

ok('summary.empty', S.brief('') === '');
ok('summary.whitespace-normalised', S.brief(' a \n\t b ') === 'a b');
ok('summary.short-untouched', S.brief('x'.repeat(88)) === 'x'.repeat(88));
ok('summary.long-truncated', S.brief('x'.repeat(89)) === `${'x'.repeat(88)}…`);
ok('summary.line-without-reason', S.line('导入失败：a.yaml', '') === '导入失败：a.yaml');
ok('summary.line-with-reason', S.line('导入失败：a.yaml', '权限被拒') === '导入失败：a.yaml｜权限被拒');
ok('summary.line-collapses-newlines', S.line('导入失败', '第一行\n第二行') === '导入失败｜第一行 第二行');

// ── B. 入口接线 ────────────────────────────────────────────────────────
const section = read('components/SubscriptionSection.ets');
const service = read('commons/services/SubscriptionService.ets');

ok('wire.import-uses-summary', section.includes("ImportFailureSummary.line('导入失败', reason)"));
ok('wire.convert-uses-summary',
  section.includes("ImportFailureSummary.line(exportFile ? '导出失败' : '导入失败', reason)"));
ok('wire.refresh-uses-summary', section.includes('ImportFailureSummary.line(`刷新失败：${sub.name}`'));
ok('wire.refresh-carries-message',
  section.includes('result.message.length > 0 ? result.message : result.advice'));
ok('wire.no-generic-import-toast', !section.includes("this.toast('导入失败，请重试')"));
ok('wire.no-generic-convert-toast', !section.includes("this.toast(exportFile ? '转换或保存失败"));
ok('wire.import-catch-logs-reason', /yaml import failed: \$\{reason\}/.test(section));

// ── C. 刷新全部的真实统计 ─────────────────────────────────────────────
ok('wire.refresh-all-tracks-failures',
  section.includes('private refreshFailedIds: string[] = [];')
  && section.includes('this.refreshFailedIds.includes(sub.id)')
  && section.includes('刷新完成：${snapshot.length - failed} 成功，${failed} 失败'));

// ── D. 本地导入：内容判定、文件名、节点数口径 ─────────────────────────
// 2026-11-04 用户重新定义唯一边界（不得因省事造成导入异常）：
// 扩展名不再充当判定，`validateProfile` 同款管线才决定内容能不能进。
ok('wire.picker-content-decides',
  section.includes("opts.fileSuffixFilters = ['.yaml', '.yml', '.txt', '.conf'];"));
ok('wire.file-name-decoded', section.includes('const fileName: string = fileNameFromUri(uri);')
  && section.includes('return decodeURIComponent(raw);'));
ok('wire.provider-only-honest',
  section.includes('const parsedNodes: number = this.service.lastLocalImportNodes;')
  && section.includes('配置已导入 TunBox，节点将在加载订阅后显示'));
ok('service.exposes-local-node-count',
  service.includes('lastLocalImportNodes: number = 0;')
  && service.includes('this.lastLocalImportNodes = parsed.length;'));

// ── E. 产品定案不得被本批顺手放开 ─────────────────────────────────────
ok('decision.clash-only-guard-kept', service.includes('static isClashBody(body: string): boolean'));
ok('decision.clash-only-advice-kept', service.includes('NON_CLASH_ADVICE'));

console.log(`\n失败原因透传闸门：${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
  console.log(`FAILED: ${failures.join(', ')}`);
  process.exit(1);
}
