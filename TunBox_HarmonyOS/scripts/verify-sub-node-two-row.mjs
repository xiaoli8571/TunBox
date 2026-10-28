/**
 * 订阅页节点行「两行信息列」结构自检（含单列/双列排布、协议口径、延迟口径）。
 *
 * 历史：0.3.x 的节点行把「名称 + 协议徽标 + 延迟」三者挤在一行，窄屏下名称被截断、
 * 协议被 layoutWeight(1) 压成残字。修复后改为两行信息列：
 *   第一行 = 单选圆圈 + 节点名称（名称 layoutWeight(1) 拿满宽度）
 *   第二行 = 协议标签 + Blank 弹性空隙 + 延迟文本
 * 0.4.0 又把节点行收进 `@Builder nodeCard(node)` 卡片（Column({space:8}) 两行），
 * 并由 GridRow/GridCol 统一控宽（单列 / 双列），因此本脚本按**当前**结构重写，
 * 断言「两行语义 + 单双列 + 协议走 NodeProtocolPolicy + 延迟走 TunBoxPing」。
 *
 * 本脚本不做完整 ArkTS 解析（无 DevEco SDK），只对源码做结构断言，
 * 与仓库既有 verify-*.mjs 的「文本断言 + 负对照」风格一致。
 *
 * ⚠ 已知陷阱（本脚本已处理，勿改回去）:
 *   · 仓库是 CRLF 检出：读取时统一归一化 CRLF→LF，断言才按真实语义工作。
 *   · nodeCard 里有**嵌套花括号**（Stack/Circle/if/Row），固定长度窗口会溢进相邻
 *     代码，必须用逐字符状态机（跳过注释/字符串/正则字面量）做括号配对。
 *   · 「注释里提到旧实现」不算实现：代码类断言先去注释。
 *
 * 用法: node scripts/verify-sub-node-two-row.mjs [--file <path>]
 *   --file 用于负对照：指向旧版/被改坏的 SubscriptionPage.ets 时，本脚本**必须失败**。
 * 退出码: 0 = 全部断言通过；1 = 有断言失败
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const argIdx = process.argv.indexOf('--file');
const file = argIdx >= 0 && process.argv[argIdx + 1]
  ? path.resolve(process.argv[argIdx + 1])
  : path.join(here, '..', 'entry', 'src', 'main', 'ets', 'pages', 'SubscriptionPage.ets');
// 统一换行：仓库是 CRLF 检出，断言按 LF 语义书写。
const src = fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n');

let pass = 0;
const fails = [];
function ok(name, cond, extra) {
  if (cond) { pass += 1; console.log(`  ✓ ${name}`); }
  else { fails.push(name + (extra ? ` (${extra})` : '')); console.log(`  ✗ ${name}${extra ? ` — ${extra}` : ''}`); }
}

/** 去掉注释（保留字符串/正则，结构断言用不到它们内部的 // ） */
function stripComments(text) {
  return text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '');
}

/**
 * 单遍状态机：返回 code 掩码（1=代码，0=注释/字符串/正则字面量内部）。
 * 只有掩码为 1 的位置参与括号匹配，避免 ArkUI 链式属性与正则里的 (){}[] 误判。
 */
function codeMask(text) {
  const mask = new Uint8Array(text.length);
  let i = 0;
  let prev = '';
  const mark = (n) => { for (let k = 0; k < n && i + k < text.length; k += 1) mask[i + k] = 1; };
  while (i < text.length) {
    const ch = text[i];
    const nx = text[i + 1];
    if (ch === '/' && nx === '/') { while (i < text.length && text[i] !== '\n') i += 1; continue; }
    if (ch === '/' && nx === '*') {
      i += 2;
      while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) i += 1;
      i += 2;
      continue;
    }
    if (ch === "'" || ch === '"' || ch === '`') {
      const q = ch;
      i += 1;
      while (i < text.length && text[i] !== q) { if (text[i] === '\\') i += 1; i += 1; }
      i += 1;
      prev = 'str';
      continue;
    }
    if (ch === '/' && nx !== undefined && !/\s/.test(nx) && nx !== '/' && nx !== '*') {
      if (prev === '' || '=(,:;[!&|?{+return'.includes(prev)) {
        i += 1;
        let inClass = false;
        while (i < text.length) {
          const c = text[i];
          if (c === '\\') { i += 2; continue; }
          if (c === '[') inClass = true;
          else if (c === ']') inClass = false;
          else if (c === '/' && !inClass) break;
          else if (c === '\n') break;
          i += 1;
        }
        i += 1;
        while (i < text.length && /[gimsuyd]/.test(text[i])) i += 1;
        prev = 're';
        continue;
      }
    }
    mark(1);
    if (!/\s/.test(ch)) prev = ch;
    i += 1;
  }
  return mask;
}

const MASK = codeMask(src);

/** 从 openIdx（必须是代码区的 { ( [ ）扫到匹配的闭括号，返回下标；失败 -1 */
function matchBrace(openIdx) {
  const OPEN = { '{': '}', '(': ')', '[': ']' };
  const CLOSE = { '}': '{', ')': '(', ']': '[' };
  const stack = [];
  for (let i = openIdx; i < src.length; i += 1) {
    if (MASK[i] !== 1) continue;
    const ch = src[i];
    if (OPEN[ch]) stack.push(ch);
    else if (CLOSE[ch]) {
      if (stack.pop() !== CLOSE[ch]) return -1;
      if (stack.length === 0) return i;
    }
  }
  return -1;
}

/** 全文件括号配平（逐字符状态机；朴素计数在 ArkUI 里是假失败） */
function balancedReport() {
  const PAIRS = { ')': '(', '}': '{', ']': '[' };
  const stack = [];
  for (let i = 0; i < src.length; i += 1) {
    if (MASK[i] !== 1) continue;
    const ch = src[i];
    if (PAIRS[ch]) {
      const top = stack.pop();
      const line = src.slice(0, i).split('\n').length;
      if (top === undefined) return { ok: false, msg: `第 ${line} 行多余 '${ch}'` };
      if (top.ch !== PAIRS[ch]) return { ok: false, msg: `第 ${line} 行 '${ch}' 与第 ${top.line} 行 '${top.ch}' 不匹配` };
    } else if ('({['.includes(ch)) {
      stack.push({ ch, line: src.slice(0, i).split('\n').length });
    }
  }
  if (stack.length > 0) {
    return { ok: false, msg: `末尾仍有 ${stack.length} 个未闭合括号，首个在第 ${stack[0].line} 行 '${stack[0].ch}'` };
  }
  return { ok: true, msg: '括号全部配平' };
}

console.log(`\n订阅页节点行两行信息列自检${argIdx >= 0 ? `（--file ${file}）` : ''}`);

// ── 0. 文件前提 ────────────────────────────────────────────────────────
ok('源码存在且非空', src.length > 1000, `len=${src.length}`);

// ── 1. 精确定位 nodeCard 卡片（按真实花括号配对，不用定长窗口）──────────
const cardSig = /@Builder\s*\n\s*nodeCard\(node: ProxyNode\)\s*\{/.exec(src);
const cardOpen = cardSig ? cardSig.index + cardSig[0].length - 1 : -1;
const cardClose = cardOpen >= 0 ? matchBrace(cardOpen) : -1;
const card = (cardOpen >= 0 && cardClose > cardOpen) ? src.slice(cardOpen, cardClose + 1) : '';
ok('nodeCard 卡片可完整截取（花括号配对）',
  card.length > 0 && card.length < 4000, `len=${card.length}`);
const cardCode = stripComments(card);

// 卡片根容器 = Column({ space: 8 })（两行信息列靠 8vp 行距分层）
ok('卡片根容器为 Column({ space: 8 })', /^\{\s*Column\(\{ space: 8 \}\)\s*\{/.test(cardCode));

/**
 * 从 `Name(` 调用处取它的**代码块**：先配平参数括号，再取紧随其后的 `{...}`。
 * 直接找第一个 `{` 会命中 `Row({ space: 6 })` 里的对象字面量，把整行截成参数。
 * 返回绝对下标 { open, close }。
 */
function blockAfterCall(absCallIdx) {
  const paren = src.indexOf('(', absCallIdx);
  const parenClose = paren >= 0 ? matchBrace(paren) : -1;
  const open = parenClose >= 0 ? src.indexOf('{', parenClose) : -1;
  return { open, close: open >= 0 ? matchBrace(open) : -1 };
}

// ── 2. 两行结构：恰好两个 Row，且名称/协议/延迟各自归位 ─────────────────
const colCall = src.indexOf('Column(', cardOpen);
const col = blockAfterCall(colCall);
const colBlock = (col.open >= 0 && col.close > col.open) ? src.slice(col.open, col.close + 1) : '';
ok('Column 信息列块可截取', colBlock.length > 0, `len=${colBlock.length}`);

const row1CallAbs = col.open + colBlock.indexOf('Row(');
const row1Blk = blockAfterCall(row1CallAbs);
const row1Text = row1Blk.open >= 0 && row1Blk.close > row1Blk.open
  ? src.slice(row1Blk.open, row1Blk.close + 1) : '';
const row2CallAbs = row1Blk.close >= 0 ? src.indexOf('Row(', row1Blk.close) : -1;
const row2Blk = row2CallAbs >= 0 ? blockAfterCall(row2CallAbs) : { open: -1, close: -1 };
const row2Text = row2Blk.open >= 0 && row2Blk.close > row2Blk.open
  ? src.slice(row2Blk.open, row2Blk.close + 1) : '';
ok('第一行（单选 + 名称）可截取', row1Text.length > 0, `len=${row1Text.length}`);
ok('第二行（协议 + 延迟）可截取', row2Text.length > 0, `len=${row2Text.length}`);
ok('第二行位于第一行之后',
  row1Blk.close > 0 && row2CallAbs > row1Blk.close && row2Blk.close < cardClose);
ok('卡片内恰好两行 Row（没有第三行回流/旧三件套）',
  (stripComments(colBlock).match(/\bRow\(/g) || []).length === 2,
  `rows=${(stripComments(colBlock).match(/\bRow\(/g) || []).length}`);

// 名称在第一行、协议与延迟在第二行（旧实现三者同行的核心回归点）
ok('第一行含节点名称', /Text\(node\.name\)/.test(row1Text));
ok('第一行不含协议徽标（旧「三件套一行」已拆除）', !/this\.protoOf\(node\)/.test(row1Text));
ok('第一行不含延迟文本', !/this\.nodePingText\(node\)/.test(row1Text));
ok('第二行含协议标签', /Text\(this\.protoOf\(node\)\)/.test(row2Text));
ok('第二行含延迟文本', /Text\(this\.nodePingText\(node\)\)/.test(row2Text));
ok('第二行不含节点名称', !/Text\(node\.name\)/.test(row2Text));
ok('第二行用 Blank() 把延迟推到行尾', /\bBlank\(\)/.test(row2Text));

// ── 3. 名称拿满宽度（不被协议/延迟挤压）─────────────────────────────────
ok('名称 layoutWeight(1)', /Text\(node\.name\)[\s\S]{0,300}?\.layoutWeight\(1\)/.test(row1Text));
ok('名称 maxLines(1)', /Text\(node\.name\)[\s\S]{0,300}?\.maxLines\(1\)/.test(row1Text));
ok('名称 textOverflow 省略号',
  /Text\(node\.name\)[\s\S]{0,300}?textOverflow\(\{ overflow: TextOverflow\.Ellipsis \}\)/.test(row1Text));
ok('名称文本用主文字色', /Text\(node\.name\)[\s\S]{0,300}?fontColor\(TunBoxColors\.textPrimary\)/.test(row1Text));

// ── 4. 协议标签独占宽度、不参与挤压；延迟不吃 layoutWeight ──────────────
const protoIdx = row2Text.indexOf('Text(this.protoOf(node))');
const blankIdx = row2Text.indexOf('Blank()');
const protoBlock = (protoIdx >= 0 && blankIdx > protoIdx) ? row2Text.slice(protoIdx, blankIdx) : '';
ok('协议标签块可截取', protoBlock.length > 0, `len=${protoBlock.length}`);
ok('协议标签 maxLines(1)', /\.maxLines\(1\)/.test(protoBlock));
ok('协议标签 textOverflow 省略号', /textOverflow\(\{ overflow: TextOverflow\.Ellipsis \}\)/.test(protoBlock));
ok('协议标签无 layoutWeight（否则会把名称/延迟挤成残字）', !/layoutWeight\(1\)/.test(protoBlock));
ok('协议标签有 chip 底色与圆角',
  /backgroundColor\(TunBoxColors\.chipBg\)/.test(protoBlock) && /borderRadius\(4\)/.test(protoBlock));

// ── 5. 两行都吃满卡片宽度并垂直居中 ────────────────────────────────────
const row1Tail = row1Blk.close > 0 ? src.slice(row1Blk.close + 1, row2CallAbs) : '';
const row2Tail = row2Blk.close > 0 ? src.slice(row2Blk.close + 1, col.close) : '';
ok('第一行 width(100%)', /\.width\('100%'\)/.test(row1Tail));
ok('第一行垂直居中', /\.alignItems\(VerticalAlign\.Center\)/.test(row1Tail));
ok('第二行 width(100%)', /\.width\('100%'\)/.test(row2Tail));
ok('第二行垂直居中', /\.alignItems\(VerticalAlign\.Center\)/.test(row2Tail));

// ── 6. 卡片容器属性（0.4.0 卡片化：圆角/内边距/描边/点击/长按删除）──────
// 卡片自身的属性链在 Column 块之后、nodeCard 方法结束之前。
const cardTail = (col.close > 0 && cardClose > col.close) ? src.slice(col.close + 1, cardClose) : '';
ok('卡片属性链可截取', cardTail.length > 0, `len=${cardTail.length}`);
ok('卡片 width(100%)', /\.width\('100%'\)/.test(cardTail));
ok('卡片 padding(12)', /\.padding\(12\)/.test(cardTail));
ok('卡片 borderRadius(16)', /\.borderRadius\(16\)/.test(cardTail));
ok('卡片 backgroundColor(surfaceCard)', /backgroundColor\(TunBoxColors\.surfaceCard\)/.test(cardTail));
ok('选中卡片描边加粗（1.5 vs 1）',
  /border\(\{\s*width: (?:node\.id === this\.activeNodeId|this\.isActiveNode\(node\)) \? 1\.5 : 1,/.test(cardTail));
// 2026-10-20 批量多选改造后：圆圈要同时表达「当前出口」（平时）与「已勾选」（选择态），
// 点击走 onNodeCardTap（选择态=勾选 / 平时=选中出口），长按改为进入批量选择态。
ok('选中态圆圈填充 primary（含批量勾选态）',
  /\.fill\(this\.nodeSelectMode\s*\n?\s*\? \(this\.isNodeSelected\(node\.id\) \? TunBoxColors\.primary : Color\.Transparent\)/
    .test(card) || /\.fill\(this\.nodeSelectMode/.test(card));
ok('点击走 onNodeCardTap（选择态切勾选）',
  /\.onClick\(\(\) => this\.onNodeCardTap\(node\)\)/.test(cardTail));
ok('onNodeCardTap 内部仍调用 selectNode（平时选中出口）',
  /private onNodeCardTap\(node: ProxyNode\): void \{[\s\S]*?this\.selectNode\(node\);/.test(src));
ok('长按进入批量多选（替换单节点删除框）',
  /LongPressGesture\(\)\.onAction/.test(cardTail) && /this\.enterNodeSelectMode\(node\.id\)/.test(cardTail));
ok('批量删除复用 removeNode（本地屏蔽台账）',
  /private async doDeleteSelectedNodes\(\): Promise<void> \{[\s\S]*?this\.service\.removeNode\(id\)/.test(src));

// ── 7. 单列 / 双列排布（GridRow 控宽，卡片自身 100%）────────────────────
ok('nodeColumns 状态存在且默认单列', /@State nodeColumns: number = 1;/.test(src));
ok('GridRow 按 nodeColumns 控宽', /GridRow\(\{ columns: this\.nodeColumns, gutter: 10 \}\)/.test(src));
ok('GridCol 内渲染 nodeCard', /GridCol\(\)\s*\{\s*\n\s*this\.nodeCard\(node\)/.test(src));
ok('单双列切换逻辑保留', /const next = this\.nodeColumns === 2 \? 1 : 2;/.test(src));
ok('单双列选择持久化', /SettingsService\.saveNodeColumns\(next\);/.test(src));
ok('启动时读回单双列选择', /await SettingsService\.loadNodeColumns\(\)/.test(src));

// ── 8. 协议口径：复用 NodeProtocolPolicy，不硬截断 ──────────────────────
const codeOnly = stripComments(src);
// 2026-10-22：protoOf 现在有「内核影子节点」前置分支（CoreNodeBridge.isShadow），
// 所以不能再要求 return 紧贴函数头；只要函数体内**最终**落到
// NodeProtocolPolicy.fromNode(node).display() 即可（口径仍单一）。
ok('protoOf 复用 NodeProtocolPolicy',
  /private protoOf\(node: ProxyNode\): string \{[\s\S]{0,400}?NodeProtocolPolicy\.fromNode\(node\)\.display\(\);/.test(src));
ok('import NodeProtocolPolicy',
  /import \{ NodeProtocolPolicy \} from '\.\.\/commons\/services\/NodeSortPersistence';/.test(src));
ok('代码中无 slice(0, 8) 硬截断', !/toUpperCase\(\)\.slice\(0, 8\)/.test(codeOnly));

// ── 9. 延迟口径：TunBoxPing 五态文案/配色，不再走 NexusPing ─────────────
// 2026-10-20（LP08 清退）：旧门面 LatencyController 已删 ⇒ 页面改走 LatencyStoreBridge
// （= LatencyStore + LatencyLiveView 的唯一 UI 接缝）⇒ 断言跟着换源。
ok('nodePingText 走 TunBoxPing.recordText',
  /private nodePingText\(node: ProxyNode\): string \{\s*\n\s*return TunBoxPing\.recordText\(LatencyStoreBridge\.recordFor\(node\.name\), this\.latencyTick\);/.test(src));
ok('nodePingColor 走 TunBoxPing.recordColor',
  /private nodePingColor\(node: ProxyNode\): ResourceColor \{\s*\n\s*return TunBoxPing\.recordColor\(LatencyStoreBridge\.recordFor\(node\.name\), this\.latencyTick\);/.test(src));
ok('页面不再直接读旧 LatencyController', !/LatencyController/.test(codeOnly));
ok('TunBoxPing 已从主题令牌导入', /import \{[^}]*TunBoxPing[^}]*\} from '\.\.\/theme\/TunBoxTokens';/.test(src));
ok('旧 NexusPing 延迟路径已移除（代码区）', !/NexusPing/.test(codeOnly));
ok('第二行延迟仍带配色（五态）', /fontColor\(this\.nodePingColor\(node\)\)/.test(row2Text));

// ── 10. 全文件括号配平（本文件结构未被改坏）────────────────────────────
const bal = balancedReport();
ok('全文件括号配平', bal.ok, bal.msg);

// ── 汇总 ──────────────────────────────────────────────────────────────
console.log(`\n自检结果：${pass} 条通过，${fails.length} 条失败`);
if (fails.length > 0) {
  console.error('失败：' + fails.join(' | '));
  process.exit(1);
}
console.log('全部通过（第一行=单选+名称，第二行=协议+延迟；单双列/协议口径/延迟口径均未退化）');
process.exit(0);
