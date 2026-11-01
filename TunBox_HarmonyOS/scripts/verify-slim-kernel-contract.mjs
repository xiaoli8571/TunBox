#!/usr/bin/env node
/**
 * 内核裁剪与前端拦截的一致性闸门（Slim Kernel Contract Gate）
 *
 * ## 为什么必须成对存在
 *
 * 0.8.0 起内核用 `no_tailscale,no_zerotier,no_easytier` 编译，这三个 outbound
 * 在 libgojni.so 里已经不存在（省 6.26MB 包体）。但 mihomo 对**未知协议类型**
 * 的处理是致命的：
 *
 *   adapter/parser.go:  default: return nil, fmt.Errorf("unsupport proxy type: %s")
 *   config/config.go:922  proxy, err := adapter.ParseProxy(...)
 *                         if err != nil { return nil, nil, fmt.Errorf("proxy %d: %w", ...) }
 *
 * 一条节点解析失败 ⇒ **整份配置拒载**，不是丢掉那一个节点。
 *
 * 而 `ClashConfigGenerator.dropReasonFor()` 的白名单末尾是
 * `YamlMerger.isRelayType(proxyType)`，它带兜底正则 `/^[a-z][a-z0-9-]{0,31}$/`
 * —— tailscale / zerotier / easytier 全部匹配。所以只要前端不显式拦，
 * 订阅里有一条 tailscale 节点，用户的整个代理就起不来。
 *
 * 这个闸门守的就是这对契约：
 *   内核编译 tag 里裁掉的协议  ⇄  前端 dropReasonFor 里必须拦的协议
 * 任何一边改了另一边没跟上，都会让上面那条致命路径重新打开。
 *
 * ## 跑法
 *
 *   node scripts/verify-slim-kernel-contract.mjs
 *   node scripts/verify-slim-kernel-contract.mjs --self-test
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PROJ = path.resolve(HERE, '..');

/**
 * 内核被裁掉的协议 → 对应的 Go build tag。
 * 新增裁剪项时这张表必须同步加，否则闸门查不到。
 */
const STRIPPED = [
  { protocol: 'tailscale', tag: 'no_tailscale' },
  { protocol: 'zerotier', tag: 'no_zerotier' },
  { protocol: 'easytier', tag: 'no_easytier' }
];

/** 必须保留的 tag（裁掉会让功能真的坏） */
const REQUIRED_TAGS = [
  { tag: 'with_gvisor', why: 'WireGuard 出站的用户态 IP 栈依赖它' },
  { tag: 'cmfa', why: 'mihomo 的移动端适配（含 HarmonyOS VPN fd 注入路径）' }
];

const results = [];
function check(name, fn) {
  try {
    fn();
    results.push({ name, ok: true });
    console.log(`PASS  ${name}`);
  } catch (e) {
    results.push({ name, ok: false, err: e.message });
    console.log(`FAIL  ${name}\n      ${e.message}`);
  }
}

function read(p) {
  return fs.readFileSync(p, 'utf8');
}

function main() {
  console.log('== 瘦身内核契约闸门 ==');

  const ps1 = path.join(PROJ, 'scripts', 'build-ohos-core.ps1');
  const sh = path.join(PROJ, 'scripts', 'build-ohos-core.sh');
  const gen = path.join(PROJ, 'entry', 'src', 'main', 'ets', 'commons', 'services',
    'ClashConfigGenerator.ets');

  check('build-ohos-core.ps1 存在', () => assert.ok(fs.existsSync(ps1), `缺少 ${ps1}`));
  check('build-ohos-core.sh 存在', () => assert.ok(fs.existsSync(sh), `缺少 ${sh}`));
  check('ClashConfigGenerator.ets 存在', () => assert.ok(fs.existsSync(gen), `缺少 ${gen}`));

  const ps1Text = fs.existsSync(ps1) ? read(ps1) : '';
  const shText = fs.existsSync(sh) ? read(sh) : '';
  const genText = fs.existsSync(gen) ? read(gen) : '';

  // ── 1. 两个构建脚本的 tag 必须一致，且都带上全部裁剪 tag ──
  for (const file of [{ name: 'build-ohos-core.ps1', text: ps1Text },
    { name: 'build-ohos-core.sh', text: shText }]) {
    for (const { protocol, tag } of STRIPPED) {
      check(`${file.name} 带 ${tag}（裁掉 ${protocol}）`, () => {
        assert.ok(file.text.includes(tag),
          `脚本里找不到 ${tag}。内核会重新编进 ${protocol}，包体白涨 6MB。`);
      });
    }
    for (const { tag, why } of REQUIRED_TAGS) {
      check(`${file.name} 保留 ${tag}`, () => {
        assert.ok(file.text.includes(tag), `脚本里丢了 ${tag} —— ${why}`);
      });
    }
  }

  check('两个构建脚本的 tag 集合一致', () => {
    const grab = (t) => {
      const m = t.match(/-tags\s+"?([a-z0-9_,]+)"?/);
      assert.ok(m, '找不到 -tags 参数');
      return new Set(m[1].split(',').map(s => s.trim()).filter(Boolean));
    };
    const a = grab(ps1Text);
    const b = grab(shText);
    const onlyPs1 = [...a].filter(x => !b.has(x));
    const onlySh = [...b].filter(x => !a.has(x));
    assert.equal(onlyPs1.length + onlySh.length, 0,
      `.ps1 独有: [${onlyPs1}]，.sh 独有: [${onlySh}]。两个脚本必须编出同一个内核。`);
  });

  // ── 2. 前端必须显式拦掉被裁协议（这是防止整份配置拒载的唯一屏障） ──
  /**
   * 去掉 `//` 行注释后再做位置判定。
   *
   * 为什么必须去注释：dropReasonFor 上方的说明注释里就写着
   * `YamlMerger.isRelayType()` 和 `tailscale / zerotier / easytier` 这些字面量。
   * 不剥注释时 indexOf('isRelayType(') 会先命中注释，导致「代码里其实拦在前面」
   * 也被误判成「拦在后面」。注释不是行为，判据只看代码。
   */
  const stripLineComments = (src) =>
    src.split('\n').map(line => {
      const i = line.indexOf('//');
      return i >= 0 ? line.slice(0, i) : line;
    }).join('\n');

  for (const { protocol } of STRIPPED) {
    check(`dropReasonFor 显式拦 ${protocol}`, () => {
      const fnStart = genText.indexOf('static dropReasonFor(');
      assert.ok(fnStart >= 0, '找不到 dropReasonFor');
      const fnBody = stripLineComments(genText.slice(fnStart, fnStart + 4000));
      const relayIdx = fnBody.indexOf('isRelayType(');
      const idx = fnBody.indexOf(`'${protocol}'`);
      assert.ok(idx >= 0,
        `dropReasonFor 里没有 '${protocol}' 分支。该协议内核已裁掉，`
        + `不拦就会被写进配置 ⇒ 内核整份拒载 ⇒ 用户整个代理起不来。`);
      if (relayIdx >= 0) {
        assert.ok(idx < relayIdx,
          `'${protocol}' 的判定出现在 isRelayType() 之后 —— isRelayType 的兜底正则`
          + ` /^[a-z][a-z0-9-]{0,31}$/ 会先把它放行，等于没拦。必须前置短路。`);
      }
    });
  }

  // ── 3. 被裁协议不得出现在任何「支持协议」枚举里 ──
  const enumerations = [
    { file: 'NodeSortPersistence.ets', rel: 'entry/src/main/ets/commons/services/NodeSortPersistence.ets' },
    { file: 'YamlMerger.ets', rel: 'entry/src/main/ets/commons/services/YamlMerger.ets' }
  ];
  for (const { protocol } of STRIPPED) {
    for (const en of enumerations) {
      const p = path.join(PROJ, en.rel);
      if (!fs.existsSync(p)) {
        continue;
      }
      check(`${en.file} 不把 ${protocol} 列为支持协议`, () => {
        const t = read(p);
        const re = new RegExp(`case\\s+'${protocol}'|'${protocol}'\\s*:`);
        assert.equal(re.test(t), false,
          `${en.file} 仍把 ${protocol} 当成可展示/可支持的协议。`
          + ` 内核已无此 outbound，展示出来只会让用户选了必然失败的节点。`);
      });
    }
  }

  // ── 4. 已构建的 libgojni.so（若存在）不得再含这些协议栈 ──
  const so = path.join(PROJ, 'entry', 'libs', 'arm64-v8a', 'libgojni.so');
  if (fs.existsSync(so)) {
    const buf = fs.readFileSync(so);
    // 二进制里仍会有少量命中（错误文案、注释），用一个远低于旧版的数量做判据：
    // 旧版 tailscale≈11213 / easytier≈5866 / zerotier≈1210，裁掉后都是个位数~几十。
    const LIMITS = { tailscale: 200, zerotier: 100, easytier: 200 };
    for (const [needle, limit] of Object.entries(LIMITS)) {
      check(`libgojni.so 已裁掉 ${needle}（命中 < ${limit}）`, () => {
        let count = 0;
        let at = -1;
        const pat = Buffer.from(needle, 'utf8');
        while ((at = buf.indexOf(pat, at + 1)) !== -1) {
          count++;
        }
        assert.ok(count < limit,
          `libgojni.so 里 "${needle}" 命中 ${count} 次（阈值 ${limit}）—— `
          + `这个 .so 还是裁剪前的产物，请用 scripts/build-ohos-core 重新编译。`);
      });
    }
  } else {
    console.log('NOTE  libgojni.so 不存在，跳过二进制抽查（未编译过内核）');
  }

  // ── 5. 负对照 ──
  if (process.argv.includes('--self-test')) {
    console.log('');
    console.log('== 负对照 ==');
    check('[负对照] 未加 no_* tag 的脚本应被判为不合规', () => {
      const fake = '$argLine = \'build -tags with_gvisor,cmfa -ldflags ...\'';
      assert.equal(fake.includes('no_tailscale'), false);
    });
    check('[负对照] isRelayType 兜底正则会放行 tailscale（必须靠前置短路兜住）', () => {
      const re = /^[a-z][a-z0-9-]{0,31}$/;
      assert.equal(re.test('tailscale'), true);
      assert.equal(re.test('zerotier'), true);
      assert.equal(re.test('easytier'), true);
    });
  }

  const failed = results.filter(r => !r.ok);
  console.log('');
  console.log(`PASSED=${results.length - failed.length}  FAILED=${failed.length}  TOTAL=${results.length}`);
  if (failed.length > 0) {
    console.log('RESULT: SLIM KERNEL CONTRACT FAILED');
    process.exitCode = 1;
  } else {
    console.log('RESULT: SLIM KERNEL CONTRACT PASSED');
  }
}

main();
