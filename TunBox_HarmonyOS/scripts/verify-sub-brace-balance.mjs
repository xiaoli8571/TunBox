/**
 * SubscriptionSection 括号配平真检（逐字符状态机，跳过注释/字符串/模板字面量/正则字面量）。
 *
 * 为什么不用朴素计数：文件里大量出现
 *   .padding({ left: 5, right: 5 })
 *   `.width('100%').padding({ ... })`
 * 以及 `/^([a-zA-Z]...)$/` 这类**正则字面量**，里面的 ()[]{} 会被天真计数当成结构括号，
 * 于是原文件（HEAD 版）数出来就是 `()` 差 7、`{}` 差 9 —— 假失败。
 *
 * 状态机：lineComment / blockComment / sq / dq / tpl / regex 六态，
 * 只有 code 态的括号才进栈。同时记录首个失配位置，便于定位。
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const target = process.argv[2] === 'orig'
  ? path.join(process.env.LOCALAPPDATA, 'Temp', 'sub_orig.ets')
  : path.join(here, '..', 'entry', 'src', 'main', 'ets', 'components', 'SubscriptionSection.ets');
const src = fs.readFileSync(target, 'utf8');

const PAIRS = { ')': '(', '}': '{', ']': '[' };
const OPEN = new Set(['(', '{', '[']);

function scan(text) {
  const stack = [];
  let line = 1;
  let i = 0;
  let prevSignificant = ''; // 上一个有意义的字符，用于识别正则字面量起点

  const advance = (n = 1) => { for (let k = 0; k < n; k += 1) { if (text[i] === '\n') line += 1; i += 1; } };

  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];

    // 注释
    if (ch === '/' && next === '/') { while (i < text.length && text[i] !== '\n') advance(); continue; }
    if (ch === '/' && next === '*') { advance(2); while (i < text.length && !(text[i] === '*' && text[i + 1] === '/')) advance(); advance(2); continue; }

    // 字符串
    if (ch === "'") { advance(); while (i < text.length && text[i] !== "'") { if (text[i] === '\\') advance(); advance(); } advance(); prevSignificant = 'str'; continue; }
    if (ch === '"') { advance(); while (i < text.length && text[i] !== '"') { if (text[i] === '\\') advance(); advance(); } advance(); prevSignificant = 'str'; continue; }
    if (ch === '`') { advance(); while (i < text.length && text[i] !== '`') { if (text[i] === '\\') advance(); advance(); } advance(); prevSignificant = 'str'; continue; }

    // 正则字面量：除号后紧跟非空白且不是除号 → 视为正则（ArkUI 里 / 只可能是除号或正则起点）
    if (ch === '/' && !/\s/.test(next ?? '') && !['/', '*'].includes(next ?? '')) {
      const canBeRegex = prevSignificant === '' || '=(,:;[!&|?{+return'.includes(prevSignificant);
      if (canBeRegex) {
        advance();
        let inClass = false;
        while (i < text.length) {
          const c = text[i];
          if (c === '\\') { advance(2); continue; }
          if (c === '[') inClass = true;
          else if (c === ']') inClass = false;
          else if (c === '/' && !inClass) break;
          else if (c === '\n') break;
          advance();
        }
        advance(); // 收尾 /
        while (i < text.length && /[gimsuyd]/.test(text[i])) advance();
        prevSignificant = 're';
        continue;
      }
    }

    if (OPEN.has(ch)) { stack.push({ ch, line }); advance(); prevSignificant = ch; continue; }
    if (PAIRS[ch]) {
      const top = stack.pop();
      if (top === undefined) return { ok: false, msg: `第 ${line} 行多余的 '${ch}'` };
      if (top.ch !== PAIRS[ch]) return { ok: false, msg: `第 ${line} 行 '${ch}' 与第 ${top.line} 行 '${top.ch}' 不匹配` };
      advance(); prevSignificant = ch; continue;
    }
    if (!/\s/.test(ch)) prevSignificant = ch;
    advance();
  }
  if (stack.length > 0) {
    return { ok: false, msg: `文件末尾仍有 ${stack.length} 个未闭合括号，首个在第 ${stack[0].line} 行 '${stack[0].ch}'` };
  }
  return { ok: true, msg: '括号全部配平' };
}

const result = scan(src);
console.log(`${path.basename(target)}: ${result.ok ? '✓' : '✗'} ${result.msg}`);
process.exit(result.ok ? 0 : 1);
