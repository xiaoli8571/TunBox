// Execute the production Go socket hook on Windows. Only pipe I/O and logging
// are replaced at the OS boundary; the binder and VPN receipt gate are unchanged.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const core = new URL('../../mihomo-build/mihomo-smart-462455136157a760937c666bba71afe33b1a809e/bridge/', import.meta.url);
const source = fs.readFileSync(new URL('bridge.go', core), 'utf8').replace(/\r\n/g,'\n');
const tests = fs.readFileSync(new URL('bridge_test.go', core), 'utf8').replace(/\r\n/g,'\n');
const logic = source.slice(source.indexOf('var ('), source.indexOf('// releaseProtectLocked'));
assert.ok(logic.includes('func SetHeadlessSocketBinder(') && logic.includes('func protectSocket('));
const ack = source.match(/^func SetProtectResultForFd\([\s\S]*?^}/m)[0];
const scratch = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'tunbox-probe-socket-bind-'));
fs.writeFileSync(path.join(scratch,'go.mod'),'module socket-bind-regression\n\ngo 1.23\n');
fs.writeFileSync(path.join(scratch,'bridge.go'),`package bridge
import ("encoding/binary";"errors";"os";"sync";"sync/atomic";"syscall";"time")
var log = struct{Warnln func(string,...any)}{Warnln:func(string,...any){}}
func writePipe(int,[]byte)(int,error){return 0,errors.New("pipe I/O is not part of this test")}
${logic.replace('syscall.Write(session.writerFd, encoded[:])','writePipe(session.writerFd, encoded[:])')}
${ack}`);
fs.copyFileSync(new URL('protect_policy.go',core),path.join(scratch,'protect_policy.go'));
const rawConn = tests.slice(tests.indexOf('type fixedRawConn'),tests.indexOf('func TestProtectSocketHeadless'));
const binderTest = tests.slice(tests.indexOf('func TestHeadlessPhysicalBinderFailsClosedAndDoesNotReplaceVPNProtection'));
assert.ok(binderTest.startsWith('func TestHeadless'));
fs.writeFileSync(path.join(scratch,'bridge_test.go'),`package bridge
import ("errors";"testing")
${rawConn}
${binderTest}`);
const result = spawnSync('go',['test','-count=1','-v','.'], {cwd:scratch,encoding:'utf8',timeout:120000,windowsHide:true});
assert.equal(result.status,0,result.stdout+'\n'+result.stderr);
console.log(result.stdout.trim());
console.log('PASS production Go binder and protect receipts: stale sessions/exhausted sequences cannot authorize a dial');
// Compile the actual NAPI functions as well: testing the Go nil-binder behavior
// alone cannot catch a caller that leaves a stale callback installed on close.
const napi = fs.readFileSync(new URL('../entry/src/main/cpp/tunbox_core_napi.cpp', import.meta.url), 'utf8');
const nativeLogic = napi.slice(napi.indexOf('static std::atomic<int32_t> g_physical_net_id'), napi.indexOf('EXTERN_C_START'));
assert.ok(nativeLogic.includes('static napi_value SetPhysicalNetId('));
const fixture = fs.readFileSync(new URL('./fixtures/physical-socket-lifecycle.cpp', import.meta.url), 'utf8');
const nativePath = path.join(scratch, 'lifecycle.cpp');
const nativeExe = path.join(scratch, 'lifecycle');
function nativeRun(logic) {
  fs.writeFileSync(nativePath, fixture.replace('/*PRODUCTION*/', logic));
  const unix = value => value.replace(/^([A-Za-z]):/, (_, drive) => '/mnt/' + drive.toLowerCase()).replace(/\\/g, '/');
  const command = process.platform === 'win32' ? 'wsl.exe' : (process.env.CXX || 'g++');
  const prefix = process.platform === 'win32' ? ['-d', process.env.TUNBOX_TEST_WSL_DISTRO || 'Ubuntu', '--', 'g++'] : [];
  const compile = spawnSync(command, [...prefix, '-std=c++17', '-Wall', '-Wextra', unix(nativePath), '-o', unix(nativeExe)],
    {encoding:'utf8', timeout:60000, windowsHide:true});
  assert.equal(compile.status, 0, compile.stdout + compile.stderr);
  return process.platform === 'win32'
    ? spawnSync('wsl.exe', ['-d', process.env.TUNBOX_TEST_WSL_DISTRO || 'Ubuntu', '--', unix(nativeExe)], {encoding:'utf8', timeout:30000, windowsHide:true})
    : spawnSync(nativeExe, [], {encoding:'utf8', timeout:30000});
}
const nativeResult = nativeRun(nativeLogic);
assert.equal(nativeResult.status, 0, nativeResult.stdout + nativeResult.stderr);
console.log('PASS production NAPI: start, network loss, cleanup, repeated close, rejected rebind and later subscription dials');
const regressed = nativeLogic.replace('setBinder(0);', 'setBinder(reinterpret_cast<uintptr_t>(&BindPhysicalSocket));');
assert.notEqual(regressed, nativeLogic, 'negative control must restore the stale callback');
assert.notEqual(nativeRun(regressed).status, 0, 'negative control failed to detect the original regression');
console.log('PASS negative control: the old stale-callback implementation fails the same lifecycle test');
const resolvedScratch = fs.realpathSync(scratch);
assert.equal(path.dirname(resolvedScratch), fs.realpathSync(os.tmpdir()));
assert.ok(path.basename(resolvedScratch).startsWith('tunbox-probe-socket-bind-'));
for (const name of ['go.mod','bridge.go','bridge_test.go','protect_policy.go','lifecycle.cpp','lifecycle']) fs.unlinkSync(path.join(resolvedScratch,name));
fs.rmdirSync(resolvedScratch);
