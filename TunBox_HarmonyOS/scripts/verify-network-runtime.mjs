// Execute production network/lifecycle/config code. Only OS boundaries and time are faked.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';
import { harness, flush, deferred } from './orchestrator-runtime-harness.mjs';
const root = new URL('../entry/src/main/ets/', import.meta.url);
let passed = 0;
function sandbox() {
  let now=10000,id=0;
  const timers=new Map(),calls=[],status=[];
  class Clock extends Date {static now(){return now;}}
  const platform=vm.createContext({console,Date:Clock,Map,Set,Promise,Math,JSON,Number,
    setTimeout(fn,ms){const n=++id;timers.set(n,{fn,at:now+ms,ms});return n;},
    clearTimeout(n){timers.delete(n);},
    AppLogger:{info(){},warn(){},error(){},errText:String},
    VpnExtensionAbility:class {},AppRoutingRuntime:class {},
    ReconnectReason:{CORE_NOT_ALIVE:'core-not-alive',RETRY:'retry'},
    coreBridge:{async updateNetwork(dns,reset){calls.push({dns,reset});return true;},async isCoreAlive(){return true;}},
    UnifiedScheduler:{every(fn,ms){const n=++id;timers.set(n,{fn,at:now+ms,ms,repeat:true});return n;},clear(n){timers.delete(n);}},
  });
  return {platform,timers,calls,status,advance:async(ms)=>{
    now+=ms;
    for(const [n,t] of [...timers]) if(t.at<=now){if(t.repeat)t.at=now+t.ms;else timers.delete(n);t.fn();}
    await flush();
  }};
}
function load(file,names,h) {
  const source=fs.readFileSync(new URL(file,root),'utf8').replace(/^import\b[\s\S]*?;\r?\n/gm,'')
    .replace(/^export default /gm,'').replace(/^export /gm,'');
  const result=vm.runInContext(stripTypeScriptTypes(`(()=>{${source}\nreturn {${names}}})()`,{mode:'transform'}),h.platform);
  Object.assign(h.platform,result);return result;
}
function setup() {
  const h=sandbox();
  const {NetworkStateWatcher:W,NetworkSnapshot:S}=load('commons/services/NetworkStateWatcher.ets','NetworkStateWatcher,NetworkSnapshot,NetTypes',h);
  load('commons/services/VpnRecoveryPolicy.ets','BASE_MTU,RECOVERY_STABLE_MS,mtuForNetType,coreRecoveryDelayMs,tunnelRebuildDelayMs,MAX_CORE_RECOVERY_ATTEMPTS,MAX_TUNNEL_REBUILDS',h);
  const {TunBoxVpnExtension:E}=load('vpnability/VpnExtensionAbility.ets','TunBoxVpnExtension',h);
  const snap=(id,type='wifi',dns=['1.1.1.1'])=>Object.assign(new S(),{netId:id,netType:type,dnsServers:dns,interfaceName:type==='wifi'?'wlan0':'rmnet0',addresses:['192.0.2.1/24'],validated:true});
  const ext=()=>{
    const e=Object.create(E.prototype);
    Object.assign(e,{lastNetworkGeneration:0,lastNetworkType:'wifi',latestNetwork:snap(1),appliedNetwork:snap(1),pendingNetwork:null,
      networkUpdateFlight:null,networkUpdateTimer:-1,networkUpdateAttempts:0,stableSince:0,networkReady:true,resetFlowsPending:false,
      networkAvailable:true,connection:{},activeMtu:1360,tunConfig:{mtu:1360},tunnelRebuilds:0,stopped:false,
      cleanupPromise:null,recoveryRunning:false,rebuilding:false,rebuildTimer:-1,recoveryTimer:-1,recoveryAttempts:0,
      lifecycleGeneration:1,coreDeathStrikes:0,coreMonitorTimer:-1});
    e.writeStatus=(...args)=>h.status.push(args);e.startLeaseTimer=()=>{};e.startMemSampler=()=>{};
    return e;
  };
  return {...h,W,S,E,snap,ext};
}
async function test(name,fn){await fn();passed++;console.log('PASS '+name);}
await test('trailing cellular restoration is delivered without another OS event',async()=>{
  const h=setup(),w=new h.W(200),events=[];w.addListener({onNetworkTypeChanged(t,g){events.push([t,g]);}});
  w.feedSnapshotForTest(h.snap(1));await h.advance(2000);w.feedForTest('none');
  await h.advance(50);w.feedSnapshotForTest(h.snap(2,'cellular'));await h.advance(200);
  assert.equal(w.networkType(),'cellular');assert.equal(events.length,3);
});
await test('Wi-Fi A/B and DNS changes advance generation even when type stays Wi-Fi',async()=>{
  const h=setup(),w=new h.W(200);w.feedSnapshotForTest(h.snap(1));
  w.feedSnapshotForTest(h.snap(2));await h.advance(200);assert.equal(w.generation(),2);
  w.feedSnapshotForTest(h.snap(2,'wifi',['9.9.9.9']));await h.advance(200);assert.equal(w.generation(),3);
});
await test('burst coalescing retains only latest snapshot; duplicate signals cannot starve it',async()=>{
  const h=setup(),w=new h.W(200);w.feedSnapshotForTest(h.snap(1));w.feedSnapshotForTest(h.snap(2));
  await h.advance(100);w.feedSnapshotForTest(h.snap(3));await h.advance(100);w.feedSnapshotForTest(h.snap(3));
  await h.advance(100);assert.equal(w.snapshot().netId,3);assert.equal(w.generation(),2);
});
await test('stop cancels trailing emission and stale registration cannot alter restarted watcher',async()=>{
  const h=setup(),w=new h.W(200);let callbacks=[];
  h.platform.connection={getDefaultNetSync:()=>({netId:0}),createNetConnection:()=>({on(){},register(fn){callbacks.push(fn);},unregister(){}})};
  w.start({});w.feedSnapshotForTest(h.snap(1));w.stop();w.start({});callbacks[0]({code:201});
  await h.advance(500);assert.equal(w.networkType(),'none');assert.equal(w.isSubscribed(),true);w.stop();
});
await test('physical properties are captured and read failures preserve previous state',async()=>{
  const h=setup(),w=new h.W(0);let fail=false;
  h.platform.connection={NetCap:{NET_CAPABILITY_VALIDATED:16,NET_CAPABILITY_NOT_METERED:11},
    getDefaultNetSync(){if(fail)throw Error('IPC');return {netId:9};},
    getNetCapabilitiesSync:()=>({bearerTypes:[1],networkCap:[16,11]}),
    getConnectionPropertiesSync:()=>({interfaceName:'wlan0',dnses:[{address:'1.1.1.1'}],linkAddresses:[{address:{address:'192.0.2.1'},prefixLength:24}]})};
  w.refreshSync();assert.equal(w.snapshot().netId,9);assert.equal(w.snapshot().metered,false);
  fail=true;w.refreshSync();assert.equal(w.snapshot().netId,9);assert.equal(w.generation(),1);
});
await test('busy recovery queues latest snapshot without changing MTU or consuming rebuilds',async()=>{
  const h=setup(),e=h.ext();e.recoveryRunning=true;
  e.onNetworkTypeChanged('cellular',1,h.snap(2,'cellular'));
  e.onNetworkTypeChanged('wifi',2,h.snap(3));
  assert.equal(e.activeMtu,1360);assert.equal(e.tunConfig.mtu,1360);assert.equal(e.tunnelRebuilds,0);assert.equal(h.calls.length,0);
  e.recoveryRunning=false;e.flushNetworkUpdate();await flush();
  assert.equal(e.appliedNetwork.netId,3);assert.equal(h.calls.length,1);assert.equal(h.calls[0].reset,true);
});
await test('DNS-only change refreshes DNS but does not close established flows',async()=>{
  const h=setup(),e=h.ext();e.onNetworkTypeChanged('wifi',1,h.snap(1,'wifi',['9.9.9.9']));await flush();
  assert.equal(h.calls.length,1);assert.equal(h.calls[0].reset,false);
});
await test('validation-only change updates state without resetting DNS or flows',async()=>{
  const h=setup(),e=h.ext();const n=h.snap(1);n.validated=false;e.onNetworkTypeChanged('wifi',1,n);await flush();
  assert.equal(h.calls.length,0);assert.equal(e.appliedNetwork.validated,false);
});
await test('offline then same network still invalidates old flows on restoration',async()=>{
  const h=setup(),e=h.ext();const n=new h.S();n.netType='none';e.onNetworkTypeChanged('none',1,n);
  e.onNetworkTypeChanged('wifi',2,h.snap(1));await flush();assert.equal(h.calls[0].reset,true);
});
await test('in-flight update drains a newer network rather than dropping it',async()=>{
  const h=setup(),e=h.ext(),gate=deferred();
  h.platform.coreBridge.updateNetwork=async(dns,reset)=>{h.calls.push({dns,reset});if(h.calls.length===1)await gate.promise;return true;};
  e.onNetworkTypeChanged('cellular',1,h.snap(2,'cellular'));await flush();e.onNetworkTypeChanged('wifi',2,h.snap(3));
  gate.resolve();await flush();assert.equal(h.calls.length,2);assert.equal(e.appliedNetwork.netId,3);
});
await test('failed network update retries without restarting a healthy core',async()=>{
  const h=setup(),e=h.ext();let attempts=0,restarts=0;
  h.platform.coreBridge.updateNetwork=async()=>++attempts>1;e.scheduleCoreRecovery=()=>restarts++;
  e.onNetworkTypeChanged('cellular',1,h.snap(2,'cellular'));await flush();assert.equal(attempts,1);
  await h.advance(1000);assert.equal(attempts,2);assert.equal(restarts,0);
});
await test('late native completion cannot publish a stopped lifecycle',async()=>{
  const h=setup(),e=h.ext(),gate=deferred();h.platform.coreBridge.updateNetwork=async()=>{await gate.promise;return true;};
  e.onNetworkTypeChanged('wifi',1,h.snap(2));await flush();e.stopped=true;e.lifecycleGeneration++;
  gate.resolve();await flush();assert.equal(e.appliedNetwork.netId,1);assert.equal(h.status.length,0);
});
await test('twenty ordinary network changes never consume recovery budget or rebuild TUN',async()=>{
  const h=setup(),e=h.ext();for(let i=1;i<=20;i++){const type=i%2?'cellular':'wifi';e.onNetworkTypeChanged(type,i,h.snap(i+1,type));await flush();}
  assert.equal(e.tunnelRebuilds,0);assert.equal(e.recoveryAttempts,0);assert.equal(e.activeMtu,1360);
});
await test('one minute of healthy probes replenishes consecutive failure budget',async()=>{
  const h=setup(),e=h.ext();e.tunnelRebuilds=2;e.recoveryAttempts=3;e.startCoreMonitor();
  await h.advance(10000);assert.equal(e.tunnelRebuilds,2);await h.advance(60000);assert.equal(e.tunnelRebuilds,0);assert.equal(e.recoveryAttempts,0);e.stopCoreMonitor();
});
await test('App observes network switches without scheduling session teardown',async()=>{
  const h=harness();Object.assign(h.platform,load('commons/services/NetworkStateWatcher.ets','NetTypes',{platform:h.platform}));
  h.orch.lastNetType='wifi';h.orch.lastNetGeneration=0;let reconnects=0;
  h.orch.reconnectManager=()=>({cancel(){},request(){reconnects++;}});
  h.orch.onNetworkTypeChanged('cellular',1);await flush();assert.equal(reconnects,0);h.stop();
});
await test('obsolete failed update does not discard a newer pending network',async()=>{
  const h=setup(),e=h.ext(),gate=deferred();let first=true;
  h.platform.coreBridge.updateNetwork=async(dns,reset)=>{h.calls.push({dns,reset});if(first){first=false;await gate.promise;return false;}return true;};
  e.onNetworkTypeChanged('cellular',1,h.snap(2,'cellular'));await flush();e.onNetworkTypeChanged('wifi',2,h.snap(3));
  gate.resolve();await flush();assert.equal(e.appliedNetwork.netId,3);assert.equal(h.calls.length,2);
});
await test('network update cannot run before Core startup completes',async()=>{
  const h=setup(),e=h.ext();e.networkReady=false;e.onNetworkTypeChanged('cellular',1,h.snap(2,'cellular'));
  await flush();assert.equal(h.calls.length,0);e.networkReady=true;e.flushNetworkUpdate();await flush();assert.equal(h.calls.length,1);
});
const h=setup();load('commons/services/YamlMerger.ets','YamlMerger',h);
const {ProfileConfigMerger:M}=load('commons/tunbox/ProfileConfigMerger.ets','ProfileConfigMerger',h);
await test('final contract restores missing IPv6 pool without replacing subscription DNS',()=>{
  const yaml='ipv6: true\ntun:\n  mtu: 9000\n  enable: true\ndns:\n  enable: true\n  enhanced-mode: fake-ip\n  ipv6: true\n  nameserver: [https://example.com/dns-query]\n';
  const out=M.enforceTunnelContract(yaml,1360,true);
  assert.ok(out.includes('  mtu: 1360'));assert.ok(!out.includes('9000'));assert.ok(out.includes('  fake-ip-range6: fdfe:dcba:9876::/64'));
  assert.ok(out.includes('nameserver: [https://example.com/dns-query]'));assert.equal(M.enforceTunnelContract(out,1360,true).trim(),out.trim());
});
await test('custom real-address mode is preserved but cannot advertise unrouteable AAAA',()=>{
  const yaml='tun:\n  mtu: 1400\ndns:\n  enable: true\n  enhanced-mode: redir-host\n  ipv6: true\n  nameserver: [1.1.1.1]\n';
  const out=M.enforceTunnelContract(yaml,1360,true);assert.ok(out.includes('enhanced-mode: redir-host'));assert.ok(out.includes('  ipv6: false'));assert.ok(!out.includes('fake-ip-range6'));
});
await test('IPv6 off and explicit dns.ipv6=false never gain a fake IPv6 pool',()=>{
  const yaml='tun:\n  mtu: 1400\ndns:\n  enable: true\n  enhanced-mode: fake-ip\n  ipv6: false\n';
  for(const on of [true,false]){const out=M.enforceTunnelContract(yaml,1360,on);assert.ok(out.includes('  ipv6: false'));assert.ok(!out.includes('fake-ip-range6'));}
});
await test('actual kernel bridge no longer forces gvisor over validated mips YAML',()=>{
  const bridge=fs.readFileSync(new URL('../../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/bridge/bridge.go',import.meta.url),'utf8');
  assert.ok(!/cfg\.General\.Tun\.Stack\s*=/.test(bridge));assert.ok(bridge.includes('func UpdateNetwork('));
});
console.log(`RESULT: ${passed} network runtime checks passed (mocked OS; not device validation)`);
