/**
 * 门禁共享的 mini-YAML 解析/序列化（受控子集，仅为 Node 门禁桥接内核桥用）。
 *
 * 2026-11-05 FlClash 全量照抄后，取回/合并的 YAML 解码都由内核承担
 * （TunBoxDecodeYaml / UnmarshalRawConfig）；Node 门禁没有内核 —— 这里提供与
 * go.yaml.in/yaml/v3 公共子集一致的解析器，只用于门禁自造 fixture 与
 * ClashConfigGenerator 的输出。超出子集立即抛错（不静默）。
 *
 * 支持块式 map/list、流式 [a,b] {a:b}、单双引号标量（含 '' 转义）、
 * 数字/布尔/null；不支持多行标量、锚点、注释保留。
 */

export function miniScalar(raw) {
  const t = raw.trim();
  if (t.length === 0 || t === '~' || t === 'null') return null;
  if (t === 'true' || t === 'True' || t === 'TRUE') return true;
  if (t === 'false' || t === 'False' || t === 'FALSE') return false;
  if (/^-?\d+$/.test(t)) return parseInt(t, 10);
  if (/^-?\d+\.\d+$/.test(t)) return parseFloat(t);
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    return t.slice(1, -1).replace(/''/g, "'");
  }
  return t;
}

function splitFlow(body) {
  const items = [];
  let depth = 0, quote = null, cur = '';
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (quote !== null) {
      cur += ch;
      if (ch === quote) quote = null;
      continue;
    }
    if (ch === '"' || ch === "'") { quote = ch; cur += ch; continue; }
    if (ch === '[' || ch === '{') depth++;
    if (ch === ']' || ch === '}') depth--;
    if (ch === ',' && depth === 0) { items.push(cur.trim()); cur = ''; continue; }
    cur += ch;
  }
  if (cur.trim().length > 0) items.push(cur.trim());
  return items;
}

function parseFlow(text) {
  const t = text.trim();
  if (t.startsWith('[')) {
    if (t === '[]') return [];
    return splitFlow(t.slice(1, -1)).map((x) => (x.startsWith('{') ? parseFlow(x) : miniScalar(x)));
  }
  if (t.startsWith('{')) {
    const out = {};
    if (t === '{}') return out;
    for (const item of splitFlow(t.slice(1, -1))) {
      const idx = findColon(item);
      if (idx < 0) throw new Error(`mini-yaml: flow map item missing colon: ${item}`);
      out[miniScalar(item.slice(0, idx))] = parseFlow(item.slice(idx + 1));
    }
    return out;
  }
  return miniScalar(t);
}

function findColon(t) {
  let quote = null;
  for (let k = 0; k < t.length; k++) {
    const ch = t[k];
    if (quote !== null) { if (ch === quote) quote = null; continue; }
    if (ch === '"' || ch === "'") { quote = ch; continue; }
    if (ch === ':' && (k + 1 === t.length || t[k + 1] === ' ')) return k;
  }
  return t.endsWith(':') ? t.length - 1 : -1;
}

export function miniYamlParse(text) {
  const lines = text.replace(/\r/g, '').split('\n')
    .filter((l) => l.trim().length > 0 && !l.trim().startsWith('#'));
  let i = 0;
  const indentOf = (l) => l.length - l.trimStart().length;

  function parseBlock(indent) {
    if (i >= lines.length) return null;
    if (lines[i].trimStart().startsWith('- ')) return parseList(indent);
    return parseMap(indent);
  }

  function parseMap(indent) {
    const out = {};
    while (i < lines.length) {
      const line = lines[i];
      const ind = indentOf(line);
      if (ind < indent) break;
      if (ind > indent) throw new Error(`mini-yaml: bad indent: ${line}`);
      if (line.trimStart().startsWith('- ')) break;
      const t = line.trim();
      const idx = findColon(t);
      if (idx < 0) throw new Error(`mini-yaml: map line missing colon: ${t}`);
      const key = miniScalar(t.slice(0, idx));
      const rest = t.slice(idx + 1).trim();
      i++;
      if (rest.length === 0) {
        const childIndent = i < lines.length ? indentOf(lines[i]) : indent + 2;
        out[key] = parseBlock(childIndent > indent ? childIndent : indent + 2);
      } else {
        out[key] = parseFlow(rest);
      }
    }
    return out;
  }

  function parseList(indent) {
    const out = [];
    while (i < lines.length) {
      const line = lines[i];
      const ind = indentOf(line);
      if (ind < indent || !line.trimStart().startsWith('- ')) break;
      const t = line.trim().slice(2).trim();
      if (t.length === 0) {
        i++;
        out.push(parseBlock(indent + 2));
        continue;
      }
      // 流式（{...} / [...]）优先：不能先按「有冒号」分块 —— `- {name: A, ...}`
      // 会被误拆成键为 `{name` 的坏 map
      if (t.startsWith('{') || t.startsWith('[')) {
        out.push(parseFlow(t));
        i++;
        continue;
      }
      const colon = findColon(t);
      if (colon > 0) {
        const itemIndent = ind + 2;
        lines[i] = ' '.repeat(itemIndent) + t;
        out.push(parseMap(itemIndent));
        continue;
      }
      out.push(parseFlow(t));
      i++;
    }
    return out;
  }

  return parseBlock(0);
}

function yamlNeedsQuote(v) {
  if (v.length === 0) return true;
  if (/^(?:true|false|null|yes|no|on|off|~)$/i.test(v)) return true;
  if (/^[-?:,[]{}#&*!|>'"%@`]/.test(v)) return true;
  if (/^(?:0x[0-9a-fA-F]+|-?\d+(?:\.\d+)?)$/.test(v)) return true;
  if (/\s$|^\s/.test(v)) return true;
  return false;
}

function yamlScalar(v) {
  if (typeof v === 'number') return String(v);
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (v === null || v === undefined) return 'null';
  const s = String(v);
  if (yamlNeedsQuote(s)) return `'${s.replace(/'/g, "''")}'`;
  return s;
}

export function miniYamlDump(value) {
  const out = [];
  function walkMapInline(obj, indent) {
    for (const key of Object.keys(obj)) {
      const val = obj[key];
      const pad = ' '.repeat(indent);
      if (Array.isArray(val)) {
        if (val.length === 0) { out.push(`${pad}${key}: []`); continue; }
        const allScalar = val.every((x) => x === null || typeof x !== 'object');
        if (allScalar) {
          out.push(`${pad}${key}: [${val.map(yamlScalar).join(', ')}]`);
        } else {
          out.push(`${pad}${key}:`);
          walkList(val, indent + 2);
        }
        continue;
      }
      if (val !== null && typeof val === 'object') {
        if (Object.keys(val).length === 0) { out.push(`${pad}${key}: {}`); continue; }
        out.push(`${pad}${key}:`);
        walkMapInline(val, indent + 2);
        continue;
      }
      out.push(`${pad}${key}: ${yamlScalar(val)}`);
    }
  }
  function walkList(list, indent) {
    for (const item of list) {
      if (item !== null && typeof item === 'object') {
        const keys = Object.keys(item);
        const first = keys[0];
        const headVal = item[first];
        const pad = ' '.repeat(indent);
        if (headVal !== null && typeof headVal === 'object') {
          out.push(`${pad}- ${first}:`);
          walkMapInline(headVal, indent + 2);
        } else {
          out.push(`${pad}- ${first}: ${yamlScalar(headVal)}`);
        }
        for (const key of keys.slice(1)) {
          const val = item[key];
          if (Array.isArray(val)) {
            if (val.length === 0) { out.push(`${pad}  ${key}: []`); continue; }
            const allScalar = val.every((x) => x === null || typeof x !== 'object');
            if (allScalar) {
              out.push(`${pad}  ${key}: [${val.map(yamlScalar).join(', ')}]`);
            } else {
              out.push(`${pad}  ${key}:`);
              walkList(val, indent + 4);
            }
            continue;
          }
          if (val !== null && typeof val === 'object') {
            if (Object.keys(val).length === 0) { out.push(`${pad}  ${key}: {}`); continue; }
            out.push(`${pad}  ${key}:`);
            walkMapInline(val, indent + 4);
            continue;
          }
          out.push(`${pad}  ${key}: ${yamlScalar(val)}`);
        }
        continue;
      }
      out.push(`${' '.repeat(indent)}- ${yamlScalar(item)}`);
    }
  }
  if (Array.isArray(value)) {
    walkList(value, 0);
  } else if (value !== null && typeof value === 'object') {
    walkMapInline(value, 0);
  } else {
    out.push(yamlScalar(value));
  }
  return `${out.join('\n')}\n`;
}
