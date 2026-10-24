const fs = require('node:fs');
const p = 'scripts/orchestrator-runtime-harness.mjs';
let t = fs.readFileSync(p, 'utf8');
t = t.replace("    fs: { async stat() { return {}; }, statSync(path) {",
  "    fs: { OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2, CREATE: 64, TRUNC: 512 },\n"
+ "      async stat() { return {}; }, statSync(path) {");
fs.writeFileSync(p, t);
console.log('OpenMode added');
