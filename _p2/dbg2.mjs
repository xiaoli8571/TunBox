import fs from 'node:fs';
import { pathToFileURL } from 'node:url';
const src = fs.readFileSync('scripts/verify-profile-merge-providers.mjs', 'utf8');
const grab = (name) => {
  const m = new RegExp('const ' + name + ' = `([\\s\\S]*?)`;').exec(src); return m[1];
};
const OVERLAY = grab('OVERLAY');
const PROFILE_NO_PROVIDERS = grab('PROFILE_NO_PROVIDERS');
const overlay = OVERLAY.replace('proxy-providers: []', `proxy-providers:
  own-pp:
    type: http
    url: "https://example.invalid/pp.yaml"
    path: ./providers/own-pp.yaml`);
const profile = `${PROFILE_NO_PROVIDERS}proxy-providers:
  sub-pp:
    type: http
    url: "https://example.invalid/sub-pp.yaml"
    path: ./providers/sub-pp.yaml
`;
const { ProfileConfigMerger } = await import(pathToFileURL('tools/true-chain-harness/generated/ProfileConfigMerger.ts').href);
const r = ProfileConfigMerger.merge(overlay, profile);
const lines = r.yaml.split('\n');
const idx = lines.findIndex(l => l.startsWith('proxy-providers:'));
console.log('applied=', r.applied);
console.log(lines.filter(l => /proxy-providers|own-pp|sub-pp|type: http/.test(l)).join('\n'));
console.log('--- 段上下文 ---');
console.log(lines.slice(idx - 2, idx + 14).join('\n'));
