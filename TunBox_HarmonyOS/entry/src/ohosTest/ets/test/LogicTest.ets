import { describe, it, expect } from '@ohos/hypium';
import { SubscriptionParser } from '../../../main/ets/commons/services/SubscriptionParser';
import { ClashConfigGenerator } from '../../../main/ets/commons/services/ClashConfigGenerator';
import { NodeCountryPolicy } from '../../../main/ets/commons/services/PublicIpService';
import { SubscriptionFetchPolicy } from '../../../main/ets/commons/services/SubscriptionFetchPolicy';
import { LogRedactor } from '../../../main/ets/commons/utils/AppLogger';
import { YamlMerger } from '../../../main/ets/commons/services/YamlMerger';
import {
  HEARTBEAT_STALE_MS, CoreLivenessProbe, isHeartbeatFresh, resolveAuthority,
  shouldExecuteDisconnect, shouldSuppressConnect
} from '../../../main/ets/commons/services/TunnelAuthority';
import { LatencyStyle, NodeDisplay } from '../../../main/ets/theme/UiTokens';
import { LatencyController } from '../../../main/ets/commons/services/LatencyController';
import {
  NodeSortSnapshot, NodeSortModes, NodeLatencyRecord, NodeProtocolPolicy
} from '../../../main/ets/commons/services/NodeSortPersistence';
import { ProxyNode, ProxyNodeType } from '../../../main/ets/commons/models/ProxyNode';
import { ProxyGroup } from '../../../main/ets/commons/models/ProxyGroup';
import { AppSettings, AppSettingsJson } from '../../../main/ets/commons/models/AppSettings';
import {
  MAX_STATE_FILE_BYTES, PRIVATE_CONFIG_FILE, PRIVATE_TEST_CONFIG_FILE, PrivateFs,
  SyncReadResult, clearPrivateArtifacts, heartbeatAgeFromText, parseHeartbeatTimestamp,
  removeFilesIndependently
} from '../../../main/ets/commons/services/RuntimeFilePolicy';
import {
  SingleFlightTestCore, TestCoreStatus
} from '../../../main/ets/commons/services/TestCoreFlight';
import {
  BEARER_BLUETOOTH, BEARER_CELLULAR, BEARER_ETHERNET, BEARER_VPN, BEARER_WIFI,
  NET_DEBOUNCE_MS, NetTypes, NetworkStateListener, NetworkStateWatcher,
  normalizeNetType, shouldEmit
} from '../../../main/ets/commons/services/NetworkStateWatcher';
import {
  CheckIds, DEFAULT_MAX_REPAIR_STEPS, HealthOverall, HealthStatus, LinkHealthChecker,
  LinkHealthItem, LinkHealthProbes, LinkHealthReport, ProbeOutcome, RepairActions,
  repairForCheck, repairSteps, summarize
} from '../../../main/ets/commons/services/LinkHealthChecker';
import {
  LATENCY_FAILED, LATENCY_UNTESTED, MAX_SELECT_CONCURRENCY, NodeCandidate, RankedNode, SelectorOptions,
  failoverAllowed, isEligible, isInCooldown, markFailure, markSuccess, nextBestNode,
  normalizeOptions, orderedNames, rankNodes, scoreOf, selectConcurrency
} from '../../../main/ets/commons/services/SmartSelector';

/**
 * 测试用网络监听者。ArkTS 严格模式禁止用对象字面量实现接口（arkts-no-untyped-obj-literals，
 * 带方法的接口尤甚），因此改为类实现，并把记录数组/抛异常行为由构造参数注入，
 * 使既有的 seen/gens/good 断言无需改动。
 */
class RecordingNetworkListener implements NetworkStateListener {
  private readonly types: string[];
  private readonly generations: number[];
  private readonly shouldThrow: boolean;

  constructor(types: string[], generations: number[], shouldThrow: boolean) {
    this.types = types;
    this.generations = generations;
    this.shouldThrow = shouldThrow;
  }

  onNetworkTypeChanged(type: string, generation: number): void {
    if (this.shouldThrow) {
      throw new Error('listener boom');
    }
    this.types.push(type);
    this.generations.push(generation);
  }
}

/**
 * 内存文件系统桩：精确模拟「部分文件缺失」「一个文件删除失败」两类场景，
 * 并记录写入/删除/取消调用次数，用于验证清理容错与单航班语义。
 */
class FakePrivateFs implements PrivateFs {
  files: Map<string, string> = new Map<string, string>();
  /** 这些路径的 remove() 必须失败（模拟被占用/权限不足） */
  undeletable: Set<string> = new Set<string>();
  removeCalls: number = 0;

  writePrivate(path: string, content: string): void {
    this.files.set(path, content);
  }

  readCapped(path: string, maxBytes: number): SyncReadResult {
    const raw = this.files.get(path);
    if (raw === undefined) {
      return { ok: false, text: '', truncated: false };
    }
    return { ok: true, text: raw, truncated: raw.length > maxBytes };
  }

  /** 异步版与同步版同语义（测试用内存 Map，无真实 IO） */
  async readCappedAsync(path: string, maxBytes: number): Promise<SyncReadResult> {
    return this.readCapped(path, maxBytes);
  }

  remove(path: string): boolean {
    this.removeCalls = this.removeCalls + 1;
    if (this.undeletable.has(path)) {
      return false;
    }
    return this.files.delete(path);
  }

  exists(path: string): boolean {
    return this.files.has(path);
  }
}

export default function logicTest() {
  describe('tunboxLogicTest', () => {
    it('ssr_parse', 0, () => {
      // ssr:// 1.2.3.4:8388:origin:aes-256-cfb:plain:<base64("pass")>/?remarks=<base64("测试")>
      const pass = 'cGFzcw==';
      const remarks = '5rGf6IO9';
      const uri = `ssr://1.2.3.4:8388:origin:aes-256-cfb:plain:${pass}/?remarks=${remarks}&obfsparam=`;
      const nodes = SubscriptionParser.parse(uri, 'sub1');
      expect(nodes.length).assertEqual(1);
      expect(nodes[0].server).assertEqual('1.2.3.4');
      expect(nodes[0].port).assertEqual(8388);
      expect(nodes[0].method).assertEqual('aes-256-cfb');
      expect(nodes[0].password).assertEqual('pass');
      expect(nodes[0].name).assertEqual('测试');
    });

    it('ss_parse_sip002', 0, () => {
      // ss:// base64("aes-256-gcm:secret")@example.com:443#节点名
      const userInfo = 'YWVzLTI1Ni1nY206c2VjcmV0';
      const uri = `ss://${userInfo}@example.com:443#%E6%97%A5%E6%9C%AC01`;
      const nodes = SubscriptionParser.parse(uri, 'sub1');
      expect(nodes.length).assertEqual(1);
      expect(nodes[0].server).assertEqual('example.com');
      expect(nodes[0].port).assertEqual(443);
      expect(nodes[0].method).assertEqual('aes-256-gcm');
      expect(nodes[0].password).assertEqual('secret');
      expect(nodes[0].name).assertEqual('日本01');
    });

    it('base64_subscription', 0, () => {
      const line = 'ssr://MS4yLjMuNDo4Mzg4Om9yaWdpbjphZXMtMjU2LWNmYjpwbGFpbjpjR0Z6YzNJPz9yZW1hcmtzPQ==';
      const nodes = SubscriptionParser.parse(line, 'sub1');
      expect(nodes.length >= 1).assertTrue();
    });

    it('clash_yaml_parse', 0, () => {
      const yaml = 'port: 7890\nproxies:\n' +
        "  - {name: 'HK-01', type: ss, server: h.example.com, port: 443, cipher: aes-128-gcm, password: 'pw1'}\n" +
        "  - {name: 'US-01', type: ssr, server: u.example.com, port: 8388, cipher: aes-256-cfb, password: 'pw2', protocol: origin, obfs: plain}\n";
      const nodes = SubscriptionParser.parse(yaml, 'sub2');
      expect(nodes.length).assertEqual(2);
      expect(nodes[0].name).assertEqual('HK-01');
      expect(nodes[1].type === 'ssr').assertTrue();
    });

    it('config_generator_ipv4_only_and_mode', 0, () => {
      const s = new AppSettings();
      const node = new ProxyNode();
      node.name = 'HK-01';
      node.server = 'h.example.com';
      node.port = 443;
      node.method = 'aes-128-gcm';
      node.password = 'pw';
      const yaml = ClashConfigGenerator.generate(node, [node], s, 7890, 9090, 1053, 'sec');
      expect(yaml.includes('ipv6: false')).assertTrue();
      expect(yaml.includes('mode: rule')).assertTrue();
      expect(yaml.includes('external-controller: 127.0.0.1:9090')).assertTrue();
      expect(yaml.includes('GEOIP,CN,DIRECT')).assertTrue();
      const sGlobal = new AppSettings();
      sGlobal.proxyMode = 'global';
      const yamlGlobal = ClashConfigGenerator.generate(node, [node], sGlobal, 7890, 9090, 1053, 'sec');
      expect(yamlGlobal.includes('mode: global')).assertTrue();
      expect(yamlGlobal.includes('MATCH,PROXY')).assertTrue();
    });

    it('config_generator_force_sites', 0, () => {
      const s = new AppSettings();
      s.forceProxySites = ['openai.com'];
      const node = new ProxyNode();
      node.name = 'n';
      node.server = 's';
      node.port = 1;
      node.method = 'aes-128-gcm';
      node.password = 'p';
      const yaml = ClashConfigGenerator.generate(node, [node], s, 7890, 9090, 1053, 'sec');
      expect(yaml.includes('DOMAIN-SUFFIX,openai.com,PROXY')).assertTrue();
    });

    it('config_generator_rule_target_must_be_emitted', 0, () => {
      // 回归（2026-10-19 用户报障）：订阅组被 planProxyGroups 丢弃（空成员无法落地）后，
      // 引用它的规则必须一并跳过。否则内核 config.Parse 报
      //   parse config:rules[0] [DOMAIN-SUFFIX,local, 本地直连] error: proxy not found
      // 整份配置拒载 → 启动代理失败。
      const s = new AppSettings();
      const node = new ProxyNode();
      node.name = 'HK-01';
      node.server = 'h.example.com';
      node.port = 443;
      node.method = 'aes-128-gcm';
      node.password = 'pw';

      const dead = new ProxyGroup();
      dead.name = '本地直连';
      dead.groupType = 'select';
      dead.members = [];
      const yamlDead = ClashConfigGenerator.generate(node, [node], s, 7890, 9090, 1053, 'sec',
        true, false, {}, true, [dead], true, false,
        ['DOMAIN-SUFFIX,local,本地直连']);
      expect(yamlDead.includes('DOMAIN-SUFFIX,local,本地直连')).assertFalse();

      // 对照组：组能落地（成员是真实节点）时规则必须保留，别误杀。
      const live = new ProxyGroup();
      live.name = '本地直连';
      live.groupType = 'select';
      live.members = ['HK-01'];
      const yamlLive = ClashConfigGenerator.generate(node, [node], s, 7890, 9090, 1053, 'sec',
        true, false, {}, true, [live], true, false,
        ['DOMAIN-SUFFIX,local,本地直连']);
      expect(yamlLive.includes('DOMAIN-SUFFIX,local,本地直连')).assertTrue();
    });

    it('config_generator_normalizes_rule_whitespace', 0, () => {
      // 逗号后带空格的规则（用户报障原文 `DOMAIN-SUFFIX,local, 本地直连`）写盘时
      // 必须归一，避免校验（trim 过）与写盘（原始行）语义不一致。
      expect(ClashConfigGenerator.normalizeRuleLine('DOMAIN-SUFFIX,local, 本地直连'))
        .assertEqual('DOMAIN-SUFFIX,local,本地直连');
    });

    it('country_detect', 0, () => {
      expect(NodeCountryPolicy.detect('🇭🇰 香港 IEPL 01').code).assertEqual('HK');
      expect(NodeCountryPolicy.detect('Japan Tokyo 02').code).assertEqual('JP');
      expect(NodeCountryPolicy.detect('unknown-node').code).assertEqual('XX');
    });

    it('log_redact', 0, () => {
      const red = LogRedactor.redact('connect password=abc123 to https://sub.example.com/token123');
      expect(red.includes('abc123')).assertFalse();
      expect(red.includes('password=***')).assertTrue();
    });

    it('node_display', 0, () => {
      expect(NodeDisplay.withoutLeadingFlag('🇭🇰 香港 01')).assertEqual('香港 01');
      const long = 'a'.repeat(40);
      expect(NodeDisplay.compact(long).length).assertLarger(0);
      expect(NodeDisplay.compact(long).length).assertLessOrEqual(24);
    });

    it('latency_style', 0, () => {
      expect(LatencyStyle.color(null)).assertEqual('#A7AFC2');
      expect(LatencyStyle.color(120)).assertEqual('#29C978');
      expect(LatencyStyle.color(200)).assertEqual('#F3B83F');
      expect(LatencyStyle.color(400)).assertEqual('#E35D6A');
      expect(LatencyStyle.text(-1)).assertEqual('超时');
      expect(LatencyStyle.text(null)).assertEqual('--');
    });

    it('latency_controller_retain_only_reclaims_stale_nodes', 0, () => {
      LatencyController.clearAll();
      LatencyController.set('active-a', 31);
      LatencyController.set('stale-b', 92);
      LatencyController.set('active-c', -1);

      LatencyController.retainOnly(['active-a', 'active-c']);

      expect(LatencyController.latencyFor('active-a')).assertEqual(31);
      expect(LatencyController.latencyFor('active-c')).assertEqual(-1);
      expect(LatencyController.latencyFor('stale-b')).assertNull();
      LatencyController.clearAll();
    });

    it('yaml_merger_dedupe_and_name_preserve', 0, () => {
      const yaml1 = 'proxies:\n' +
        "  - {name: 'A', type: ss, server: a.com, port: 1, cipher: aes-128-gcm, password: p}\n" +
        "  - {name: 'B', type: ss, server: b.com, port: 2, cipher: aes-128-gcm, password: p}\n";
      const yaml2 = 'proxies:\n' +
        "  - {name: 'A-2', type: ss, server: a.com, port: 1, cipher: aes-128-gcm, password: p}\n" +
        "  - {name: 'C', type: ss, server: c.com, port: 3, cipher: aes-128-gcm, password: p}\n";
      // 第一次合并
      const first = YamlMerger.merge([yaml1], 'subA', '');
      expect(first.length).assertEqual(2);
      // 第二次刷新（A 内容不变 → 名称保留；C 为新节点）
      const second = YamlMerger.merge([yaml2], 'subA', YamlMerger.toYaml(first));
      expect(second.length).assertEqual(2);
      let hasA = false;
      let hasC = false;
      for (const m of second) {
        if (m.server === 'a.com') {
          hasA = true;
          expect(m.name).assertEqual('A');
        }
        if (m.server === 'c.com') {
          hasC = true;
        }
      }
      expect(hasA).assertTrue();
      expect(hasC).assertTrue();
    });

    it('mixed_protocol_yaml_skips_bad_nodes_and_roundtrips_options', 0, () => {
      const yaml = 'proxies:\n' +
        '  - {name: "SS", type: ss, server: ss.example.com, port: 443, cipher: aes-128-gcm, password: "pw"}\n' +
        '  - {name: "bad", type: ss, server: bad.example.com, port: 70000, cipher: aes-128-gcm, password: "pw"}\n' +
        '  - {name: "VL", type: vless, server: vl.example.com, port: 443, uuid: "123e4567-e89b-12d3-a456-426614174000", network: ws, tls: true, reality-opts: {public-key: "pk", short-id: "sid"}, ws-opts: {path: "/ws", headers: {Host: "cdn.example.com"}}}\n' +
        '  - {name: "VM", type: vmess, server: vm.example.com, port: 443, uuid: "123e4567-e89b-12d3-a456-426614174001", alterId: 0, cipher: auto, network: grpc, tls: true, grpc-opts: {grpc-service-name: "svc"}}\n' +
        '  - {name: "TR", type: trojan, server: tr.example.com, port: 443, password: "secret", tls: true}\n';
      const parsed = SubscriptionParser.parse(yaml, 'mixed');
      expect(parsed.length).assertEqual(4);
      const merged = YamlMerger.merge([yaml], 'mixed', '');
      expect(merged.length).assertEqual(4);
      const cached = YamlMerger.toYaml(merged);
      const reread = SubscriptionParser.parse(cached, 'reread');
      expect(reread.length).assertEqual(4);
      const vl = reread.find((n) => n.proxyType === 'vless');
      const vm = reread.find((n) => n.proxyType === 'vmess');
      expect(vl !== undefined).assertTrue();
      expect(vm !== undefined).assertTrue();
      expect(vl?.realityPublicKey ?? '').assertEqual('pk');
      expect(vl?.realityShortId ?? '').assertEqual('sid');
      expect(vl?.wsPath ?? '').assertEqual('/ws');
      expect(vl?.wsHost ?? '').assertEqual('cdn.example.com');
      expect(vm?.grpcServiceName ?? '').assertEqual('svc');
    });

    it('config_generator_all_protocols_and_injection_defense', 0, () => {
      const ss = new ProxyNode();
      ss.id = 'ss'; ss.name = 'SS'; ss.server = 'ss.example.com'; ss.port = 443;
      ss.method = 'aes-128-gcm'; ss.password = 'pw'; ss.proxyType = 'ss';
      const vless = new ProxyNode();
      vless.id = 'vl'; vless.name = 'VLESS'; vless.server = 'vl.example.com'; vless.port = 443;
      vless.proxyType = 'vless'; vless.uuid = '123e4567-e89b-12d3-a456-426614174000';
      vless.network = 'ws'; vless.tls = true; vless.wsPath = '/ws'; vless.wsHost = 'cdn.example.com';
      const vmess = new ProxyNode();
      vmess.id = 'vm'; vmess.name = 'VMESS'; vmess.server = 'vm.example.com'; vmess.port = 443;
      vmess.proxyType = 'vmess'; vmess.uuid = '123e4567-e89b-12d3-a456-426614174001';
      vmess.method = 'auto'; vmess.network = 'grpc'; vmess.grpcServiceName = 'svc';
      const trojan = new ProxyNode();
      trojan.id = 'tr'; trojan.name = 'TROJAN'; trojan.server = 'tr.example.com'; trojan.port = 443;
      trojan.proxyType = 'trojan'; trojan.password = 'secret'; trojan.tls = true;
      const injected = new ProxyNode();
      injected.id = 'bad'; injected.name = 'bad\n  - MATCH,DIRECT'; injected.server = 'bad.example.com';
      injected.port = 443; injected.method = 'aes-128-gcm'; injected.password = 'pw'; injected.proxyType = 'ss';
      const settings = new AppSettings();
      const config = ClashConfigGenerator.generate(vless, [ss, vless, vmess, trojan, injected], settings,
        7890, 9090, 1053, 'secret');
      expect(config.includes('type: ss')).assertTrue();
      expect(config.includes('type: vless')).assertTrue();
      expect(config.includes('type: vmess')).assertTrue();
      expect(config.includes('type: trojan')).assertTrue();
      expect(config.includes('grpc-service-name: "svc"')).assertTrue();
      expect(config.includes('bad\n  - MATCH,DIRECT')).assertFalse();
    });

    it('hysteria2_uri_yaml_and_generator', 0, () => {
      // 1) hysteria2:// URI 解析（含中文 percent-encoded 名称、insecure、sni、obfs、带宽）
      const uri = 'hysteria2://p@ssw0rd@sg01.example.xyz:8443/?insecure=1&sni=localhost'
        + '&obfs=salamander&obfs-password=abc123&up=114&down=514&pinSHA256=deadbeef'
        + '#%E6%96%B0%E5%8A%A0%E5%9D%A101';
      const n = ProxyNode.fromUri(uri, 't', 'id1');
      expect(n !== null).assertTrue();
      expect(n?.name ?? '').assertEqual('新加坡01');
      expect(n?.password ?? '').assertEqual('p@ssw0rd');
      expect(n?.proxyType ?? '').assertEqual('hysteria2');
      expect(n?.port ?? 0).assertEqual(8443);
      expect(n?.skipCertVerify ?? false).assertTrue();
      expect(n?.servername ?? '').assertEqual('localhost');
      expect(n?.obfs ?? '').assertEqual('salamander');
      expect(n?.obfsParam ?? '').assertEqual('abc123');
      expect(n?.hyUp ?? '').assertEqual('114');
      expect(n?.hyDown ?? '').assertEqual('514');
      expect(n?.clientFingerprint ?? '').assertEqual('deadbeef');
      // 2) 配置生成：键名 sni/fingerprint/obfs-password/up/down 正确
      const line = ClashConfigGenerator.proxyYamlLine(n!);
      expect(line.includes('type: hysteria2')).assertTrue();
      expect(line.includes('sni: "localhost"')).assertTrue();
      expect(line.includes('fingerprint: "deadbeef"')).assertTrue();
      expect(line.includes('obfs-password: "abc123"')).assertTrue();
      expect(line.includes('up: "114"')).assertTrue();
      expect(line.includes('down: "514"')).assertTrue();
      expect(line.includes('servername:')).assertFalse();
      expect(line.includes('client-fingerprint:')).assertFalse();
      // 3) Clash YAML 流式条目解析 + 缓存往返
      const yaml = 'proxies:\n'
        + '  - { name: \u0027剩余流量：596.51 GB\u0027, server: sg01.example.xyz, port: 8443, udp: true,'
        + ' skip-cert-verify: true, sni: localhost, type: hysteria2, password: e73cc1c7-545d-437b-b328-7490b0f06d28 }\n';
      const parsed = SubscriptionParser.parse(yaml, 'hy');
      expect(parsed.length).assertEqual(1);
      expect(parsed[0].proxyType).assertEqual('hysteria2');
      expect(parsed[0].servername).assertEqual('localhost');
      const cached = YamlMerger.toYaml(YamlMerger.merge([yaml], 'hy', ''));
      const reread = SubscriptionParser.parse(cached, 'hy2');
      expect(reread.length).assertEqual(1);
      expect(reread[0].password).assertEqual('e73cc1c7-545d-437b-b328-7490b0f06d28');
      expect(reread[0].skipCertVerify).assertTrue();
      // 4) 缺 password 的 hy2 节点必须被拒绝
      expect(ProxyNode.fromUri('hysteria2://@x.example.com:443/', 't', 'id2') === null).assertTrue();
    });

    it('subscription_url_redact', 0, () => {
      expect(SubscriptionFetchPolicy.redactUrl('https://sub.example.com/path?token=abc'))
        .assertEqual('sub.example.com');
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://a.com/x')).assertTrue();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('ftp://a.com')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('http://a.com/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://localhost/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://127.0.0.1/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://192.168.1.1/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://a.com:8443/x')).assertFalse();
    });

    it('subscription_ip_policy_rejects_reserved_ranges', 0, () => {
      expect(SubscriptionFetchPolicy.isPublicIpAddress('8.8.8.8')).assertTrue();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('0.0.0.0')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('100.64.0.1')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('192.0.0.9')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('198.51.100.1')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('240.0.0.1')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('2606:4700:4700::1111')).assertTrue();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('::1')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('fe80::1')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('fd00::1')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('::ffff:127.0.0.1')).assertFalse();
      expect(SubscriptionFetchPolicy.isPublicIpAddress('2001:db8::1')).assertFalse();
    });

    it('subscription_redirect_to_private_target_is_rejected', 0, () => {
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://192.168.1.10/sub')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://[::1]/sub')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('https://[fe80::1]/sub')).assertFalse();
    });

    it('subscription_http_requires_explicit_risk_and_drops_sensitive_header', 0, () => {
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('http://a.com/x')).assertFalse();
      expect(SubscriptionFetchPolicy.isValidSubscriptionUrl('http://a.com/x', true)).assertTrue();
      expect(SubscriptionFetchPolicy.maySendCustomHeader('https://a.com/x', 'Authorization')).assertTrue();
      expect(SubscriptionFetchPolicy.maySendCustomHeader('http://a.com/x', 'Authorization')).assertFalse();
    });

    it('subscription_limits_response_fields_and_nodes', 0, () => {
      expect(SubscriptionFetchPolicy.isResponseSizeAllowed(1024)).assertTrue();
      expect(SubscriptionFetchPolicy.isResponseSizeAllowed(8 * 1024 * 1024 + 1)).assertFalse();
      expect(SubscriptionFetchPolicy.isFieldLengthAllowed('a'.repeat(4096))).assertTrue();
      expect(SubscriptionFetchPolicy.isFieldLengthAllowed('a'.repeat(4097))).assertFalse();
      expect(SubscriptionFetchPolicy.isNodeCountAllowed(2000)).assertTrue();
      expect(SubscriptionFetchPolicy.isNodeCountAllowed(2001)).assertFalse();
    });

    it('subscription_userinfo_parses_traffic_and_expiry', 0, () => {
      const info = SubscriptionFetchPolicy.parseUserInfo(
        'upload=1048576; download=2097152; total=10737418240; expire=1798761600');
      expect(info.uploadBytes).assertEqual(1048576);
      expect(info.downloadBytes).assertEqual(2097152);
      expect(info.totalBytes).assertEqual(10737418240);
      expect(info.expireAt).assertEqual(1798761600000);
    });

    it('subscription_userinfo_is_case_insensitive_and_keeps_missing_values_unknown', 0, () => {
      const info = SubscriptionFetchPolicy.parseUserInfo(
        ' Upload = 12 ; DOWNLOAD=34; malformed; total=-1; expire=not-a-number');
      expect(info.uploadBytes).assertEqual(12);
      expect(info.downloadBytes).assertEqual(34);
      expect(info.totalBytes).assertEqual(-1);
      expect(info.expireAt).assertEqual(-1);
    });

    // ── 卡片启动 VPN 的权威状态 / 保活 / 断开语义专项验证 ──
    it('tunnel_authority_card_cold_start_connected', 0, () => {
      // 卡片冷启动刚连接：意图=已连接，心跳新鲜 → 必须判为已连接
      const fresh = new HeartbeatProbeStub(1200, 'fresh');
      const state = resolveAuthority(true, fresh.heartbeatAgeMs(), false);
      expect(state.desiredConnected).assertTrue();
      expect(state.coreAlive).assertTrue();
      expect(state.connected).assertTrue();
      expect(state.reason).assertEqual('core-alive');
    });

    it('tunnel_authority_kernel_crash_immediate_disconnect', 0, () => {
      // 卡片启动后内核崩溃：进程内 state 已丢失(state 恒 DISCONNECTED)、
      // 心跳文件消失(-1)。权威判定必须为"未连接"，卡片随即显示已断开/连接。
      const dead = new HeartbeatProbeStub(-1, 'core-exited');
      const state = resolveAuthority(true, dead.heartbeatAgeMs(), false);
      expect(state.coreAlive).assertFalse();
      expect(state.connected).assertFalse();
      expect(state.reason).assertEqual('core-exited');
      // 心跳文件过期但尚存：14.9s 内仍算活，15s 起立即判死
      expect(isHeartbeatFresh(HEARTBEAT_STALE_MS - 100)).assertTrue();
      expect(isHeartbeatFresh(HEARTBEAT_STALE_MS)).assertFalse();
    });

    it('tunnel_authority_heartbeat_timeout_marks_disconnected', 0, () => {
      const stale = new HeartbeatProbeStub(HEARTBEAT_STALE_MS + 1, 'heartbeat-timeout');
      const state = resolveAuthority(true, stale.heartbeatAgeMs(), false);
      expect(state.connected).assertFalse();
      expect(state.reason).assertEqual('heartbeat-timeout');
      // 存活标记仍在但心跳超时 → 标记作为兜底证据，仍视为存活（避免抖动误杀）
      const marked = resolveAuthority(true, stale.heartbeatAgeMs(), true);
      expect(marked.coreAlive).assertTrue();
      expect(marked.connected).assertTrue();
      // 用户主动断开（意图=false）时，纵有存活标记也不得报已连接
      const off = resolveAuthority(false, 100, true);
      expect(off.connected).assertFalse();
      expect(off.reason).assertEqual('user-disconnected');
    });

    it('disconnect_on_connected_is_real_disconnect_not_toggle', 0, () => {
      // 已连接（卡片显示「断开」）点断开：必须执行真实断开
      expect(shouldExecuteDisconnect(true, 500, false)).assertTrue();
      // 意图已连接但内核已死：点断开仍需执行清理，绝不反转成重连
      expect(shouldExecuteDisconnect(true, -1, false)).assertTrue();
      // 意图已断开但内核仍在跑（残留进程）：也必须真正停止
      expect(shouldExecuteDisconnect(false, 500, false)).assertTrue();
      expect(shouldExecuteDisconnect(false, -1, true)).assertTrue();
      // 真正空闲（无意图、无存活证据）：无需执行断开
      expect(shouldExecuteDisconnect(false, -1, false)).assertFalse();
    });

    it('connect_when_disconnected_starts_tunnel_and_dedupes_repeats', 0, () => {
      // 已断开点连接：允许发起（不应被抑制）
      expect(shouldSuppressConnect(false, -1, false, false)).assertFalse();
      // 重复点击去重：操作在途时一律抑制
      expect(shouldSuppressConnect(false, -1, false, true)).assertTrue();
      // 已连接状态下重复点连接：抑制，不再拉起第二条隧道
      expect(shouldSuppressConnect(true, 800, false, false)).assertTrue();
      // 意图已连接但内核已死：允许恢复连接（不算重复）
      expect(shouldSuppressConnect(true, -1, false, false)).assertFalse();
    });

    // ── 节点排序持久化 专项验证 ──
    /** 构造 auto 测速快照: [[名, 延迟], ...] */
    const buildAutoSnapshot = (pairs: string[][], testedAt: number): NodeSortSnapshot => {
      const recs: NodeLatencyRecord[] = [];
      for (const p of pairs) {
        const r = new NodeLatencyRecord();
        r.name = p[0];
        r.latency = parseInt(p[1]);
        r.lastOk = r.latency >= 0;
        recs.push(r);
      }
      return NodeSortSnapshot.buildAuto(testedAt, recs, null);
    };

    it('node_sort_snapshot_roundtrip_restores_order', 0, () => {
      // 测速完成: C(30ms) 最快 → A(80ms) → B 失败沉底
      const snap = buildAutoSnapshot([['A', '80'], ['B', '-1'], ['C', '30']], 1700000000000);
      const names: string[] = ['A', 'B', 'C'];
      expect(snap.orderedNames(names)[0]).assertEqual('C');
      expect(snap.orderedNames(names)[1]).assertEqual('A');
      expect(snap.orderedNames(names)[2]).assertEqual('B');
      // 序列化 → 反序列化（模拟退出页面/重启后从设置恢复）
      const restored = NodeSortSnapshot.fromJsonText(snap.toJsonText());
      expect(restored !== null).assertTrue();
      expect(restored!.mode).assertEqual(NodeSortModes.AUTO);
      expect(restored!.testedAt).assertEqual(1700000000000);
      expect(restored!.orderedNames(names)[0]).assertEqual('C');
      expect(restored!.orderedNames(names)[2]).assertEqual('B');
    });

    it('node_sort_retest_overwrites_previous_order', 0, () => {
      const first = buildAutoSnapshot([['A', '80'], ['B', '20'], ['C', '50']], 1000);
      const names: string[] = ['A', 'B', 'C'];
      expect(first.orderedNames(names)[0]).assertEqual('B'); // 首次: B 最快
      // 重新测速: A 变最快（整体覆盖旧顺序）
      const second = buildAutoSnapshot([['A', '10'], ['B', '90'], ['C', '50']], 2000);
      expect(second.orderedNames(names)[0]).assertEqual('A');
      expect(second.orderedNames(names)[2]).assertEqual('B');
      expect(second.testedAt).assertEqual(2000);
    });

    it('node_sort_without_data_falls_back_to_default_order', 0, () => {
      // 空快照 / 损坏 JSON / 全 -2（未测试）→ orderedNames 返回空，调用方保持订阅原始顺序
      expect(NodeSortSnapshot.fromJsonText('')).assertNull();
      expect(NodeSortSnapshot.fromJsonText('{not-json')).assertNull();
      const recs: NodeLatencyRecord[] = [];
      const unsupported = new NodeLatencyRecord();
      unsupported.name = 'X';
      unsupported.latency = -2;
      recs.push(unsupported);
      const empty = NodeSortSnapshot.buildAuto(1, recs, null);
      expect(empty.hasLatencyData()).assertFalse();
      const names: string[] = ['A', 'B'];
      expect(empty.orderedNames(names).length).assertEqual(0);
      // 模式归一化: 未知值回退 default
      expect(NodeSortModes.normalize('bogus')).assertEqual(NodeSortModes.DEFAULT);
      expect(NodeSortModes.normalize(undefined)).assertEqual(NodeSortModes.DEFAULT);
    });

    it('node_sort_manual_mode_keeps_pinned_order', 0, () => {
      const snap = buildAutoSnapshot([['A', '10'], ['B', '20'], ['C', '30']], 5);
      snap.mode = NodeSortModes.MANUAL;
      snap.order = ['C', 'A', 'B']; // 用户固定顺序
      const names: string[] = ['A', 'B', 'C'];
      const out = snap.orderedNames(names);
      expect(out[0]).assertEqual('C');
      expect(out[1]).assertEqual('A');
      expect(out[2]).assertEqual('B');
      // 新增节点（未在固定顺序中）沉底
      const names2: string[] = ['A', 'B', 'C', 'D'];
      expect(snap.orderedNames(names2)[3]).assertEqual('D');
    });

    it('node_sort_appsettings_persists_mode_and_snapshot', 0, () => {
      const snap = buildAutoSnapshot([['A', '10'], ['B', '40']], 777);
      const s = new AppSettings();
      s.nodeSortMode = NodeSortModes.AUTO;
      s.nodeSortSnapshot = snap.toJsonText();
      // 走 AppSettings 序列化/反序列化（与落盘一致）
      const round = AppSettings.fromJson(JSON.parse(JSON.stringify(s.toJson())) as AppSettingsJson);
      expect(round.nodeSortMode).assertEqual(NodeSortModes.AUTO);
      const restored = NodeSortSnapshot.fromJsonText(round.nodeSortSnapshot);
      expect(restored !== null).assertTrue();
      expect(restored!.orderedNames(['A', 'B'])[0]).assertEqual('A');
      // 缺省值回退
      const def = AppSettings.fromJson(new AppSettings().toJson());
      expect(def.nodeSortMode).assertEqual(NodeSortModes.DEFAULT);
      expect(def.nodeSortSnapshot).assertEqual('');
    });

    it('node_protocol_type_mapping_includes_unknown_and_reality', 0, () => {
      // proxyType 优先
      expect(NodeProtocolPolicy.resolve('vless', '', '', '').label).assertEqual('VLESS');
      expect(NodeProtocolPolicy.resolve('vmess', '', '', '').label).assertEqual('VMESS');
      expect(NodeProtocolPolicy.resolve('trojan', '', '', '').label).assertEqual('TROJAN');
      expect(NodeProtocolPolicy.resolve('hysteria2', '', '', '').label).assertEqual('HYSTERIA2');
      expect(NodeProtocolPolicy.resolve('hy2', '', '', '').label).assertEqual('HYSTERIA2');
      // type 枚举派生 ss/ssr
      expect(NodeProtocolPolicy.resolve('', 'ss', '', '').label).assertEqual('SS');
      expect(NodeProtocolPolicy.resolve('', 'ssr', '', '').label).assertEqual('SSR');
      // 未知值兜底
      const unknown = NodeProtocolPolicy.resolve('gibberish', '', '', '');
      expect(unknown.key).assertEqual('');
      expect(unknown.label).assertEqual('未知');
      expect(NodeProtocolPolicy.resolve('', '', '', '').label).assertEqual('未知');
      // REALITY: vless + 公钥/短id
      const reality = NodeProtocolPolicy.resolve('vless', '', 'PUBKEY', '');
      expect(reality.reality).assertTrue();
      expect(reality.display()).assertEqual('VLESS·REALITY');
      expect(NodeProtocolPolicy.resolve('vless', '', '', 'short').display()).assertEqual('VLESS·REALITY');
      // 非 vless 即使有键也不标 REALITY
      expect(NodeProtocolPolicy.resolve('trojan', '', 'PUBKEY', '').reality).assertFalse();
      expect(NodeProtocolPolicy.resolve('vmess', '', '', '').display()).assertEqual('VMESS');
    });

    it('node_protocol_from_proxy_node_derives_reality', 0, () => {
      const vless = new ProxyNode();
      vless.proxyType = 'vless';
      vless.type = ProxyNodeType.UNKNOWN;
      expect(NodeProtocolPolicy.fromNode(vless).label).assertEqual('VLESS');
      expect(NodeProtocolPolicy.isRealityNode(vless)).assertFalse();
      vless.realityPublicKey = 'abc';
      expect(NodeProtocolPolicy.isRealityNode(vless)).assertTrue();
      expect(NodeProtocolPolicy.fromNode(vless).display()).assertEqual('VLESS·REALITY');
      // ss / ssr 由枚举派生
      const ss = new ProxyNode();
      ss.type = ProxyNodeType.SS;
      expect(NodeProtocolPolicy.fromNode(ss).label).assertEqual('SS');
      const ssr = new ProxyNode();
      ssr.type = ProxyNodeType.SSR;
      expect(NodeProtocolPolicy.fromNode(ssr).label).assertEqual('SSR');
      // 完全未知
      expect(NodeProtocolPolicy.fromNode(new ProxyNode()).label).assertEqual('未知');
    });

    // ── 运行时凭据清理（逐文件独立容错）────────────────────────────
    it('cleanup_tolerates_partial_missing_files', 0, () => {
      const mem = new FakePrivateFs();
      mem.files.set('/cache/mihomo_config.yaml', 'secret: abc');
      // mihomo_test_config.yaml 与全部隧道标记文件都不存在（进程重启后的真实形态）
      const removed = clearPrivateArtifacts('/cache', mem);
      // 不抛异常；存在的那一个被删掉；其余缺失文件被跳过
      expect(removed.length).assertEqual(1);
      expect(removed[0]).assertEqual(PRIVATE_CONFIG_FILE);
      expect(mem.exists('/cache/mihomo_config.yaml')).assertFalse();
      // 每个目标文件都被尝试过（缺失也要尝试，才能覆盖后续创建的文件）
      expect(mem.removeCalls).assertEqual(5);
    });

    it('cleanup_continues_when_one_delete_fails', 0, () => {
      const mem = new FakePrivateFs();
      mem.files.set('/cache/mihomo_config.yaml', 'secret: abc');
      mem.files.set('/cache/mihomo_test_config.yaml', 'secret: test');
      mem.files.set('/cache/vpn_heartbeat.txt', '1700000000000');
      mem.files.set('/cache/vpn_start_ok.txt', 'x');
      // 主配置删除失败（模拟被内核占用）：不得阻断其余文件删除
      mem.undeletable.add('/cache/mihomo_config.yaml');
      const removed = clearPrivateArtifacts('/cache', mem);
      expect(removed.length).assertEqual(3);
      expect(mem.exists('/cache/mihomo_test_config.yaml')).assertFalse();
      expect(mem.exists('/cache/vpn_heartbeat.txt')).assertFalse();
      expect(mem.exists('/cache/vpn_start_ok.txt')).assertFalse();
      // 失败的那个仍在（由下次断开/退出补删），但绝不阻塞其他
      expect(mem.exists('/cache/mihomo_config.yaml')).assertTrue();
    });

    it('cleanup_isolates_missing_file_in_independent_list', 0, () => {
      const mem = new FakePrivateFs();
      // 测速配置不存在，主配置与错误标记存在
      mem.files.set('/cache/mihomo_config.yaml', 'a');
      mem.files.set('/cache/vpn_start_error.txt', 'boom');
      const removed = removeFilesIndependently('/cache',
        [PRIVATE_TEST_CONFIG_FILE, PRIVATE_CONFIG_FILE, 'vpn_start_error.txt'], mem);
      expect(removed.length).assertEqual(2);
      expect(removed.indexOf(PRIVATE_TEST_CONFIG_FILE)).assertEqual(-1);
      expect(removed.indexOf(PRIVATE_CONFIG_FILE) >= 0).assertTrue();
      expect(removed.indexOf('vpn_start_error.txt') >= 0).assertTrue();
    });

    // ── 状态文件有界读取 + 心跳解析 ────────────────────────────────
    it('state_file_read_is_length_capped', 0, () => {
      const mem = new FakePrivateFs();
      // 1MB 超长内容：上限 64KB，必须只读上限长度
      const long = 'A'.repeat(1024 * 1024);
      mem.files.set('/cache/vpn_start_error.txt', long);
      const res = mem.readCapped('/cache/vpn_start_error.txt', MAX_STATE_FILE_BYTES);
      expect(res.ok).assertTrue();
      expect(res.truncated).assertTrue();
      expect(MAX_STATE_FILE_BYTES).assertEqual(64 * 1024);
      // 缺失文件返回 ok=false，绝不抛异常
      const miss = mem.readCapped('/cache/vpn_heartbeat.txt', MAX_STATE_FILE_BYTES);
      expect(miss.ok).assertFalse();
      expect(miss.text).assertEqual('');
    });

    it('heartbeat_parse_rejects_garbage_and_reports_age', 0, () => {
      expect(parseHeartbeatTimestamp('1700000000000')).assertEqual(1700000000000);
      expect(parseHeartbeatTimestamp('  1800000000000\n')).assertEqual(1800000000000);
      expect(parseHeartbeatTimestamp('')).assertEqual(-1);
      expect(parseHeartbeatTimestamp('not-a-number')).assertEqual(-1);
      expect(parseHeartbeatTimestamp('-5')).assertEqual(-1);
      expect(heartbeatAgeFromText('1700000000000', 1700000005000)).assertEqual(5000);
      expect(heartbeatAgeFromText('garbage', 1700000005000)).assertEqual(-1);
    });

    // ── 测速内核单航班状态机 ───────────────────────────────────────
    it('single_flight_concurrent_ensure_starts_core_once', 0, async () => {
      let starts = 0;
      const flight = new SingleFlightTestCore({
        startFn: (): Promise<boolean> => {
          starts = starts + 1;
          return new Promise<boolean>((resolve) => {
            setTimeout(() => resolve(true), 30);
          });
        },
        cancelFn: (): Promise<void> => Promise.resolve(),
        timeoutMs: 5000
      });
      // 三个并发调用：只允许真正启动一次
      const results = await Promise.all([flight.ensure(), flight.ensure(), flight.ensure()]);
      expect(starts).assertEqual(1);
      expect(results[0]).assertTrue();
      expect(results[1]).assertTrue();
      expect(results[2]).assertTrue();
      expect(flight.isActive()).assertTrue();
      // 已 ACTIVE 后再次 ensure 也必须复用，不再启动
      const again = await flight.ensure();
      expect(again).assertTrue();
      expect(starts).assertEqual(1);
    });

    it('single_flight_timeout_releases_and_resets_state', 0, async () => {
      let cancels = 0;
      const flight = new SingleFlightTestCore({
        startFn: (): Promise<boolean> => {
          // 永不 resolve：模拟系统授权链路卡死
          return new Promise<boolean>(() => {
          });
        },
        cancelFn: (): Promise<void> => {
          cancels = cancels + 1;
          return Promise.resolve();
        },
        timeoutMs: 60
      });
      const ok = await flight.ensure();
      expect(ok).assertFalse();
      // 超时必须释放已发出的启动，且状态归零不留残余
      expect(cancels).assertEqual(1);
      expect(flight.getStatus()).assertEqual(TestCoreStatus.IDLE);
      expect(flight.isActive()).assertFalse();
    });

    it('single_flight_stop_during_start_does_not_fight_start', 0, async () => {
      let cancels = 0;
      let resolveStart: (v: boolean) => void = () => {
      };
      const flight = new SingleFlightTestCore({
        startFn: (): Promise<boolean> => new Promise<boolean>((resolve) => {
          resolveStart = resolve;
        }),
        cancelFn: (): Promise<void> => {
          cancels = cancels + 1;
          return Promise.resolve();
        },
        timeoutMs: 5000
      });
      const pending = flight.ensure();
      expect(flight.isStarting()).assertTrue();
      // 启动在途时要求停止：不得立即 post 停止（避免与在途启动互相 stop）
      const stopping = flight.stop();
      expect(cancels).assertEqual(0);
      resolveStart(true);
      const ok = await pending;
      await stopping;
      // 快速启停：启动落地后立即回收，结果作废，状态归零
      expect(ok).assertFalse();
      expect(cancels).assertEqual(1);
      expect(flight.getStatus()).assertEqual(TestCoreStatus.IDLE);
    });

    it('single_flight_stop_once_for_active_core_is_idempotent', 0, async () => {
      let starts = 0;
      let cancels = 0;
      const flight = new SingleFlightTestCore({
        startFn: (): Promise<boolean> => {
          starts = starts + 1;
          return Promise.resolve(true);
        },
        cancelFn: (): Promise<void> => {
          cancels = cancels + 1;
          return Promise.resolve();
        },
        timeoutMs: 5000
      });
      await flight.ensure();
      expect(flight.isActive()).assertTrue();
      await flight.stop();
      expect(cancels).assertEqual(1);
      // 已 IDLE 再 stop：幂等，不得重复停止
      await flight.stop();
      expect(cancels).assertEqual(1);
      expect(flight.getStatus()).assertEqual(TestCoreStatus.IDLE);
      // 停止后可再次启动（不残留坏死状态）
      const restarted = await flight.ensure();
      expect(restarted).assertTrue();
      expect(starts).assertEqual(2);
    });

    it('single_flight_failed_start_returns_idle_without_stop_noise', 0, async () => {
      let cancels = 0;
      const flight = new SingleFlightTestCore({
        startFn: (): Promise<boolean> => Promise.resolve(false),
        cancelFn: (): Promise<void> => {
          cancels = cancels + 1;
          return Promise.resolve();
        },
        timeoutMs: 5000
      });
      const ok = await flight.ensure();
      expect(ok).assertFalse();
      expect(flight.getStatus()).assertEqual(TestCoreStatus.IDLE);
      // 启动本身明确失败（非超时）时不产生额外的取消噪声
      expect(cancels).assertEqual(0);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 第二阶段纯逻辑：NetworkStateWatcher / LinkHealthChecker / SmartSelector
  // ══════════════════════════════════════════════════════════════════
  describe('tunboxPhase2PureLogic', () => {
    // ── NetworkStateWatcher：normalizeNetType 全分支 ────────────────
    it('net_type_normalize_all_branches', 0, () => {
      // bearer 数值常量必须与 SDK connection.NetBearType 对齐
      expect(BEARER_CELLULAR).assertEqual(0);
      expect(BEARER_WIFI).assertEqual(1);
      expect(BEARER_BLUETOOTH).assertEqual(2);
      expect(BEARER_ETHERNET).assertEqual(3);
      expect(BEARER_VPN).assertEqual(4);
      // 无默认网络 → none（无论 bearer 里有什么）
      expect(normalizeNetType([], false)).assertEqual(NetTypes.NONE);
      expect(normalizeNetType([BEARER_WIFI], false)).assertEqual(NetTypes.NONE);
      // 有默认网络但 bearer 为空 → unknown
      expect(normalizeNetType([], true)).assertEqual(NetTypes.UNKNOWN);
      // 单 bearer 三分支
      expect(normalizeNetType([BEARER_WIFI], true)).assertEqual(NetTypes.WIFI);
      expect(normalizeNetType([BEARER_ETHERNET], true)).assertEqual(NetTypes.ETHERNET);
      expect(normalizeNetType([BEARER_CELLULAR], true)).assertEqual(NetTypes.CELLULAR);
      // 不可识别承载（蓝牙 / 纯 VPN TUN）→ unknown，不对外暴露自指类型
      expect(normalizeNetType([BEARER_BLUETOOTH], true)).assertEqual(NetTypes.UNKNOWN);
      expect(normalizeNetType([BEARER_VPN], true)).assertEqual(NetTypes.UNKNOWN);
      // 优先级 wifi > ethernet > cellular
      expect(normalizeNetType([BEARER_CELLULAR, BEARER_WIFI], true)).assertEqual(NetTypes.WIFI);
      expect(normalizeNetType([BEARER_CELLULAR, BEARER_ETHERNET], true)).assertEqual(NetTypes.ETHERNET);
      expect(normalizeNetType([BEARER_WIFI, BEARER_ETHERNET], true)).assertEqual(NetTypes.WIFI);
      expect(normalizeNetType([BEARER_VPN, BEARER_CELLULAR], true)).assertEqual(NetTypes.CELLULAR);
      // 默认去抖窗口
      expect(NET_DEBOUNCE_MS).assertEqual(1500);
    });

    // ── NetworkStateWatcher：shouldEmit 去抖全分支 ──────────────────
    it('net_type_should_emit_debounce_branches', 0, () => {
      // 无变化 → 永不上报
      expect(shouldEmit(NetTypes.WIFI, NetTypes.WIFI, 99999, NET_DEBOUNCE_MS)).assertFalse();
      // 无历史状态 → 立即上报
      expect(shouldEmit('', NetTypes.WIFI, 0, NET_DEBOUNCE_MS)).assertTrue();
      // 去抖关闭 → 立即上报
      expect(shouldEmit(NetTypes.WIFI, NetTypes.CELLULAR, 10, 0)).assertTrue();
      // 时钟回拨 → 不阻塞上报
      expect(shouldEmit(NetTypes.WIFI, NetTypes.CELLULAR, -5, NET_DEBOUNCE_MS)).assertTrue();
      // 窗口内 → 抑制；达窗口 → 上报（边界 1499/1500）
      expect(shouldEmit(NetTypes.WIFI, NetTypes.CELLULAR, 1499, NET_DEBOUNCE_MS)).assertFalse();
      expect(shouldEmit(NetTypes.WIFI, NetTypes.CELLULAR, 1500, NET_DEBOUNCE_MS)).assertTrue();
      // 自定义窗口生效
      expect(shouldEmit(NetTypes.WIFI, NetTypes.CELLULAR, 300, 300)).assertTrue();
      expect(shouldEmit(NetTypes.WIFI, NetTypes.CELLULAR, 299, 300)).assertFalse();
    });

    // ── NetworkStateWatcher：去抖 + generation 单调递增 + 回调隔离 ──
    it('net_type_debounce_and_generation_monotonic', 0, () => {
      let now = 0;
      const watcher = new NetworkStateWatcher(1500, (): number => now);
      const seen: string[] = [];
      const gens: number[] = [];
      const listener: NetworkStateListener = new RecordingNetworkListener(seen, gens, false);
      watcher.addListener(listener);
      // 初始：无历史状态，对外映射 unknown，代数为 0
      expect(watcher.networkType()).assertEqual(NetTypes.UNKNOWN);
      expect(watcher.generation()).assertEqual(0);
      expect(watcher.isSubscribed()).assertFalse();
      expect(watcher.debounceWindowMs()).assertEqual(1500);

      // 首次观测 → 立即上报（prev 为空）
      watcher.feedForTest(NetTypes.WIFI);
      expect(watcher.generation()).assertEqual(1);
      expect(watcher.networkType()).assertEqual(NetTypes.WIFI);

      // 重复同一类型 → 不上报，代数不变
      watcher.feedForTest(NetTypes.WIFI);
      expect(watcher.generation()).assertEqual(1);

      // 窗口内变化 → 抑制
      now = 500;
      watcher.feedForTest(NetTypes.CELLULAR);
      expect(watcher.generation()).assertEqual(1);
      expect(watcher.networkType()).assertEqual(NetTypes.WIFI);

      // 达窗口 → 上报，代数 +1
      now = 1500;
      watcher.feedForTest(NetTypes.CELLULAR);
      expect(watcher.generation()).assertEqual(2);
      expect(watcher.networkType()).assertEqual(NetTypes.CELLULAR);

      // 由 wifi 切到 none 同样受去抖保护
      watcher.feedForTest(NetTypes.NONE);
      expect(watcher.generation()).assertEqual(2);
      now = 3100;
      watcher.feedForTest(NetTypes.NONE);
      expect(watcher.generation()).assertEqual(3);

      expect(seen.length).assertEqual(3);
      expect(seen[0]).assertEqual(NetTypes.WIFI);
      expect(seen[1]).assertEqual(NetTypes.CELLULAR);
      expect(seen[2]).assertEqual(NetTypes.NONE);
      // 代数严格单调递增
      expect(gens[0]).assertEqual(1);
      expect(gens[1]).assertEqual(2);
      expect(gens[2]).assertEqual(3);

      // 非法去抖值回退默认
      expect(new NetworkStateWatcher(-1).debounceWindowMs()).assertEqual(NET_DEBOUNCE_MS);
    });

    it('net_type_listener_exception_is_isolated_and_stop_releases', 0, () => {
      const watcher = new NetworkStateWatcher(0, (): number => 100);
      const good: string[] = [];
      const bad: NetworkStateListener = new RecordingNetworkListener([], [], true);
      const ok: NetworkStateListener = new RecordingNetworkListener(good, [], false);
      watcher.addListener(bad);
      watcher.addListener(ok);
      // 抛异常的监听者必须被隔离，不得中断广播（feedForTest 本身不抛）
      watcher.feedForTest(NetTypes.ETHERNET);
      expect(good.length).assertEqual(1);
      expect(good[0]).assertEqual(NetTypes.ETHERNET);
      expect(watcher.generation()).assertEqual(1);
      // 重复 start/stop 幂等且安全（无真机时也不抛）
      watcher.stop();
      expect(watcher.isSubscribed()).assertFalse();
      watcher.stop();
      expect(watcher.isSubscribed()).assertFalse();
      // stop 清空监听者：之后的变化不再回调任何旧监听者（防 UI 泄漏）
      watcher.feedForTest(NetTypes.WIFI);
      expect(good.length).assertEqual(1);
    });

    // ── LinkHealthChecker：summarize 边界 ──────────────────────────
    it('link_health_summarize_boundaries', 0, () => {
      const passItem = (id: string): LinkHealthItem =>
        LinkHealthItem.make(id, 'label-' + id, ProbeOutcome.pass('ok', 'v1'), 5);
      const failItem = (id: string, advice: string): LinkHealthItem =>
        LinkHealthItem.make(id, 'label-' + id, ProbeOutcome.fail('bad', advice), 7);
      const skipItem = (id: string): LinkHealthItem =>
        LinkHealthItem.make(id, 'label-' + id, ProbeOutcome.skip('n/a'), 1);

      // (1) 全部通过 → ok
      const allPass = new LinkHealthReport();
      allPass.items.push(passItem(CheckIds.SUBSCRIPTION));
      allPass.items.push(passItem(CheckIds.CORE));
      const s1 = summarize(allPass);
      expect(s1.overall).assertEqual(HealthOverall.OK);
      expect(s1.passCount).assertEqual(2);
      expect(s1.failCount).assertEqual(0);
      expect(s1.skipCount).assertEqual(0);
      expect(s1.firstFailId).assertEqual('');
      expect(s1.isOk()).assertTrue();

      // (2) 单项失败 → broken，首要失败项为该 fail
      const oneFail = new LinkHealthReport();
      oneFail.items.push(passItem(CheckIds.SUBSCRIPTION));
      oneFail.items.push(failItem(CheckIds.CORE, '请点击重连以重启内核'));
      oneFail.items.push(passItem(CheckIds.DNS));
      const s2 = summarize(oneFail);
      expect(s2.overall).assertEqual(HealthOverall.BROKEN);
      expect(s2.passCount).assertEqual(2);
      expect(s2.failCount).assertEqual(1);
      expect(s2.firstFailId).assertEqual(CheckIds.CORE);
      expect(s2.firstFailLabel).assertEqual('label-' + CheckIds.CORE);
      expect(s2.firstFailDetail).assertEqual('bad');
      expect(s2.firstFailAdvice).assertEqual('请点击重连以重启内核');
      expect(s2.isBroken()).assertTrue();
      // 失败项必须带可执行建议 + 可枚举修复动作
      expect(s2.firstFailAdvice.length > 0).assertTrue();
      expect(oneFail.item(CheckIds.CORE)!.repair).assertEqual(RepairActions.RESTART_CORE);

      // (3) 全部失败 → broken，首要失败项为报告顺序第一个
      const allFail = new LinkHealthReport();
      allFail.items.push(failItem(CheckIds.SUBSCRIPTION, '请刷新订阅'));
      allFail.items.push(failItem(CheckIds.NODE, '请重新选择节点'));
      allFail.items.push(failItem(CheckIds.TUN, '请重连以重建 TUN'));
      const s3 = summarize(allFail);
      expect(s3.overall).assertEqual(HealthOverall.BROKEN);
      expect(s3.failCount).assertEqual(3);
      expect(s3.passCount).assertEqual(0);
      expect(s3.firstFailId).assertEqual(CheckIds.SUBSCRIPTION);

      // (4) 空报告 → degraded（没查过不能说 ok）
      const empty = new LinkHealthReport();
      const s4 = summarize(empty);
      expect(s4.overall).assertEqual(HealthOverall.DEGRADED);
      expect(s4.passCount).assertEqual(0);
      expect(s4.failCount).assertEqual(0);
      expect(s4.skipCount).assertEqual(0);
      expect(s4.firstFailId).assertEqual('');

      // (5) 有跳过但无失败 → degraded（如设备/网络不支持 IPv6）
      const withSkip = new LinkHealthReport();
      withSkip.items.push(passItem(CheckIds.SUBSCRIPTION));
      withSkip.items.push(skipItem(CheckIds.IPV6));
      const s5 = summarize(withSkip);
      expect(s5.overall).assertEqual(HealthOverall.DEGRADED);
      expect(s5.skipCount).assertEqual(1);
      expect(s5.failCount).assertEqual(0);

      // 状态常量取值稳定（供 UI / 日志映射）
      expect(HealthStatus.PASS).assertEqual('pass');
      expect(HealthStatus.FAIL).assertEqual('fail');
      expect(HealthStatus.SKIP).assertEqual('skip');
    });

    // ── LinkHealthChecker：repairSteps 有限 / 有序 / 去重 ───────────
    it('link_health_repair_steps_bounded_ordered_deduped', 0, () => {
      const failItem = (id: string): LinkHealthItem =>
        LinkHealthItem.make(id, 'label-' + id, ProbeOutcome.fail('bad', 'advice'), 3);
      const passItem = (id: string): LinkHealthItem =>
        LinkHealthItem.make(id, 'label-' + id, ProbeOutcome.pass('ok'), 3);

      expect(DEFAULT_MAX_REPAIR_STEPS).assertEqual(3);
      // 空报告 → 无修复动作
      expect(repairSteps(new LinkHealthReport()).length).assertEqual(0);
      // 全通过 → 无修复动作
      const clean = new LinkHealthReport();
      clean.items.push(passItem(CheckIds.CORE));
      expect(repairSteps(clean).length).assertEqual(0);

      // 多个失败：按报告顺序（= 链路自底向上）给出，且默认最多 3 步
      const report = new LinkHealthReport();
      report.items.push(passItem(CheckIds.SUBSCRIPTION));
      report.items.push(failItem(CheckIds.NODE));
      report.items.push(failItem(CheckIds.CORE));
      report.items.push(failItem(CheckIds.CLASH_API));
      report.items.push(failItem(CheckIds.DNS));
      const steps = repairSteps(report);
      expect(steps.length).assertEqual(3);
      expect(steps[0]).assertEqual(RepairActions.RESELECT_NODE);
      expect(steps[1]).assertEqual(RepairActions.RESTART_CORE);
      expect(steps[2]).assertEqual(RepairActions.RESTART_CLASH_API);
      // 上限可调：1 步 / 5 步 / 0 步（禁用）
      expect(repairSteps(report, 1).length).assertEqual(1);
      expect(repairSteps(report, 5).length).assertEqual(4);
      expect(repairSteps(report, 0).length).assertEqual(0);
      expect(repairSteps(report, -3).length).assertEqual(0);

      // 去重：两项映射到同一动作只出现一次（禁重复重连/重试）
      const dup = new LinkHealthReport();
      dup.items.push(failItem(CheckIds.CORE));
      dup.items.push(failItem(CheckIds.CORE));
      const dupSteps = repairSteps(dup);
      expect(dupSteps.length).assertEqual(1);
      expect(dupSteps[0]).assertEqual(RepairActions.RESTART_CORE);

      // 修复动作全部来自枚举（有限集合，禁止无限重试/重连风暴）
      const allowed: string[] = [
        RepairActions.REFRESH_SUBSCRIPTION, RepairActions.RESELECT_NODE,
        RepairActions.GRANT_VPN_PERMISSION, RepairActions.REBUILD_TUN,
        RepairActions.RESTART_CORE, RepairActions.RESTART_CLASH_API,
        RepairActions.FIX_DNS, RepairActions.CHECK_UPLINK,
        RepairActions.RECONCILE_INTENT, RepairActions.ENABLE_NOTIFICATIONS
      ];
      for (const s of steps) {
        expect(allowed.includes(s)).assertTrue();
      }
      // 兜底映射表覆盖全部 9 个可失败检查项
      expect(repairForCheck(CheckIds.SUBSCRIPTION)).assertEqual(RepairActions.REFRESH_SUBSCRIPTION);
      expect(repairForCheck(CheckIds.NODE)).assertEqual(RepairActions.RESELECT_NODE);
      expect(repairForCheck(CheckIds.VPN_AUTH)).assertEqual(RepairActions.GRANT_VPN_PERMISSION);
      expect(repairForCheck(CheckIds.TUN)).assertEqual(RepairActions.REBUILD_TUN);
      expect(repairForCheck(CheckIds.CORE)).assertEqual(RepairActions.RESTART_CORE);
      expect(repairForCheck(CheckIds.CLASH_API)).assertEqual(RepairActions.RESTART_CLASH_API);
      expect(repairForCheck(CheckIds.DNS)).assertEqual(RepairActions.FIX_DNS);
      expect(repairForCheck(CheckIds.EGRESS_IPV4)).assertEqual(RepairActions.CHECK_UPLINK);
      expect(repairForCheck(CheckIds.INTENT)).assertEqual(RepairActions.RECONCILE_INTENT);
      expect(repairForCheck('not-a-check')).assertEqual('');
    });

    // ── LinkHealthChecker：单点挂死/失败不阻断其余检查 ──────────────
    it('link_health_checker_run_isolates_failures_and_timeouts', 0, async () => {
      const stubs = new FakeLinkHealthProbes();
      stubs.outcomes.set(CheckIds.SUBSCRIPTION, ProbeOutcome.pass('订阅含 3 个节点', '3'));
      stubs.outcomes.set(CheckIds.NODE, ProbeOutcome.fail('当前节点字段缺失', '请重新选择节点'));
      stubs.outcomes.set(CheckIds.VPN_AUTH, ProbeOutcome.pass('已授权'));
      stubs.outcomes.set(CheckIds.TUN, ProbeOutcome.pass('TUN 已建立', 'tun0'));
      stubs.outcomes.set(CheckIds.CORE, ProbeOutcome.fail('内核已退出', '请点击重连以重启内核'));
      stubs.outcomes.set(CheckIds.CLASH_API, ProbeOutcome.pass('API 可达', 'v1.19.0'));
      stubs.outcomes.set(CheckIds.EGRESS_IPV4, ProbeOutcome.pass('generate_204 返回 204'));
      stubs.outcomes.set(CheckIds.IPV6, ProbeOutcome.skip('当前网络不支持 IPv6'));
      stubs.outcomes.set(CheckIds.INTENT, ProbeOutcome.pass('意图与真实状态一致'));
      // DNS 探针永不返回 → 只允许它自己超时
      stubs.hangIds.add(CheckIds.DNS);
      // 另一个探针直接抛异常 → 只允许它自己变 fail
      stubs.throwIds.add(CheckIds.EGRESS_IPV4);

      const checker = new LinkHealthChecker(stubs, 4000, 80);
      const report = await checker.run();
      expect(report.items.length).assertEqual(10);
      expect(report.truncated).assertFalse();
      // 挂死项被独立超时收敛为 fail，其余项照常完成
      expect(report.item(CheckIds.DNS)!.status).assertEqual(HealthStatus.FAIL);
      expect(report.item(CheckIds.DNS)!.detail.includes('超时')).assertTrue();
      expect(report.item(CheckIds.EGRESS_IPV4)!.status).assertEqual(HealthStatus.FAIL);
      expect(report.item(CheckIds.CLASH_API)!.status).assertEqual(HealthStatus.PASS);
      expect(report.item(CheckIds.IPV6)!.status).assertEqual(HealthStatus.SKIP);
      expect(report.item(CheckIds.CORE)!.status).assertEqual(HealthStatus.FAIL);
      // 报告顺序 = 检查顺序，且每项都有耗时
      expect(report.items[0].id).assertEqual(CheckIds.SUBSCRIPTION);
      expect(report.items[9].id).assertEqual(CheckIds.INTENT);
      expect(report.item(CheckIds.CORE)!.durationMs >= 0).assertTrue();
      // 汇总：首个失败项是 node（DNS 在它之后）
      const s = summarize(report);
      expect(s.overall).assertEqual(HealthOverall.BROKEN);
      expect(s.firstFailId).assertEqual(CheckIds.NODE);
      expect(s.failCount).assertEqual(4);   // node + core + dns(超时) + egress-ipv4(抛异常)
      expect(s.passCount).assertEqual(5);
      expect(s.skipCount).assertEqual(1);
      // 修复动作：有序且有限
      const steps = repairSteps(report);
      expect(steps[0]).assertEqual(RepairActions.RESELECT_NODE);
      expect(steps[1]).assertEqual(RepairActions.RESTART_CORE);
      expect(steps[2]).assertEqual(RepairActions.FIX_DNS);
      // 全部 10 项探针都被调用过（互不阻断）
      expect(stubs.calls.length).assertEqual(10);
    });

    it('link_health_checker_total_budget_truncates_to_skip', 0, async () => {
      let t = 0;
      const clock = (): number => {
        t = t + 10;
        return t;
      };
      const stubs = new FakeLinkHealthProbes();
      const checker = new LinkHealthChecker(stubs, 5, 50, clock);
      const report = await checker.run();
      expect(report.items.length).assertEqual(10);
      expect(report.truncated).assertTrue();
      expect(stubs.calls.length).assertEqual(0);
      for (const item of report.items) {
        // 超预算的项是 skip，绝不误报为 fail
        expect(item.status).assertEqual(HealthStatus.SKIP);
      }
      const s = summarize(report);
      expect(s.overall).assertEqual(HealthOverall.DEGRADED);
      expect(s.failCount).assertEqual(0);
      expect(repairSteps(report).length).assertEqual(0);
    });

    // ── SmartSelector：评分 / 排序 / 确定性 ────────────────────────
    it('smart_selector_scoring_and_ranking', 0, () => {
      const nowMs = 2000;
      const candidates: NodeCandidate[] = [
        NodeCandidate.of('fast-lowrate', 50, 0, 0.5, 1000, 0),
        NodeCandidate.of('slow-highrate', 120, 0, 1.0, 1000, 0),
        NodeCandidate.of('untested', LATENCY_UNTESTED, 0, -1, 0, 0),
        NodeCandidate.of('dead', LATENCY_FAILED, 3, 0, 0, 0)
      ];
      // 评分 = 延迟基值 + (1-成功率)*300 + 连续失败*400 + 冷却 + 陈旧
      expect(scoreOf(candidates[0], nowMs)).assertEqual(200);   // 50 + 150
      expect(scoreOf(candidates[1], nowMs)).assertEqual(120);   // 120 + 0
      expect(scoreOf(candidates[2], nowMs)).assertEqual(650);   // 500(未测) + 150(中性 0.5)
      expect(scoreOf(candidates[3], nowMs)).assertEqual(3500);  // 2000(失败) + 300 + 3*400
      // 排序：评分升序
      const names = orderedNames(candidates, nowMs);
      expect(names[0]).assertEqual('slow-highrate');
      expect(names[1]).assertEqual('fast-lowrate');
      expect(names[2]).assertEqual('untested');
      expect(names[3]).assertEqual('dead');
      // rank 结果带回下标与可用性
      const ranked: RankedNode[] = rankNodes(candidates, nowMs);
      expect(ranked[0].index).assertEqual(1);
      expect(ranked[0].score).assertEqual(120);
      expect(ranked[3].eligible).assertFalse();

      // 确定性：同分按原始下标稳定排序
      const a = NodeCandidate.of('a', 100, 0, 1, 1000, 0);
      const b = NodeCandidate.of('b', 100, 0, 1, 1000, 0);
      expect(orderedNames([a, b], nowMs)[0]).assertEqual('a');
      expect(orderedNames([b, a], nowMs)[0]).assertEqual('b');
      // 陈旧节点被追加惩罚（距上次成功超过 30 分钟）
      const staleNow = 1901000;
      const stale = NodeCandidate.of('stale', 100, 0, 1, 1000, 0);
      const fresh = NodeCandidate.of('fresh', 100, 0, 1, staleNow, 0);
      expect(scoreOf(stale, staleNow) > scoreOf(fresh, staleNow)).assertTrue();
      expect(scoreOf(stale, staleNow)).assertEqual(300);   // 100 + 200(陈旧)
      // 从未成功过（lastSuccessAt=0）不算陈旧，不加罚
      expect(scoreOf(NodeCandidate.of('never', 100, 0, 1, 0, 0), staleNow)).assertEqual(100);
      // 参数可配置：惩罚权重变化立即反映到评分
      const lenient = new SelectorOptions();
      lenient.failPenalty = 0;
      lenient.successWeight = 0;
      expect(scoreOf(candidates[3], nowMs, lenient)).assertEqual(2000);
    });

    it('smart_selector_cooldown_penalty_and_eligibility', 0, () => {
      const nowMs = 100000;
      const hot = NodeCandidate.of('hot', 30, 0, 1, nowMs, nowMs + 5000);
      const cold = NodeCandidate.of('cold', 300, 0, 1, nowMs, 0);
      const risky = NodeCandidate.of('risky', 20, 3, 1, nowMs, 0);
      // 冷却判定
      expect(isInCooldown(hot, nowMs)).assertTrue();
      expect(isInCooldown(hot, nowMs + 5000)).assertFalse();
      // 冷却/达阈值 → 不可参与选点
      expect(isEligible(hot, nowMs)).assertFalse();
      expect(isEligible(risky, nowMs)).assertFalse();
      expect(isEligible(cold, nowMs)).assertTrue();
      const relaxed = new SelectorOptions();
      relaxed.failThreshold = 5;
      expect(isEligible(risky, nowMs, relaxed)).assertTrue();
      // 冷却惩罚让「低延迟但刚失败过」的节点排到「高延迟但健康」之后
      expect(scoreOf(hot, nowMs) > scoreOf(cold, nowMs)).assertTrue();
      expect(orderedNames([hot, cold], nowMs)[0]).assertEqual('cold');
    });

    // ── SmartSelector：failoverAllowed（阈值 + 冷却 + 防抖）──────────
    it('smart_selector_failover_allowed_threshold_and_cooldown', 0, () => {
      const nowMs = 100000;
      const cool = NodeCandidate.of('cool', 50, 3, 0, nowMs, nowMs + 60000);
      const free = NodeCandidate.of('free', 50, 3, 0, nowMs, 0);
      // 未达阈值 → 不允许切换
      expect(failoverAllowed(null, 0, nowMs)).assertFalse();
      expect(failoverAllowed(null, 2, nowMs)).assertFalse();
      // 达阈值 → 允许
      expect(failoverAllowed(null, 3, nowMs)).assertTrue();
      expect(failoverAllowed(null, 9, nowMs)).assertTrue();
      // 当前节点冷却中 → 再切被拒（防抖核心）
      expect(failoverAllowed(cool, 3, nowMs)).assertFalse();
      expect(failoverAllowed(cool, 3, nowMs + 60000)).assertTrue();
      expect(failoverAllowed(free, 3, nowMs)).assertTrue();
      // 关闭自动切换 → 恒不允许
      const locked = new SelectorOptions();
      locked.autoSwitch = false;
      expect(failoverAllowed(null, 9, nowMs, locked)).assertFalse();
      // 阈值可配置
      const eager = new SelectorOptions();
      eager.failThreshold = 1;
      expect(failoverAllowed(null, 1, nowMs, eager)).assertTrue();
      const patient = new SelectorOptions();
      patient.failThreshold = 10;
      expect(failoverAllowed(null, 9, nowMs, patient)).assertFalse();
      // 非法参数被夹到安全值（failThreshold < 1 → 1）
      const bad = new SelectorOptions();
      bad.failThreshold = 0;
      expect(normalizeOptions(bad).failThreshold).assertEqual(1);
      expect(failoverAllowed(null, 1, nowMs, bad)).assertTrue();
    });

    // ── SmartSelector：nextBestNode（迟滞切换 / 首次选择 / 禁用）────
    it('smart_selector_next_best_node', 0, () => {
      const nowMs = 100000;
      const cur = NodeCandidate.of('cur', 200, 0, 1, nowMs, 0);
      const better = NodeCandidate.of('better', 50, 0, 1, nowMs, 0);
      const slight = NodeCandidate.of('slight', 190, 0, 1, nowMs, 0);
      // cur=null → 返回最优可用节点（首次选择）
      expect(nextBestNode(null, [cur, better], nowMs)!.name).assertEqual('better');
      // 明显更优 → 切换（50+30 <= 200）
      expect(nextBestNode(cur, [cur, better], nowMs)!.name).assertEqual('better');
      // 只是略优（190+30 > 200）→ 迟滞，不切
      expect(nextBestNode(cur, [cur, slight], nowMs)).assertNull();
      // 自身已是最优 → 不切
      expect(nextBestNode(better, [cur, better], nowMs)).assertNull();
      // 关闭自动切换 → 永不返回新节点
      const locked = new SelectorOptions();
      locked.autoSwitch = false;
      expect(nextBestNode(cur, [cur, better], nowMs, locked)).assertNull();
      // cur 已达失败阈值 → 立即切换，无视迟滞
      const deadCur = NodeCandidate.of('cur', LATENCY_FAILED, 3, 0, nowMs, 0);
      expect(nextBestNode(deadCur, [deadCur, slight], nowMs)!.name).assertEqual('slight');
      // 无可用候选 / 空列表 → null（宁可不动也不乱切）
      const allDead: NodeCandidate[] = [
        NodeCandidate.of('x', LATENCY_FAILED, 5, 0, nowMs, 0),
        NodeCandidate.of('y', LATENCY_FAILED, 4, 0, nowMs, 0)
      ];
      expect(nextBestNode(cur, allDead, nowMs)).assertNull();
      expect(nextBestNode(cur, [], nowMs)).assertNull();
      // 迟滞可配置：switchMargin=0 → 略优也切
      const noHysteresis = new SelectorOptions();
      noHysteresis.switchMargin = 0;
      expect(nextBestNode(cur, [cur, slight], nowMs, noHysteresis)!.name).assertEqual('slight');
    });

    // ── SmartSelector：markSuccess / markFailure 纯状态迁移 ─────────
    it('smart_selector_mark_success_failure_transitions', 0, () => {
      const nowMs = 500000;
      // 成功率派生规则与 NodeSortPersistence 一致：未测=-1，上次失败=0，否则 1/(1+failCount)
      expect(NodeCandidate.deriveSuccessRate(LATENCY_UNTESTED, 0, false)).assertEqual(-1);
      expect(NodeCandidate.deriveSuccessRate(100, 0, false)).assertEqual(0);
      expect(NodeCandidate.deriveSuccessRate(100, 0, true)).assertEqual(1);
      expect(NodeCandidate.deriveSuccessRate(100, 1, true)).assertEqual(0.5);
      expect(NodeCandidate.deriveSuccessRate(100, 3, true)).assertEqual(0.25);
      expect(NodeCandidate.fromStats('n', 100, 1, true, 1, 0).recentSuccessRate).assertEqual(0.5);

      // markSuccess：清零失败、上调成功率、刷新上次成功时间、清冷却、失败延迟回退未测
      const failed = NodeCandidate.of('n', LATENCY_FAILED, 2, 0, 0, nowMs + 9999);
      const afterOk = markSuccess(failed, nowMs);
      expect(failed.consecutiveFailures).assertEqual(2);        // 入参绝不被修改
      expect(failed.cooldownUntil).assertEqual(nowMs + 9999);
      expect(failed.latency).assertEqual(LATENCY_FAILED);
      expect(afterOk.consecutiveFailures).assertEqual(0);
      expect(afterOk.recentSuccessRate).assertEqual(0.5);       // 0 + (1-0)*0.5
      expect(afterOk.lastSuccessAt).assertEqual(nowMs);
      expect(afterOk.cooldownUntil).assertEqual(0);
      expect(afterOk.latency).assertEqual(LATENCY_UNTESTED);
      // 成功率 EWMA：未知→1；0.5→0.75；1→1（封顶）
      expect(markSuccess(NodeCandidate.of('u', 100, 0, -1, 0, 0), nowMs).recentSuccessRate).assertEqual(1);
      expect(markSuccess(NodeCandidate.of('h', 100, 0, 0.5, 0, 0), nowMs).recentSuccessRate).assertEqual(0.75);
      expect(markSuccess(NodeCandidate.of('f', 100, 0, 1, 0, 0), nowMs).recentSuccessRate).assertEqual(1);

      // markFailure：连续失败 +1、延迟记失败、成功率衰减、达阈值才进冷却
      const healthy = NodeCandidate.of('h2', 80, 0, 1, nowMs - 1000, 0);
      const f1 = markFailure(healthy, nowMs);
      expect(healthy.consecutiveFailures).assertEqual(0);       // 无副作用
      expect(healthy.latency).assertEqual(80);
      expect(f1.consecutiveFailures).assertEqual(1);
      expect(f1.latency).assertEqual(LATENCY_FAILED);
      expect(f1.recentSuccessRate).assertEqual(0.5);            // 1 * 0.5
      expect(f1.cooldownUntil).assertEqual(0);                  // 未达阈值不冷却
      expect(f1.lastSuccessAt).assertEqual(nowMs - 1000);       // 上次成功时间保留
      const f2 = markFailure(f1, nowMs);
      expect(f2.consecutiveFailures).assertEqual(2);
      expect(f2.recentSuccessRate).assertEqual(0.25);
      expect(f2.cooldownUntil).assertEqual(0);
      const f3 = markFailure(f2, nowMs);
      expect(f3.consecutiveFailures).assertEqual(3);
      expect(f3.cooldownUntil).assertEqual(nowMs + 60000);      // 达阈值 → 进入冷却
      // 冷却期内不允许再切，冷却过期后恢复
      expect(failoverAllowed(f3, 3, nowMs)).assertFalse();
      expect(failoverAllowed(f3, 3, nowMs + 60000)).assertTrue();
      // 失败时成功率未知 → 直接归零
      expect(markFailure(NodeCandidate.of('u2', 100, 0, -1, 0, 0), nowMs).recentSuccessRate).assertEqual(0);
      // 冷却时长可配置
      const tight = new SelectorOptions();
      tight.cooldownMs = 1000;
      tight.failThreshold = 2;
      const g1 = markFailure(healthy, nowMs, tight);
      expect(g1.cooldownUntil).assertEqual(0);
      const g2 = markFailure(g1, nowMs, tight);
      expect(g2.cooldownUntil).assertEqual(nowMs + 1000);
    });

    it('smart_selector_options_clamped_and_concurrency_constant', 0, () => {
      // 默认值与常量
      expect(MAX_SELECT_CONCURRENCY).assertEqual(4);
      const d = normalizeOptions();
      expect(d.failThreshold).assertEqual(3);
      expect(d.cooldownMs).assertEqual(60000);
      expect(d.autoSwitch).assertTrue();
      expect(d.maxConcurrency).assertEqual(MAX_SELECT_CONCURRENCY);
      // 非法输入夹到安全范围
      const bad = new SelectorOptions();
      bad.failThreshold = 0;
      bad.cooldownMs = -1;
      bad.switchMargin = -5;
      bad.failPenalty = -1;
      bad.maxConcurrency = 0;
      const fixed = normalizeOptions(bad);
      expect(fixed.failThreshold).assertEqual(1);
      expect(fixed.cooldownMs).assertEqual(0);
      expect(fixed.switchMargin).assertEqual(0);
      expect(fixed.failPenalty).assertEqual(0);
      expect(fixed.maxConcurrency).assertEqual(1);
      // 并发上限：与常量取小，恒 >= 1
      expect(selectConcurrency()).assertEqual(MAX_SELECT_CONCURRENCY);
      const big = new SelectorOptions();
      big.maxConcurrency = 100;
      expect(selectConcurrency(big)).assertEqual(MAX_SELECT_CONCURRENCY);
      const small = new SelectorOptions();
      small.maxConcurrency = 2;
      expect(selectConcurrency(small)).assertEqual(2);
      // 传入的 options 不被原地修改（纯函数）
      const keep = new SelectorOptions();
      keep.failThreshold = 7;
      normalizeOptions(keep);
      expect(keep.failThreshold).assertEqual(7);
    });
  });
}

/**
 * 链路探针桩：可注入结论 / 挂死 / 抛异常，验证「单点失败不阻断其余检查」。
 * 挂死用永不 settle 的 Promise 模拟（真实场景=内核/网络 IPC 卡死）。
 */
class FakeLinkHealthProbes implements LinkHealthProbes {
  outcomes: Map<string, ProbeOutcome> = new Map<string, ProbeOutcome>();
  hangIds: Set<string> = new Set<string>();
  throwIds: Set<string> = new Set<string>();
  calls: string[] = [];

  private pick(id: string): Promise<ProbeOutcome> {
    this.calls.push(id);
    if (this.hangIds.has(id)) {
      return new Promise<ProbeOutcome>((resolve) => {
        // 故意永不 settle
      });
    }
    if (this.throwIds.has(id)) {
      throw new Error('probe threw: ' + id);
    }
    const o = this.outcomes.get(id);
    if (o === undefined) {
      return Promise.resolve(ProbeOutcome.skip('stub: not configured'));
    }
    return Promise.resolve(o);
  }

  probeSubscription(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.SUBSCRIPTION);
  }

  probeNode(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.NODE);
  }

  probeVpnAuth(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.VPN_AUTH);
  }

  probeTun(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.TUN);
  }

  probeCore(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.CORE);
  }

  probeClashApi(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.CLASH_API);
  }

  probeDns(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.DNS);
  }

  probeIpv4Egress(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.EGRESS_IPV4);
  }

  probeIpv6(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.IPV6);
  }

  probeIntentConsistency(): Promise<ProbeOutcome> {
    return this.pick(CheckIds.INTENT);
  }
}

/** 心跳探针桩：注入任意心跳年龄，模拟内核存活/崩溃/超时 */
class HeartbeatProbeStub implements CoreLivenessProbe {
  private age: number = -1;

  constructor(age: number, label: string) {
    this.age = age;
  }

  heartbeatAgeMs(): number {
    return this.age;
  }
}
