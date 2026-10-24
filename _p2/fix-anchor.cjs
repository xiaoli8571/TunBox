const fs = require('node:fs');
let s = fs.readFileSync('settings-simplify.cjs', 'utf8');
s = s.replace(`const endMark = '            Column({ space: 12 }) {\\n              this.SectionHeader($r(\\'app.media.ic_shield\\'), $r(\\'app.string.settings_background_connection\\'))';
const si = t.indexOf(startMark);
const ei = t.indexOf(endMark);
if (si < 0 || ei < 0 || ei < si) { console.log('ANCHOR MISS', si, ei); process.exit(1); }`,
`const si = t.indexOf(startMark);
const bgHeader = "this.SectionHeader($r('app.media.ic_shield'), $r('app.string.settings_background_connection'))";
const bgIdx = t.indexOf(bgHeader);
const ei = bgIdx < 0 ? -1 : t.lastIndexOf('Column(', bgIdx);
if (si < 0 || ei < 0 || ei < si) { console.log('ANCHOR MISS', si, ei); process.exit(1); }`);
fs.writeFileSync('settings-simplify.cjs', s);
console.log('patched anchor logic');
