#!/usr/bin/env node
/**
 * 分享链接 → 内核代理配置：常用协议转换闸门。
 *
 * 为什么要有这道闸门（2026-10-22 复盘）：
 *  「订阅转换」这条路此前只验证过单条 trojan，结果用户换个协议就发现转换产物不可用
 *  （裸 proxies 没组没规则 → 内核 0 节点 → 测速没反应），另一个协议则因为
 *  `insecure=1` 没被识别而永远连不上。一个一个试的速度跟不上用户试的速度，
 *  所以这里把**所有支持的 scheme** 一次性锁死为契约。
 *
 * 覆盖：
 *   [A] 9 种常用协议各一条真实形态的分享链接 → 必须转出恰好 1 个节点
 *   [B] `insecure` / `allowInsecure` / `skip-cert-verify` 三个参数名都要生效
 *   [C] 密码里含未编码 `/` 的链接必须能解析（机场高频写法）
 *   [D] 「裸节点表」必须被补上分流骨架（select/url-test 组 + MATCH）
 *
 * 做法：SubConverter.ets 是零依赖纯类，直接复制成 .ts 用 Node 的
 * type-stripping 跑（与 verify-tunbox-profile.mjs 同一套手法）。
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

if (!process.execArgv.includes('--experimental-transform-types')
  && process.env.TUNBOX_SUBCONV_CHILD !== '1') {
  const res = spawnSync(
    process.execPath,
    ['--experimental-transform-types', '--no-warnings', fileURLToPath(import.meta.url)],
    { stdio: 'inherit', env: { ...process.env, TUNBOX_SUBCONV_CHILD: '1' } },
  );
  process.exit(res.status === null ? 1 : res.status);
}

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.join(here, '..');
const genDir = path.join(root, 'tools', 'true-chain-harness', 'generated');
const G = (name) => pathToFileURL(path.join(genDir, name)).href;

// harness 的 .ts 产物（与 verify-tunbox-profile.mjs 同一套真源转换）。
// **每次都跑 prepare**：只判文件是否存在会让「改了 .ets 但忘了重新生成」的旧产物
// 通过闸门（本轮就踩过：gate 读到旧 SubConverter.ts，误报 insecure 没修）。
{
  const r = spawnSync(process.execPath,
    [path.join(root, 'tools', 'true-chain-harness', 'prepare.mjs')], { stdio: 'inherit' });
  if (r.status !== 0) {
    console.log('RESULT: FAILED (true-chain-harness/prepare.mjs 执行失败)');
    process.exit(1);
  }
}

let passed = 0;
let failed = 0;
function check(name, ok, detail = '') {
  if (ok) {
    passed++;
  } else {
    failed++;
    console.log(`  ✗ ${name} ${detail}`);
  }
}

const { SubConverter } = await import(G('SubConverter.ts'));
const { ProfileConfigMerger } = await import(G('ProfileConfigMerger.ts'));

// ── [A] 每种协议一条链接 ──────────────────────────────────────────────
const b64 = (s) => Buffer.from(s).toString('base64');
const CASES = [
  ['trojan', 'trojan://pw%2Fx@1.2.3.4:443?security=tls&sni=a.example.com#T'],
  ['trojan (insecure)', 'trojan://pw@1.2.3.4:443?security=tls&sni=a.example.com&insecure=1#T2'],
  ['vless reality', 'vless://11111111-2222-3333-4444-555555555555@5.6.7.8:443?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=abcd&sid=1a&type=tcp#V1'],
  ['vless ws', 'vless://11111111-2222-3333-4444-555555555555@5.6.7.8:8443?encryption=none&security=tls&type=ws&path=%2Fws&host=cdn.example.com#V2'],
  ['vmess', 'vmess://' + b64(JSON.stringify({ v: '2', ps: 'M1', add: '9.9.9.9', port: '443', id: '11111111-2222-3333-4444-555555555555', aid: '0', scy: 'auto', net: 'ws', host: 'h.example.com', path: '/p', tls: 'tls', sni: 'h.example.com' }))],
  ['ss', 'ss://' + Buffer.from('aes-256-gcm:pass').toString('base64') + '@10.0.0.1:8388#S'],
  ['ssr', 'ssr://' + Buffer.from('1.1.1.1:8388:auth_aes128_md5:aes-256-cfb:tls1.2_ticket_auth:cGFzcw/?remarks=UjE').toString('base64url')],
  ['hysteria', 'hysteria://h.example.com:443?auth=pw&peer=h.example.com&insecure=1&upmbps=50&downmbps=100#H1'],
  ['hysteria2', 'hysteria2://pw@h.example.com:443?sni=h.example.com&insecure=1#H2'],
  ['tuic', 'tuic://11111111-2222-3333-4444-555555555555:pw@t.example.com:443?sni=t.example.com&alpn=h3#TU'],
  ['anytls', 'anytls://pw@an.example.com:443?sni=an.example.com&insecure=1#AT'],
];

/** 转出文本里「看起来像节点」的条数（顶层 `- name:` 行） */
function countProxies(yaml) {
  const m = yaml.match(/^\s{2}- name:/gm);
  return m === null ? 0 : m.length;
}

for (const [label, link] of CASES) {
  let out;
  try {
    out = SubConverter.convert(link);
    check(`[A] ${label} 转换不抛异常`, true);
  } catch (e) {
    check(`[A] ${label} 转换不抛异常`, false, String(e));
    continue;
  }
  check(`[A] ${label} ok=true`, out.ok === true, `error=${out.error}`);
  check(`[A] ${label} count=1`, out.count === 1, `count=${out.count}`);
  check(`[A] ${label} 输出含节点行`, countProxies(out.proxiesYaml) === 1);
}

// ── [B] insecure 三个参数名都必须生效 ────────────────────────────────
const INSECURE_CASES = [
  ['insecure', 'trojan://pw@1.2.3.4:443?security=tls&sni=a.com&insecure=1#A'],
  ['allowInsecure', 'trojan://pw@1.2.3.4:443?security=tls&sni=a.com&allowInsecure=1#B'],
  ['skip-cert-verify', 'trojan://pw@1.2.3.4:443?security=tls&sni=a.com&skip-cert-verify=1#C'],
];
for (const [param, link] of INSECURE_CASES) {
  const out = SubConverter.convert(link);
  check(`[B] ${param} → skip-cert-verify: true`,
    /skip-cert-verify:\s*true/.test(out.proxiesYaml), out.proxiesYaml.replace(/\n/g, ' | '));
}
{
  const out = SubConverter.convert('trojan://pw@1.2.3.4:443?security=tls&sni=a.com#D');
  check('[B] 未声明时保持 false', /skip-cert-verify:\s*false/.test(out.proxiesYaml));
}

// ── [C] 密码含未编码 '/' ─────────────────────────────────────────────
{
  const out = SubConverter.convert('trojan://mOP7HYb9Kkm3/E%2Bbj2HJjw@18.182.64.110:8888?security=tls&sni=addons.mozilla.org&insecure=1#AWS-日本-Trojan');
  check('[C] 未编码 / 的链接 count=1', out.count === 1, `count=${out.count} error=${out.error}`);
  check('[C] server 未被污染', /server: 18\.182\.64\.110/.test(out.proxiesYaml), out.proxiesYaml);
  check('[C] 密码完整还原', /password: mOP7HYb9Kkm3\/E\+bj2HJjw/.test(out.proxiesYaml), out.proxiesYaml);
  check('[C] insecure=1 生效', /skip-cert-verify:\s*true/.test(out.proxiesYaml));
}

// ── [D] 裸节点表：FlClash 照抄 —— 不再合成组，原文交内核（GLOBAL 兜底）────────
{
  const mergerSrc = fs.readFileSync(path.join(root, 'entry/src/main/ets/commons/tunbox/ProfileConfigMerger.ets'), 'utf8');
  // 2026-11-05（任务3）：withSyntheticGroups 已删 —— 裸节点 profile 不再补
  // 「手动选择/自动选择 + MATCH」合成组（自造准入推断；FlClash 对裸表 profile
  // 的处理就是原样交内核，GLOBAL 组兜底、无规则时按内核语义路由）。
  check('[D] 合成组已删除（源码不再含 withSyntheticGroups）',
    !mergerSrc.includes('withSyntheticGroups'));
  check('[D] merge 文本层已退场（compose 取代）',
    !mergerSrc.includes('static merge('));
}

console.log(`\n分享链接转换闸门：${passed + failed} 项，PASSED=${passed} FAILED=${failed}`);
if (failed > 0) {
  console.log('RESULT: FAILED');
  process.exit(1);
}
console.log('RESULT: ALL SUB-CONVERT CHECKS PASSED');
