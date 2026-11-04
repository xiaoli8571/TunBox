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
const resolvedScratch = fs.realpathSync(scratch);
assert.equal(path.dirname(resolvedScratch), fs.realpathSync(os.tmpdir()));
assert.ok(path.basename(resolvedScratch).startsWith('tunbox-probe-socket-bind-'));
for (const name of ['go.mod','bridge.go','bridge_test.go','protect_policy.go']) fs.unlinkSync(path.join(resolvedScratch,name));
fs.rmdirSync(resolvedScratch);
