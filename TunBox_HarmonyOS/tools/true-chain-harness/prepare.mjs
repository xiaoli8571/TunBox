// tools/true-chain-harness/prepare.mjs
// 把**真实 ArkTS 源码**转成 Node 可执行的 .ts，仅重写 import 目标 + 注入系统能力 stub，
// 解析/合并/映射逻辑一行不改。与 tools/true-parser-harness/prepare.mjs 同一思路，
// 但覆盖整条链路：ProxyNode → YamlMerger → SubscriptionParser → SubscriptionService
// → ClashConfigGenerator。
//
// 运行: node tools/true-chain-harness/prepare.mjs
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repo = join(here, '..', '..');
const ets = join(repo, 'entry/src/main/ets');
const outDir = join(here, 'generated');
mkdirSync(outDir, { recursive: true });

// 每个真实源文件 → 输出名 + 模块说明符重写表
const FILES = [
  {
    src: 'commons/models/ProxyNode.ets', out: 'ProxyNode.ts', map: {
      '@kit.ArkTS': './stubs.ts',
      // 2026-10-20（yaml-sub 的订阅解析内核化）：ProxyNode 已改走规范解析层
      '../subscription/UriNodeParser': './UriNodeParser.ts',
      '../subscription/ProxyNodeAdapter': './ProxyNodeAdapter.ts',
    },
  },
  { src: 'commons/models/ProxyGroup.ets', out: 'ProxyGroup.ts', map: {} },
  // 2026-10-21：按订阅绑定的 DNS 上游载体（纯数据类，无依赖，不走桩）
  { src: 'commons/models/SubDnsUpstream.ets', out: 'SubDnsUpstream.ts', map: {} },
  { src: 'commons/services/RawProxyYaml.ets', out: 'RawProxyYaml.ts', map: {} },
  // ── 订阅解析内核化（2026-10-20）：规范解析层是真源，不能打桩 ──
  { src: 'commons/subscription/ProtocolParamTable.ets', out: 'ProtocolParamTable.ts', map: {} },
  {
    src: 'commons/subscription/NodeUsability.ets', out: 'NodeUsability.ts', map: {
      './ProtocolParamTable': './ProtocolParamTable.ts',
    },
  },
  {
    src: 'commons/subscription/UnusableLedger.ets', out: 'UnusableLedger.ts', map: {
      './NodeUsability': './NodeUsability.ts',
    },
  },
  {
    src: 'commons/subscription/UriNodeParser.ets', out: 'UriNodeParser.ts', map: {
      './ProtocolParamTable': './ProtocolParamTable.ts',
      './NodeUsability': './NodeUsability.ts',
      './UnusableLedger': './UnusableLedger.ts',
    },
  },
  {
    // 2026-10-20：适配器已改为**纯映射**（不再 import ProxyNode）⇒ 无循环依赖
    src: 'commons/subscription/ProxyNodeAdapter.ets', out: 'ProxyNodeAdapter.ts', map: {
      './ProtocolParamTable': './ProtocolParamTable.ts',
    },
  },
  {
    src: 'commons/subscription/YamlNodeAdapter.ets', out: 'YamlNodeAdapter.ts', map: {
      '../services/YamlMerger': './YamlMerger.ts',
      './ProtocolParamTable': './ProtocolParamTable.ts',
      './NodeUsability': './NodeUsability.ts',
    },
  },
  {
    src: 'commons/subscription/BodyDispatch.ets', out: 'BodyDispatch.ts', map: {
      '../services/YamlMerger': './YamlMerger.ts',
      './UriNodeParser': './UriNodeParser.ts',
    },
  },
  // 测速地址唯一真源（零 import ⇒ 任何层都能安全引）
  { src: 'commons/latency/LatencyTestUrl.ets', out: 'LatencyTestUrl.ts', map: {} },
  { src: 'commons/latency/LatencyKinds.ets', out: 'LatencyKinds.ts', map: {} },
  {
    src: 'commons/services/YamlMerger.ets', out: 'YamlMerger.ts',
    map: { '@kit.ArkTS': './stubs.ts' },
  },
  {
    src: 'commons/services/SubscriptionParser.ets', out: 'SubscriptionParser.ts', map: {
      '../models/ProxyNode': './ProxyNode.ts',
      '../models/ProxyGroup': './ProxyGroup.ts',
      '../models/SubDnsUpstream': './SubDnsUpstream.ts',
      './YamlMerger': './YamlMerger.ts',
      '../utils/AppLogger': './stubs.ts',
      // 2026-10-20（B6 旧解析器退场）：链接列表改走规范解析层
      '../subscription/UriNodeParser': './UriNodeParser.ts',
      // 2026-10-24：YAML 路径信息条目过滤
      '../subscription/NodeUsability': './NodeUsability.ts',
      '../subscription/UnusableLedger': './UnusableLedger.ts',
    },
  },
  {
    src: 'commons/models/Subscription.ets', out: 'Subscription.ts', map: {
      '../services/SubscriptionService': './stubs.ts',
    },
  },
  {
    src: 'commons/services/LatencyState.ets', out: 'LatencyState.ts', map: {
      // 2026-10-20（latency-core 的测速分类真源）：LatencyState 引用了它
      '../latency/LatencyKinds': './LatencyKinds.ts',
    },
  },
  {
    src: 'commons/services/NodeSortPersistence.ets', out: 'NodeSortPersistence.ts', map: {
      '../models/ProxyNode': './ProxyNode.ts',
      './ClashApiService': './stubs.ts',
      './LatencyState': './LatencyState.ts',
    },
  },
  {
    src: 'commons/models/AppSettings.ets', out: 'AppSettings.ts', map: {
      '../services/NodeSortPersistence': './NodeSortPersistence.ts',
      '../services/AppRoutingPolicy': './AppRoutingPolicy.ts',
      // 2026-10-20（ND06 收口）：测速地址常量收口到零 import 的真源模块。
      '../latency/LatencyTestUrl': './LatencyTestUrl.ts',
      '../services/SettingsService': './stubs.ts',
      '../services/ProxyGroupStore': './stubs.ts',
      '../services/ManualNodeStore': './stubs.ts',
      '../services/CredentialStore': './stubs.ts',
      '../services/SubscriptionService': './stubs.ts',
      '../services/NodeSortModes': './NodeSortModes.ts',
      '../models/ProxyNode': './ProxyNode.ts',
      '../utils/AppLogger': './stubs.ts',
      // 2026-10-20（latency-core 的测速地址唯一真源）：AppSettings 也引用了它
      '../latency/LatencyTestUrl': './LatencyTestUrl.ts',
    },
  },
  {
    src: 'commons/services/AppRoutingPolicy.ets', out: 'AppRoutingPolicy.ts', map: {
      '../utils/AppLogger': './stubs.ts',
    },
  },
  {
    src: 'commons/services/SubscriptionService.ets', out: 'SubscriptionService.ts', map: {
      './SubscriptionQuotaService': './SubscriptionQuotaService.ts',
      './LocalSubConverter': './LocalSubConverter.ts',
      '@kit.ArkData': './stubs.ts',
      '@kit.AssetStoreKit': './stubs.ts',
      '@kit.ArkTS': './stubs.ts',
      '../models/Subscription': './Subscription.ts',
      '../models/ProxyNode': './ProxyNode.ts',
      '../models/ProxyGroup': './ProxyGroup.ts',
      '../models/AppSettings': './AppSettings.ts',
      '../models/SubDnsUpstream': './SubDnsUpstream.ts',
      './SubscriptionParser': './SubscriptionParser.ts',
      './SubscriptionFetchPolicy': './stubs.ts',
      './SettingsService': './stubs.ts',
      './YamlMerger': './YamlMerger.ts',
      './ClashConfigGenerator': './ClashConfigGenerator.ts',
      './ProxyProviderParser': './ProxyProviderParser.ts',
      './RawSubscriptionStore': './stubs.ts',
      './RawProxyYaml': './RawProxyYaml.ts',
      './CredentialStore': './stubs.ts',
      '../utils/AppLogger': './stubs.ts',
      './ConcurrentRefresh': './ConcurrentRefresh.ts',
      // 2026-10-20（yaml-sub 的订阅解析内核化）
      '../subscription/BodyDispatch': './BodyDispatch.ts',
      '../subscription/YamlNodeAdapter': './YamlNodeAdapter.ts',
      '../subscription/NodeUsability': './NodeUsability.ts',
      '../subscription/UnusableLedger': './UnusableLedger.ts',
      // 2026-10-20（B6 旧解析器退场）：直链导入/凭据回退改走规范解析层
      '../subscription/UriNodeParser': './UriNodeParser.ts',
      // 2026-10-22（FlClash 同构）：订阅原文落成 profile 文件
      '../flclash/ProfileStore': './ProfileStore.ts',
      '../../core/CoreBridge': './stubs.ts',
      '../flclash/SubConverter': './SubConverter.ts',
      '../flclash/CoreCatalogService': './stubs.ts',
      '../flclash/CoreNodeBridge': './stubs.ts',
    },
  },
  {
    src: 'commons/services/SubscriptionQuotaService.ets', out: 'SubscriptionQuotaService.ts', map: {
      '@kit.NotificationKit': './stubs.ts',
      '@kit.BasicServicesKit': './stubs.ts',
      '../utils/AppLogger': './stubs.ts',
      '../models/Subscription': './Subscription.ts',
      './SettingsService': './stubs.ts',
      '../models/AppSettings': './AppSettings.ts',
    },
  },
  {
    src: 'commons/services/ProxyProviderParser.ets', out: 'ProxyProviderParser.ts', map: {
      '../utils/AppLogger': './stubs.ts',
      './YamlMerger': './YamlMerger.ts',
    },
  },
  {
    src: 'commons/services/ConcurrentRefresh.ets', out: 'ConcurrentRefresh.ts', map: {},
  },
  {
    src: 'commons/services/ClashConfigGenerator.ets', out: 'ClashConfigGenerator.ts', map: {
      '../models/ProxyNode': './ProxyNode.ts',
      '../models/ProxyGroup': './ProxyGroup.ts',
      '../models/AppSettings': './AppSettings.ts',
      '../models/SubDnsUpstream': './SubDnsUpstream.ts',
      './YamlMerger': './YamlMerger.ts',
      '../utils/AppLogger': './stubs.ts',
      './RawSubscriptionStore': './stubs.ts',
      './RawProxyYaml': './RawProxyYaml.ts',
      // 2026-10-20（A12c）：测速地址唯一真源
      '../latency/LatencyTestUrl': './LatencyTestUrl.ts',
    },
  },
  // 2026-10-22：订阅转换（设置页把分享链接转成 mihomo 订阅）—— 纯逻辑，真源直跑
  {
    src: 'commons/services/LocalSubConverter.ets', out: 'LocalSubConverter.ts', map: {
      '@kit.ArkData': './stubs.ts',
      '@kit.ArkTS': './stubs.ts',
      '../models/ProxyNode': './ProxyNode.ts',
      './ClashConfigGenerator': './ClashConfigGenerator.ts',
      '../subscription/UriNodeParser': './UriNodeParser.ts',
      '../utils/AppLogger': './stubs.ts',
    },
  },
  // ── 2026-10-22：FlClash 1:1 复刻（订阅原文 = profile；节点目录来自内核）──
  {
    src: 'commons/flclash/ProfileConfigMerger.ets', out: 'ProfileConfigMerger.ts', map: {
      '../services/YamlMerger': './YamlMerger.ts',
      '../utils/AppLogger': './stubs.ts',
    },
  },
  // convertProxies（mihomo ConvertsV2Ray 的 ArkTS 移植；零 import）
  { src: 'commons/flclash/SubConverter.ets', out: 'SubConverter.ts', map: {} },
  // 内核目录解析（零 import，纯函数）
  { src: 'commons/flclash/CoreCatalog.ets', out: 'CoreCatalog.ts', map: {} },
  {
    src: 'commons/flclash/ProfileStore.ets', out: 'ProfileStore.ts', map: {
      '@kit.ArkData': './stubs.ts',
      '@kit.CoreFileKit': './stubs.ts',
      '@kit.ArkTS': './stubs.ts',
      '../utils/AppLogger': './stubs.ts',
      './ProfileConfigMerger': './ProfileConfigMerger.ts',
      '../subscription/BodyDispatch': './BodyDispatch.ts',
    },
  },
];

// 匹配 import ... from 'spec'（含多行命名导入）与 import spec from 'spec'
const IMPORT_RE = /import\s+(?:type\s+)?(?:([A-Za-z_$][\w$]*)\s*,\s*)?(?:\{([^}]*)\}|\*\s+as\s+[A-Za-z_$][\w$]*|([A-Za-z_$][\w$]*))?\s*from\s*'([^']+)'/g;

const REPORT = [];
for (const f of FILES) {
  const srcPath = join(ets, f.src);
  const orig = readFileSync(srcPath, 'utf8');
  const unresolved = [];
  const stripped = [];
  const text = orig.replace(IMPORT_RE, (m, def1, named, def2, spec) => {
    const target = f.map[spec];
    if (target === undefined) {
      unresolved.push(spec);
      return `/* [harness-UNRESOLVED] ${m} */`;
    }
    if (target === './stubs.ts') {
      stripped.push(spec);
    }
    // 只改模块说明符，保留导入形式
    return m.replace(`'${spec}'`, `'${target}'`);
  });
  if (unresolved.length > 0) {
    console.error(`[prepare] FAIL ${f.src}: unresolved imports -> ${unresolved.join(', ')}`);
    process.exit(2);
  }
  // Node 的 transform-types 会擦除 interface，但不会自动擦除普通具名导入。
  // ProxyGroupJson 仅用于类型标注，生成 harness 时移除该运行时导入项。
  const runnableText = text.replace(
    "import { ProxyGroup, ProxyGroupJson } from './ProxyGroup.ts';",
    "import { ProxyGroup } from './ProxyGroup.ts';"
  );
  const header = `// [harness] generated from entry/src/main/ets/${f.src} — 仅 import 目标被重写\n`;
  writeFileSync(join(outDir, f.out), header + runnableText, 'utf8');
  const changed = text.split('\n').filter((l, i) => l !== orig.split('\n')[i]).length;
  REPORT.push({ src: f.src, out: f.out, lines: orig.split('\n').length, rewrittenImportLines: changed, stubbed: stripped.join(',') || '-' });
}
for (const r of REPORT) {
  console.log(`[prepare] ${r.src} -> generated/${r.out} lines=${r.lines} rewrittenImportLines=${r.rewrittenImportLines} stubSources=${r.stubbed}`);
}
// 手写的测试替身（系统能力/网络/持久化边界）复制到 generated/，使重写后的相对导入可解析
const stubSrc = readFileSync(join(here, 'stubs.ts'), 'utf8');
writeFileSync(join(outDir, 'stubs.ts'), stubSrc, 'utf8');
console.log('[prepare] stubs.ts -> generated/stubs.ts (hand-written test double, no parsing logic)');
