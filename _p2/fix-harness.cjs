const fs = require('node:fs');
const p = 'scripts/orchestrator-runtime-harness.mjs';
let t = fs.readFileSync(p, 'utf8');
const before = "    fs: { async stat() { return {}; }, statSync(path) {\n      if (path.endsWith('hyper_adrules_ads.mrs')) { if (!h.ruleReady) throw new Error('missing'); return { size: 4096 }; }\n      return {}; } },";
if (!t.includes(before)) { console.log('PATTERN MISS'); process.exit(1); }
const after = [
  "    fs: { async stat() { return {}; }, statSync(path) {",
  "      if (path.endsWith('hyper_adrules_ads.mrs')) { if (!h.ruleReady) throw new Error('missing'); return { size: 4096 }; }",
  "      return {}; },",
  "      // 规则集就绪判据含 zstd 魔数（0x28B52FFD）：替身必须能读回头 4 字节，",
  "      // 否则生产侧 hardened 校验在沙箱里永远 false（2026-10-23 合并 PR #5 时补上）。",
  "      openSync(path) { if (path.endsWith('hyper_adrules_ads.mrs') && !h.ruleReady) throw new Error('missing'); return { fd: 1 }; },",
  "      readSync(_fd, buffer) { new Uint8Array(buffer)[0] = 0x28; new Uint8Array(buffer)[1] = 0xB5;",
  "        new Uint8Array(buffer)[2] = 0x2F; new Uint8Array(buffer)[3] = 0xFD; return 4; },",
  "      closeSync() {},",
  "    },",
].join('\n');
t = t.replace(before, after);
fs.writeFileSync(p, t);
console.log('harness patched');
