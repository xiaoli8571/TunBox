#!/usr/bin/env node
/**
 * CoreCatalog（内核节点目录）真实行为验证。
 *
 * 为什么需要它：CoreCatalog.ets 的全部口径（组类型白名单、GLOBAL hidden、
 * 延迟优先级排序、"整组隐藏光则保留原组"、文案/配色、PUT/DELETE 路径与 body）
 * 都是纯逻辑，而 HAP 当前未签名装不上机，hypium 跑不了。这里用 Node 24 的
 * 类型剥离**直接加载 .ets 源文件本体**（只换扩展名，不改一行代码），
 * 用两份**手写但结构与真实 mihomo /proxies 响应一致**的 JSON 逐分支断言。
 *
 * 两份 payload 的差异是刻意的：
 *   - A：本仓库内核（Clash.Meta fork）形状 —— 组测速地址键是 `testUrl`，
 *        GLOBAL 的 `hidden` 是 false，含 Selector / URLTest / 非组节点 /
 *        history 为空的节点 / history 末条 delay=0（内核失败记 0）。
 *   - B：上游 mihomo 形状 —— 测速地址键是 `url`，GLOBAL 的 `hidden` 是 true，
 *        含 Fallback / LoadBalance / Relay / Compatible，history 末条为负（-1）。
 * 两条都过 = 解析器没有绑死某一种内核的字段。
 *
 * 用法: node scripts/verify-core-catalog.mjs
 * 退出码: 0 = 全部通过；1 = 有断言失败
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const src = path.join(root, 'entry/src/main/ets/commons/flclash/CoreCatalog.ets');

let passed = 0;
const failures = [];
function check(name, fn) {
  try {
    fn();
    passed++;
    console.log(`PASS ${name}`);
  } catch (e) {
    failures.push(`${name} :: ${e.message}`);
    console.log(`FAIL ${name} :: ${e.message}`);
  }
}
function eq(actual, expected, label) {
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) throw new Error(`${label}: expected ${b}, got ${a}`);
}
function ok(cond, label) {
  if (!cond) throw new Error(label);
}

// ---- 加载被测源码本体（只改扩展名，type stripping 直接吃 .ts） ----
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'core-catalog-'));
const tmpFile = path.join(tmpDir, 'CoreCatalog.ts');
fs.copyFileSync(src, tmpFile);
const mod = await import(pathToFileURL(tmpFile).href);
const {
  CORE_GROUP_TYPES,
  CoreCatalog,
  CoreGroup,
  CoreNode,
  CoreSelection
} = mod;

// ---- payload A：本仓库内核形状 ----
const PAYLOAD_A = `{
  "proxies": {
    "DIRECT": { "type": "Direct", "name": "DIRECT", "udp": true, "uot": false, "history": [] },
    "REJECT": { "type": "Reject", "name": "REJECT", "udp": false, "history": [] },
    "GLOBAL": {
      "type": "Selector", "name": "GLOBAL", "now": "PROXY",
      "all": ["PROXY", "Auto", "DIRECT", "REJECT"],
      "testUrl": "", "hidden": false, "icon": "", "emptyFallback": "COMPATIBLE"
    },
    "PROXY": {
      "type": "Selector", "name": "PROXY", "now": "HK-01",
      "all": ["HK-01", "JP-02", "Auto"],
      "testUrl": "https://www.gstatic.com/generate_204", "hidden": false, "icon": ""
    },
    "Auto": {
      "type": "URLTest", "name": "Auto", "now": "JP-02",
      "all": ["HK-01", "JP-02", "SG-03"],
      "testUrl": "https://cp.cloudflare.com/generate_204", "expectedStatus": "204", "hidden": false
    },
    "HK-01": {
      "type": "Shadowsocks", "name": "HK-01", "udp": true,
      "history": [{ "time": "2026-10-22T10:00:00Z", "delay": 38 }]
    },
    "JP-02": {
      "type": "Vmess", "name": "JP-02", "udp": true,
      "history": [
        { "time": "2026-10-22T09:58:00Z", "delay": 120 },
        { "time": "2026-10-22T10:00:00Z", "delay": 96 }
      ]
    },
    "SG-03": {
      "type": "Trojan", "name": "SG-03",
      "history": [{ "time": "2026-10-22T10:00:00Z", "delay": 0 }]
    }
  }
}`;

// ---- payload B：上游 mihomo 形状 ----
const PAYLOAD_B = `{
  "proxies": {
    "GLOBAL": {
      "type": "Selector", "name": "GLOBAL", "now": "Fallback",
      "all": ["Fallback", "DIRECT"], "hidden": true, "history": []
    },
    "Fallback": {
      "type": "Fallback", "name": "Fallback", "now": "",
      "all": ["US-01", "US-02"], "url": "https://www.gstatic.com/generate_204",
      "history": [{ "time": "2026-10-22T10:00:00Z", "delay": -1 }]
    },
    "LB": {
      "type": "LoadBalance", "name": "LB", "now": "",
      "all": ["US-01", "US-02"], "url": "", "history": []
    },
    "Relay": { "type": "Relay", "name": "Relay", "now": "", "all": ["US-01"] },
    "US-01": { "type": "Hysteria2", "name": "US-01", "history": [] },
    "US-02": { "type": "AnyTLS", "name": "US-02", "history": [] },
    "COMPATIBLE": { "type": "Compatible", "name": "COMPATIBLE", "history": [] }
  }
}`;

const a = CoreCatalog.parse(PAYLOAD_A);
const b = CoreCatalog.parse(PAYLOAD_B);

console.log('\n== 常量与组类型判定 ==');
check('CORE_GROUP_TYPES 恰为 6 个内核组类型（含 FlClash fork 的 Smart）', () => {
  eq(CORE_GROUP_TYPES, ['Selector', 'URLTest', 'Fallback', 'Relay', 'LoadBalance', 'Smart'], 'types');
});
check('isGroupType 精确匹配、大小写敏感、非组类型为 false', () => {
  eq(CORE_GROUP_TYPES.map((t) => CoreCatalog.isGroupType(t)), [true, true, true, true, true, true], 'all');
  // Smart 自 2026-10-30 起因真机报障「两条自动选择」被判定为组（此前漏判 → smart 组
  // 作为伪节点混进节点列表）。大小写敏感仍必须保留。
  eq(
    ['Shadowsocks', 'Direct', 'Compatible', 'selector', 'URLTest ', 'smart'].map((t) => CoreCatalog.isGroupType(t)),
    [false, false, false, false, false, false],
    'non-groups'
  );
});

console.log('\n== payload A：解析（本仓库内核形状） ==');
check('parse 成功，条目数与 map 键一致（8 条）', () => {
  ok(a !== null, 'parse returned null');
  eq(Object.keys(a.byName).length, 8, 'byName size');
});
check('组集合 = GLOBAL / PROXY / Auto，且 GLOBAL 被提到最前', () => {
  eq(a.groups.map((g) => g.name), ['GLOBAL', 'PROXY', 'Auto'], 'group order');
  eq(a.groups.map((g) => g.type), ['Selector', 'Selector', 'URLTest'], 'group types');
});
check('非组节点 isGroup=false，组节点 isGroup=true', () => {
  eq(
    ['GLOBAL', 'PROXY', 'Auto', 'DIRECT', 'REJECT', 'HK-01', 'JP-02', 'SG-03'].map((n) => a.byName[n].isGroup),
    [true, true, true, false, false, false, false, false],
    'isGroup'
  );
});
check('GLOBAL hidden=true（字段为 false 也按名字判定，对齐 proxyView 的 hidden:true）', () => {
  eq(a.byName['GLOBAL'].hidden, true, 'GLOBAL hidden');
  eq(a.groups.find((g) => g.name === 'GLOBAL').hidden, true, 'group hidden');
  eq([a.byName['PROXY'].hidden, a.byName['Auto'].hidden, a.byName['DIRECT'].hidden], [false, false, false], 'others');
});
check('lastDelay：取 history 末条；空 history → -1；内核失败记的 0 原样保留', () => {
  eq(a.byName['HK-01'].lastDelay, 38, 'HK-01');
  eq(a.byName['JP-02'].lastDelay, 96, 'JP-02 last of 2');
  eq(a.byName['SG-03'].lastDelay, 0, 'SG-03 failed-as-0');
  eq([a.byName['DIRECT'].lastDelay, a.byName['GLOBAL'].lastDelay], [-1, -1], 'no history');
});
check('组 url：本仓库内核的 testUrl 键也能读到；空则不回落', () => {
  eq(a.byName['PROXY'].url, 'https://www.gstatic.com/generate_204', 'PROXY url');
  eq(a.byName['Auto'].url, 'https://cp.cloudflare.com/generate_204', 'Auto url');
  eq(a.byName['GLOBAL'].url, '', 'GLOBAL url');
});
check('组 now 取内核当前选中；成员名已解析成节点引用（保留类型与组标记）', () => {
  eq([a.byName['GLOBAL'].now, a.byName['PROXY'].now, a.byName['Auto'].now], ['PROXY', 'HK-01', 'JP-02'], 'now');
  const proxy = a.groups.find((g) => g.name === 'PROXY');
  eq(proxy.all.map((n) => n.name), ['HK-01', 'JP-02', 'Auto'], 'members');
  eq(proxy.all.map((n) => n.type), ['Shadowsocks', 'Vmess', 'URLTest'], 'member types');
  eq(proxy.all.map((n) => n.isGroup), [false, false, true], 'member isGroup');
});
check('成员是同一引用（改 byName 里的对象，组里看得到）', () => {
  ok(a.groups[1].all[0] === a.byName['HK-01'], 'not the same object');
});
check('byName 含组本身（按名查类型 / now 可行）', () => {
  eq([a.findNode('Auto').type, a.findNode('Auto').now, a.findNode('nope')], ['URLTest', 'JP-02', null], 'findNode');
  eq(a.findGroup('Auto').now, 'JP-02', 'findGroup');
  eq(a.findGroup('HK-01'), null, 'findGroup on node');
});
check('groupsForMode：rule 过滤 hidden、global 全给、direct 为空', () => {
  eq(a.groupsForMode('rule').map((g) => g.name), ['PROXY', 'Auto'], 'rule');
  eq(a.groupsForMode('global').map((g) => g.name), ['GLOBAL', 'PROXY', 'Auto'], 'global');
  eq(a.groupsForMode('direct'), [], 'direct');
  eq(a.groupsForMode('unknown-mode').map((g) => g.name), ['PROXY', 'Auto'], 'fallback=rule');
});

console.log('\n== payload B：解析（上游 mihomo 形状） ==');
check('parse 成功，组集合含 GLOBAL / Fallback / LB / Relay', () => {
  ok(b !== null, 'parse returned null');
  eq(b.groups.map((g) => g.name), ['GLOBAL', 'Fallback', 'LB', 'Relay'], 'groups');
});
check('组 url 读上游 `url` 键；空 url 保持空', () => {
  eq([b.byName['Fallback'].url, b.byName['LB'].url, b.byName['Relay'].url],
    ['https://www.gstatic.com/generate_204', '', ''], 'url');
});
check('GLOBAL hidden=true（字段 true）；无字段的自建组 hidden=false', () => {
  eq([b.byName['GLOBAL'].hidden, b.byName['Relay'].hidden, b.byName['COMPATIBLE'].hidden], [true, false, false], 'hidden');
});
check('history 末条为负 → lastDelay 原样为 -1（超时），不是 0', () => {
  eq([b.byName['Fallback'].lastDelay, b.byName['LB'].lastDelay, b.byName['US-01'].lastDelay], [-1, -1, -1], 'lastDelay');
});
check('Compatible 是内置节点而非组（组白名单不含它）', () => {
  eq([b.byName['COMPATIBLE'].isGroup, b.byName['COMPATIBLE'].type], [false, 'Compatible'], 'compatible');
});

console.log('\n== parse 的失败面 ==');
check('非 JSON / 无 proxies / proxies 非对象 / 空表 → null（不能当成"没有节点"）', () => {
  eq(
    [
      CoreCatalog.parse(''),
      CoreCatalog.parse('not json'),
      CoreCatalog.parse('{"proxies":null}'),
      CoreCatalog.parse('{"other":{}}'),
      CoreCatalog.parse('{"proxies":[]}'),
      CoreCatalog.parse('{"proxies":{}}'),
      CoreCatalog.parse('{"proxies":{"A":null}}'),
      CoreCatalog.parse('{"proxies":{"A":{"name":"A"}}}')
    ],
    [null, null, null, null, null, null, null, null],
    'null cases'
  );
});
check('缺 type 的信息类条目被跳过，其余照常', () => {
  const m = CoreCatalog.parse('{"proxies":{"X":{"name":"X"},"Y":{"type":"Direct","history":[]}}}');
  eq(Object.keys(m.byName), ['Y'], 'keys');
});
check('成员不在内核表里 → 同名占位节点（type 空、isGroup false）', () => {
  const m = CoreCatalog.parse('{"proxies":{"G":{"type":"Selector","all":["GHOST"],"now":"GHOST"}}}');
  const g = m.groups[0];
  eq([g.all.length, g.all[0].name, g.all[0].type, g.all[0].isGroup], [1, 'GHOST', '', false], 'placeholder');
});

console.log('\n== 排序（DelayState.priority / compareTo） ==');
const N = (name, isGroup = false) => {
  const n = new CoreNode(name, isGroup ? 'Selector' : 'Shadowsocks');
  n.isGroup = isGroup;
  return n;
};
const mixed = [N('HK-01'), N('SUB', true), N('SG-03'), N('JP-02'), N('UNTESTED'), N('TIMEOUT'), N('FAILED')];
const delays = { 'HK-01': 38, 'SUB': 900, 'SG-03': 820, 'JP-02': 38, 'TIMEOUT': -1, 'FAILED': -2 };

check('优先级：>0 → 0，==0 → 1，==-1 → 2，其它 → 3', () => {
  eq([38, 1, 0, -1, -2, -600, NaN].map((d) => CoreCatalog.delayPriority(d)), [0, 0, 1, 2, 3, 3, 3], 'priority');
});
check('组不会因为延迟高就插到快节点前面（组优先只是最后 tiebreak）', () => {
  const sorted = CoreCatalog.sortedNodes(mixed, delays, 'delay');
  eq(sorted.map((n) => n.name), ['HK-01', 'JP-02', 'SG-03', 'SUB', 'UNTESTED', 'TIMEOUT', 'FAILED'], 'order');
  ok(sorted.every((n) => n.name !== 'UNTESTED' || n.isGroup === false), 'untested kept');
});
check('同延迟下组优先；同延迟同组按 name localeCompare', () => {
  const nodes = [N('B'), N('A'), N('GROUP', true)];
  const sorted = CoreCatalog.sortedNodes(nodes, { A: 50, B: 50, GROUP: 50 }, 'delay');
  eq(sorted.map((n) => n.name), ['GROUP', 'A', 'B'], 'tiebreak');
});
check('未测（缺键）落 priority 1，排在成功之后、超时之前', () => {
  const sorted = CoreCatalog.sortedNodes([N('T'), N('U'), N('S')], { T: -1, S: 20 }, 'delay');
  eq(sorted.map((n) => n.name), ['S', 'U', 'T'], 'untested middle');
});
check('sortType=name 用 localeCompare 升序', () => {
  const nodes = [N('node10'), N('Node2'), N('apple'), N('日本')];
  const sorted = CoreCatalog.sortedNodes(nodes, {}, 'name');
  eq(sorted.map((n) => n.name).slice().sort((x, y) => x.localeCompare(y)), sorted.map((n) => n.name), 'locale order');
});
check('sortType=none/未知 → 原顺序', () => {
  eq(CoreCatalog.sortedNodes(mixed, delays, 'none').map((n) => n.name), mixed.map((n) => n.name), 'none');
  eq(CoreCatalog.sortedNodes(mixed, delays, '').map((n) => n.name), mixed.map((n) => n.name), 'empty');
});
check('sortedNodes 不改入参数组', () => {
  const input = [N('B'), N('A')];
  const before = input.map((n) => n.name);
  CoreCatalog.sortedNodes(input, { A: 10, B: 900 }, 'delay');
  eq(input.map((n) => n.name), before, 'input mutated');
});

console.log('\n== 隐藏超时（computeHideTimeout 口径） ==');
const groupWith = (names) => {
  const g = new CoreGroup('PROXY', 'Selector');
  g.now = names[0];
  g.url = 'https://www.gstatic.com/generate_204';
  g.all = names.map((n) => N(n));
  return g;
};
check('hide=false → 原样返回同一数组引用（不做无谓遍历）', () => {
  const groups = [groupWith(['A', 'B'])];
  ok(CoreCatalog.hideTimeout(groups, { A: -1 }, false) === groups, 'not the same array');
});
check('剔除 delay<0 的成员，保留记录缺失与 >0 的成员', () => {
  const groups = [groupWith(['A', 'B', 'C', 'D'])];
  const result = CoreCatalog.hideTimeout(groups, { A: -1, B: -2, C: 120 }, true);
  eq(result[0].all.map((n) => n.name), ['C', 'D'], 'kept');
  eq(result[0].now, 'A', 'now preserved');
  eq(result[0].url, 'https://www.gstatic.com/generate_204', 'url preserved');
});
check('整组被剔光 → 保留原组成员（组和它的测速入口不消失）', () => {
  const groups = [groupWith(['A', 'B'])];
  const result = CoreCatalog.hideTimeout(groups, { A: -1, B: -1 }, true);
  eq(result[0].all.map((n) => n.name), ['A', 'B'], 'all kept');
  ok(result[0] === groups[0], 'should reuse original group object');
});
check('没有任何变化时复用原组对象；有变化时是关键字段齐全的新对象', () => {
  const groups = [groupWith(['A', 'B']), groupWith(['C', 'D'])];
  const result = CoreCatalog.hideTimeout(groups, { A: 10, B: 20, C: -1, D: 30 }, true);
  ok(result[0] === groups[0], 'unchanged group not reused');
  ok(result[1] !== groups[1], 'changed group reused');
  eq([result[1].name, result[1].type, result[1].now, result[1].url, result[1].hidden],
    ['PROXY', 'Selector', 'C', 'https://www.gstatic.com/generate_204', false], 'copied fields');
  eq(groups[1].all.map((n) => n.name), ['C', 'D'], 'input group mutated');
});
check('hideTimeout 不改入参数组', () => {
  const groups = [groupWith(['A', 'B'])];
  CoreCatalog.hideTimeout(groups, { A: -1 }, true);
  eq(groups[0].all.map((n) => n.name), ['A', 'B'], 'input mutated');
});

console.log('\n== 文案与配色（4.3 展示） ==');
check('delayText：>0 → "N ms"；-1 → 超时；0 与其它负值 → 失败；null / NaN → 空', () => {
  eq(
    [38, 1, 599, 600, 1234.7, -1, -2, -600, 0, null, NaN].map((d) => CoreCatalog.delayText(d)),
    ['38 ms', '1 ms', '599 ms', '600 ms', '1234 ms', '超时', '失败', '失败', '失败', '', ''],
    'text'
  );
});
check('delayColor：<0 → error；<600 → success；>=600 → warning（Dart color.dart:333）', () => {
  eq(
    [-1, -2, -600, 0, 1, 599, 600, 1200].map((d) => CoreCatalog.delayColor(d)),
    ['error', 'error', 'error', 'success', 'success', 'success', 'warning', 'warning'],
    'color'
  );
});
check('displayColor 复刻 `delayColor(delay > 0 ? delay : -1)`：0 与负值画 error，null 不画', () => {
  eq([38, 599, 600, 0, -1, -2, null].map((d) => CoreCatalog.displayColor(d)),
    ['success', 'success', 'warning', 'error', 'error', 'error', ''], 'displayColor');
});

console.log('\n== 选择请求（PUT / DELETE） ==');
check('select：PUT /proxies/{group}，body {"name":node}', () => {
  const req = CoreSelection.select('PROXY', 'HK-01');
  eq([req.method, req.path, req.body], ['PUT', '/proxies/PROXY', '{"name":"HK-01"}'], 'select');
});
check('select：组名/节点名做 URL 编码与 JSON 转义', () => {
  const req = CoreSelection.select('A/B 组', 'HK "01"');
  eq(req.path, '/proxies/A%2FB%20%E7%BB%84', 'path escaped');
  eq(JSON.parse(req.body), { name: 'HK "01"' }, 'body escaped');
});
check('unselectAll：DELETE /proxies/{group}，无 body', () => {
  const req = CoreSelection.unselectAll('Auto');
  eq([req.method, req.path, req.body], ['DELETE', '/proxies/Auto', ''], 'unselect');
});
check('两个请求对象互不影响（每次新建）', () => {
  const r1 = CoreSelection.select('A', 'x');
  const r2 = CoreSelection.select('A', 'y');
  ok(r1 !== r2 && r1.body !== r2.body, 'shared instance');
});

fs.rmSync(tmpDir, { recursive: true, force: true });
console.log(`\n${passed} passed, ${failures.length} failed`);
if (failures.length > 0) {
  for (const f of failures) console.log(`  - ${f}`);
  process.exit(1);
}
