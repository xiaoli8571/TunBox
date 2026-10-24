import { pathToFileURL } from 'node:url';
const g = (n) => pathToFileURL(`tools/true-chain-harness/generated/${n}`).href;
const { ProfileConfigMerger } = await import(g('ProfileConfigMerger.ts'));
const overlay = `mixed-port: 7890
mode: rule
proxy-providers:
  own-pp:
    type: http
    url: "https://example.invalid/pp.yaml"
    path: ./providers/own-pp.yaml
rules:
  - MATCH,PROXY
`;
const profile = `proxies:
  - name: 香港01
    type: ss
    server: a.b
    port: 443
    cipher: aes-128-gcm
    password: x
proxy-providers:
  sub-pp:
    type: http
    url: "https://example.invalid/sub-pp.yaml"
    path: ./providers/sub-pp.yaml
`;
const r = ProfileConfigMerger.merge(overlay, profile);
console.log('ok=', r.ok, 'applied=', r.applied);
console.log(r.yaml.split('\n').filter(l => /proxy-providers|own-pp|sub-pp/.test(l)).join('\n'));
