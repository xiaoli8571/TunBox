#!/usr/bin/env node
/**
 * NodeSelectionPage real-node card structure contract.
 * Checks the current two-row layout, protocol source, latency display and selection wiring.
 * Usage: node scripts/verify-sub-node-two-row.mjs [--file <path>]
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const argIdx = process.argv.indexOf('--file');
const file = argIdx >= 0 && process.argv[argIdx + 1]
  ? path.resolve(process.argv[argIdx + 1])
  : path.join(here, '..', 'entry', 'src', 'main', 'ets', 'pages', 'NodeSelectionPage.ets');
const src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');
const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
let pass = 0;
const fails = [];
function check(name, condition) {
  if (condition) { pass += 1; console.log(`  ✓ ${name}`); }
  else { fails.push(name); console.log(`  ✗ ${name}`); }
}
function blockAt(text, open) {
  let depth = 0;
  let quote = '';
  for (let i = open; i < text.length; i += 1) {
    const c = text[i];
    if (quote) {
      if (c === '\\') i += 1;
      else if (c === quote) quote = '';
      continue;
    }
    if (c === '"' || c === "'" || c === '`') { quote = c; continue; }
    if (c === '{') depth += 1;
    if (c === '}' && --depth === 0) return text.slice(open, i + 1);
  }
  return '';
}
function methodBody(name) {
  const re = new RegExp(`@Builder\\s+${name}\\([^\\n]*\\)\\s*\\{`);
  const match = re.exec(code);
  return match ? blockAt(code, match.index + match[0].length - 1) : '';
}

console.log(`\nNodeSelectionPage 节点卡片结构自检${argIdx >= 0 ? `（--file ${file}）` : ''}`);
check('源码存在且非空', code.length > 1000);
const card = methodBody('RealNodeCard');
check('RealNodeCard 可完整定位', card.length > 0 && card.length < 6000);
const rows = [...card.matchAll(/Row\(\{\s*space:\s*\d+\s*\}\)\s*\{/g)];
check('卡片包含名称/测速行与协议/状态行', rows.length >= 4);
const firstRow = rows.length >= 2 ? blockAt(card, rows[1].index + rows[1][0].lastIndexOf('{')) : '';
const secondRow = rows.length >= 4 ? blockAt(card, rows[3].index + rows[3][0].lastIndexOf('{')) : '';
check('名称行使用省略显示并占据弹性宽度', /Text\(NodeDisplay\.withoutLeadingFlag\(row\.node\.name\)\)[\s\S]*?\.layoutWeight\(1\)/.test(firstRow));
check('名称行有独立测速状态与重测操作', /LatencyStoreBridge\.stateFor\(row\.node\.name, this\.latencyContext\(row\.node\)\)/.test(firstRow) && /this\.testOne\(row\.node\)/.test(firstRow));
check('第二行调用统一协议展示 Builder', /this\.ProtocolText\(row\.node\)/.test(secondRow));
check('第二行展示测速状态徽标', /this\.NodeStatusBadge\(row\.status\)/.test(secondRow));
check('协议文本使用 NodeProtocolPolicy', /Text\(NodeProtocolPolicy\.fromNode\(node\)\.display\(\)\)/.test(methodBody('ProtocolText')));
check('选中节点由统一 onNodeTap 处理', /\.onClick\(\(\) => this\.onNodeTap\(row\.node\)\)/.test(card));
check('批量选择态渲染 SelectDot', /if \(this\.selectMode\)\s*\{\s*this\.SelectDot\(row\.node\.id\)/.test(card));
check('LatencyStoreBridge 是当前卡片测速来源', /LatencyStoreBridge\.recordFor\(row\.node\.name, this\.latencyContext\(row\.node\)\)/.test(card));
check('当前卡片不依赖已删除 nodeCard/旧延迟门面', !/nodePingText|nodePingColor|LatencyController|this\.nodeCard\(/.test(code));

let depth = 0;
for (const c of code) {
  if (c === '{') depth += 1;
  if (c === '}' && --depth < 0) break;
}
check('源码花括号数量配平', depth === 0);
console.log(`\n自检结果：${pass} 条通过，${fails.length} 条失败`);
if (fails.length) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（真实节点卡片当前两行行为契约）');
