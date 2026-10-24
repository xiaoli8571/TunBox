const fs = require('node:fs');
const p = 'scripts/orchestrator-runtime-harness.mjs';
const lines = fs.readFileSync(p, 'utf8').split('\n');
// 定位 fs 对象块（77..79）
const start = lines.findIndex((l) => l.includes("fs: { async stat() { return {}; }, statSync(path) {"));
if (start < 0 || !lines[start + 2].trim().startsWith('return {}; } },')) { console.log('MISS', start); process.exit(1); }
const repl = [
  "    fs: { async stat() { return {}; }, statSync(path) {",
  "      if (path.endsWith('hyper_adrules_ads.mrs')) { if (!h.ruleReady) throw new Error('missing'); return { size: 4096 }; }",
  "      return {}; },",
  "      // 规则集就绪判据含 zstd 魔数 0x28B52FFD：替身必须能读回头 4 字节，否则",
  "      // 生产侧的 hardened 校验在沙箱里恒为 false（2026-10-23 合并 PR #5 时补）。",
  "      openSync(path) { if (path.endsWith('hyper_adrules_ads.mrs') && !h.ruleReady) throw new Error('missing'); return { fd: 1 }; },",
  "      readSync(_fd, buffer) { const a = new Uint8Array(buffer);",
  "        a[0] = 0x28; a[1] = 0xB5; a[2] = 0x2F; a[3] = 0xFD; return 4; },",
  "      closeSync() {},",
  "    },",
];
lines.splice(start, 3, ...repl);
fs.writeFileSync(p, lines.join('\n'));
console.log('harness patched at line', start + 1);
