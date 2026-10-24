// Executes the production classes with platform boundaries and a virtual clock.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { stripTypeScriptTypes } from 'node:module';

const base = new URL('../entry/src/main/ets/', import.meta.url);
function load(file, name, ctx) {
  const source = fs.readFileSync(new URL(file, base), 'utf8')
    .replace(/^import .*;\r?\n/gm, '').replace(/^export /gm, '');
  return vm.runInContext(stripTypeScriptTypes(`(() => {\n${source}\nreturn ${name};\n})()`,
    { mode: 'transform' }), ctx);
}
function deferred() {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return { promise, resolve, reject };
}
async function flush() { for (let i = 0; i < 40; i++) await Promise.resolve(); }

function harness({ audioEnabled = false, deny = [], rendererError = false } = {}) {
  let now = 100000, id = 0, progressActive = false;
  const timers = new Map(), calls = [], sessions = [], renderers = [], logs = [];
  const h = { audioEnabled, deny, rendererError, tasks: [], alive: true,
    queryError: false, queryGate: null, startGate: null, sessionGate: null };
  class Clock extends Date { static now() { return now; } }
  const bg = {
    ContinuousTaskCancelReason: { USER_CANCEL: 1, SYSTEM_CANCEL: 2, USER_CANCEL_REMOVE_NOTIFICATION: 3 },
    ContinuousTaskDetailedCancelReason: { USER_CANCEL_REMOVE_NOTIFICATION: 3 },
    ContinuousTaskSuspendReason: {},
    ContinuousTaskRequest: class {}, BackgroundTaskMode: { MODE_TASK_KEEPING: 9 },
    BackgroundTaskSubmode: { SUBMODE_NORMAL_NOTIFICATION: 0 },
    async startBackgroundRunning(_ctx, request) {
      const modes = Array.isArray(request) ? request : ['taskKeeping'];
      calls.push(['start', [...modes]]);
      if (h.deny.some(x => modes.includes(x))) throw new Error('denied');
      if (h.startGate) { const gate = h.startGate; h.startGate = null; await gate.promise; }
      const notificationId = ++id;
      const continuousTaskId = notificationId + 1000;
      h.tasks = [{ notificationId, continuousTaskId, backgroundModes: [...modes], suspendState: false }];
      return { notificationId, continuousTaskId };
    },
    async stopBackgroundRunning() { calls.push(['stop']); h.tasks = []; },
    async getAllContinuousTasks() {
      calls.push(['query']);
      if (h.queryGate) { const gate = h.queryGate; h.queryGate = null; await gate.promise; }
      if (h.queryError) throw new Error('unavailable');
      return h.tasks;
    }
  };
  const ctx = vm.createContext({
    Date: Clock, Uint8Array, Math, Promise,
    setInterval(fn, delay) { const key = ++id; timers.set(key, { fn, delay }); return key; },
    clearInterval(key) { timers.delete(key); },
    backgroundTaskManager: bg,
    wantAgent: { OperationType: { START_ABILITY: 1 }, WantAgentFlags: { UPDATE_PRESENT_FLAG: 1 },
      async getWantAgent() { return {}; } },
    AppLogger: { info: (...a) => logs.push(a), warn: (...a) => logs.push(a), errText: String },
    SettingsService: { async load() { return { audioKeepAliveEnabled: h.audioEnabled }; } },
    ContinuousTaskKind: { NONE: 'none', TASK_KEEPING: 'taskKeeping',
      DATA_TRANSFER: 'dataTransfer', AUDIO_PLAYBACK: 'audioPlayback' },
    TaskProgressUpdater: { attach: (...a) => { progressActive = a[1] === 'dataTransfer'; calls.push(['progress', ...a]); },
      detach: () => { progressActive = false; calls.push(['detach']); }, isActive: () => progressActive },
    avSession: {
      PlaybackState: { PLAYBACK_STATE_PLAY: 2 },
      async createAVSession() {
        if (h.sessionGate) { const gate = h.sessionGate; h.sessionGate = null; await gate.promise; }
        const handlers = new Map();
        const session = { handlers, destroyed: false,
          async setAVMetadata() {}, async activate() {}, async setAVPlaybackState() {},
          on(name, fn) { handlers.set(name, fn); }, async destroy() { this.destroyed = true; } };
        sessions.push(session); return session;
      }
    },
    audio: {
      AudioSamplingRate: { SAMPLE_RATE_44100: 44100 }, AudioChannel: { CHANNEL_1: 1 },
      AudioSampleFormat: { SAMPLE_FORMAT_S16LE: 1 }, AudioEncodingType: { ENCODING_TYPE_RAW: 0 },
      StreamUsage: { STREAM_USAGE_MUSIC: 1 }, AudioDataCallbackResult: { VALID: 0, INVALID: 1 },
      InterruptHint: { INTERRUPT_HINT_PAUSE: 2, INTERRUPT_HINT_STOP: 3 },
      async createAudioRenderer() {
        if (h.rendererError) throw new Error('renderer unavailable');
        const handlers = new Map();
        const renderer = { handlers, released: false, started: false, volume: null,
          on(name, fn) { handlers.set(name, fn); },
          async setVolume(v) { this.volume = v; calls.push(['volume', v]); },
          async start() { assert.equal(this.volume, 0.03); this.started = true; },
          async stop() { this.started = false; }, async release() { this.released = true; } };
        renderers.push(renderer); return renderer;
      }
    }
  });
  ctx.AudioKeepAlive = load('commons/services/AudioKeepAlive.ets', 'AudioKeepAlive', ctx);
  const guardian = load('commons/services/UiGuardian.ets', 'UiGuardian', ctx);
  ctx.UiGuardian = guardian;
  const watch = load('commons/services/BackgroundTaskWatch.ets', 'BackgroundTaskWatch', ctx);
  return Object.assign(h, { guardian, watch, audio: ctx.AudioKeepAlive, calls, timers, renderers, sessions, logs,
    context: {}, check: async () => h.alive,
    starts: () => calls.filter(x => x[0] === 'start'),
    advance(ms) { now += ms; },
    async tick() { now += 30000; for (const t of [...timers.values()]) t.fn(); await flush(); },
    async close() { await guardian.release({}); await flush();
      assert.equal(timers.size, 0); assert.equal(ctx.AudioKeepAlive.isActive(), false);
      assert.ok(renderers.every(x => x.released)); assert.ok(sessions.every(x => x.destroyed)); }
  });
}

let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log('PASS ' + name); }

await test('default keeps taskKeeping and queries at 30s without extra registration', async () => {
  const h = harness(); assert.equal(await h.guardian.engage(h.context, h.check), true);
  assert.equal(h.guardian.currentTaskType(), 'taskKeeping'); assert.equal(h.renderers.length, 0);
  assert.equal([...h.timers.values()][0].delay, 30000);
  await h.tick(); assert.equal(h.starts().length, 1); await h.close();
});
await test('permission denial retains existing dataTransfer fallback', async () => {
  const h = harness({ deny: ['taskKeeping'] }); await h.guardian.engage(h.context, h.check);
  assert.equal(h.guardian.currentTaskType(), 'dataTransfer'); await h.close();
});
await test('opt-in renders nonzero PCM and registers audio alone', async () => {
  const h = harness({ audioEnabled: true }); await h.guardian.engage(h.context, h.check);
  assert.equal(h.guardian.currentTaskType(), 'audioPlayback');
  assert.deepEqual(h.starts()[0], ['start', ['audioPlayback']]);
  const frame = new ArrayBuffer(4096); h.renderers[0].handlers.get('writeData')(frame);
  assert.ok(new Uint8Array(frame).some(x => x !== 0));
  await h.close();
  h.sessions[0].handlers.get('pause')(); await flush();
  assert.equal(h.guardian.isAutoEngageSuppressed(), false, 'stale callbacks are ignored');
});
await test('renderer failure cleans AVSession and falls back honestly', async () => {
  const h = harness({ audioEnabled: true, rendererError: true });
  await h.guardian.engage(h.context, h.check);
  assert.equal(h.guardian.currentTaskType(), 'taskKeeping');
  assert.ok(h.sessions.every(x => x.destroyed)); await h.close();
});
await test('audio task denial releases renderer before normal fallback', async () => {
  const h = harness({ audioEnabled: true, deny: ['audioPlayback'] });
  await h.guardian.engage(h.context, h.check);
  assert.equal(h.guardian.currentTaskType(), 'taskKeeping');
  assert.ok(h.renderers.every(x => x.released)); await h.close();
});
await test('missing task waits for recheck and re-arms once after backoff', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check); h.tasks = [];
  await h.tick(); assert.equal(h.starts().length, 1);
  await h.tick(); assert.equal(h.starts().length, 2);
  assert.equal(h.guardian.isRegistered(), true); await h.close();
});
await test('query errors are unknown and do not trigger registrations', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check); h.queryError = true;
  await h.tick(); assert.equal(h.starts().length, 1);
  assert.equal(h.guardian.isRegistered(), true); await h.close();
});
await test('inactive session does not query or re-arm tasks', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check); h.alive = false; h.tasks = [];
  await h.tick(); assert.equal(h.calls.filter(x => x[0] === 'query').length, 0);
  assert.equal(h.starts().length, 1); await h.close();
});
await test('user stop suppresses timer, playback and automatic re-arm', async () => {
  const h = harness({ audioEnabled: true }); await h.guardian.engage(h.context, h.check);
  h.guardian.noteExternalCancel({ requireUserAction: true, allowAutoRearm: false,
    category: 'user-stop', summary: 'user stopped', reasonCode: 1 }); await flush();
  assert.equal(h.timers.size, 0); assert.equal(h.audio.isActive(), false);
  assert.equal(await h.guardian.rearm(h.context, true), false); await h.close();
});
await test('cancellation during pending query cannot revive a session', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check); h.tasks = [];
  const gate = deferred(); h.queryGate = gate;
  const tick = h.tick(); await flush();
  h.guardian.noteExternalCancel({ requireUserAction: true, allowAutoRearm: false,
    category: 'user-stop', summary: 'user stopped', reasonCode: 1 });
  gate.resolve(); await tick; await flush();
  assert.equal(h.starts().length, 1); assert.equal(h.guardian.isWatching(), false); await h.close();
});
await test('direct registration also respects external-stop suppression', async () => {
  const h = harness({ audioEnabled: true });
  h.guardian.noteExternalCancel({ requireUserAction: true, allowAutoRearm: false,
    category: 'user-stop', summary: 'user stopped', reasonCode: 1 });
  const result = await h.guardian.applyContinuousTask(h.context);
  assert.equal(result.ok, false); assert.equal(h.starts().length, 0);
  assert.equal(h.renderers.length, 0); await h.close();
});
await test('late task registration after disconnect is cleaned, not accepted', async () => {
  const h = harness(); const gate = deferred(); h.startGate = gate;
  const start = h.guardian.engage(h.context, h.check); await flush();
  const stop = h.guardian.release(h.context); gate.resolve(); await start; await stop;
  assert.equal(h.guardian.isRegistered(), false); assert.equal(h.tasks.length, 0); await h.close();
});
await test('late audio creation after disconnect is disposed without playback', async () => {
  const h = harness({ audioEnabled: true }); const gate = deferred(); h.sessionGate = gate;
  const start = h.guardian.engage(h.context, h.check); await flush();
  const stop = h.guardian.release(h.context); gate.resolve(); await start; await stop;
  assert.equal(h.renderers.length, 0); assert.equal(h.guardian.isRegistered(), false); await h.close();
});
await test('media interruption stops task and requires explicit reconnection', async () => {
  const h = harness({ audioEnabled: true }); await h.guardian.engage(h.context, h.check);
  h.renderers[0].handlers.get('audioInterrupt')({ hintType: 2 }); await flush();
  assert.equal(h.guardian.isRegistered(), false); assert.equal(h.guardian.isWatching(), false);
  assert.equal(h.audio.isActive(), false); assert.equal(h.guardian.isAutoEngageSuppressed(), true);
  h.guardian.clearExternalCancelSuppression();
  assert.equal(await h.guardian.engage(h.context, h.check), true); await h.close();
});
await test('system suspension is never treated as a missing task', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check);
  h.tasks[0].suspendState = true; await h.tick(); await h.tick();
  assert.equal(h.starts().length, 1); assert.equal(h.guardian.isRegistered(), false);
  h.tasks[0].suspendState = false; await h.tick(); assert.equal(h.guardian.isRegistered(), true);
  await h.close();
});
await test('failed automatic registrations have a finite three-attempt budget', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check); h.tasks = [];
  h.deny = ['taskKeeping', 'dataTransfer'];
  for (let i = 0; i < 8; i++) await h.tick();
  assert.equal(h.starts().length, 7);
  await h.guardian.engage(h.context, h.check);
  assert.equal(h.starts().length, 7, 'page sync cannot bypass the automatic retry budget');
  await h.close();
});
await test('audio tasks never publish dataTransfer progress', async () => {
  const timers = [], publications = [];
  const ctx = vm.createContext({ console, Date, setInterval: (...a) => { timers.push(a); return 1; },
    clearInterval() {}, AppLogger: { info() {}, warn() {}, errText: String },
    notificationManager: { publish: (...a) => { publications.push(a); return Promise.resolve(); } },
    TunBoxNotifier: { cancel: async () => {}, update: async () => {} } });
  const progress = load('commons/services/TaskProgressUpdater.ets', 'TaskProgressUpdater', ctx);
  progress.attach(7, 'audioPlayback'); assert.equal(timers.length, 0); assert.equal(publications.length, 0);
});
await test('page-driven retries share the same budget as watchdog retries', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check); h.tasks = [];
  await h.tick(); h.deny = ['taskKeeping', 'dataTransfer'];
  for (let i = 0; i < 5; i++) {
    h.advance(30000); await h.guardian.engage(h.context, h.check);
  }
  assert.equal(h.starts().length, 7); await h.close();
});
await test('old and malformed settings keep audio off; explicit true round-trips', async () => {
  const ctx = vm.createContext({});
  ctx.AppRoutingPolicy = load('commons/services/AppRoutingPolicy.ets', 'AppRoutingPolicy', ctx);
  ctx.LatencyTestUrl = load('commons/latency/LatencyTestUrl.ets', 'LatencyTestUrl', ctx);
  ctx.NodeSortModes = load('commons/services/NodeSortPersistence.ets', 'NodeSortModes', ctx);
  const settings = load('commons/models/AppSettings.ets', 'AppSettings', ctx);
  assert.equal(settings.fromJson({}).audioKeepAliveEnabled, false);
  assert.equal(settings.fromJson({ audioKeepAliveEnabled: 'true' }).audioKeepAliveEnabled, false);
  const value = settings.fromJson({ audioKeepAliveEnabled: true });
  assert.equal(settings.fromJson(value.toJson()).audioKeepAliveEnabled, true);
});
await test('watchdog restores dataTransfer progress after an unreported system resume', async () => {
  const h = harness({ deny: ['taskKeeping'] }); await h.guardian.engage(h.context, h.check);
  h.tasks[0].suspendState = true; await h.tick();
  h.tasks[0].suspendState = false; await h.tick();
  assert.equal(h.guardian.isRegistered(), true);
  assert.equal(h.calls.filter(x => x[0] === 'progress' && x[2] === 'dataTransfer').length, 2,
    'resumed dataTransfer must regain its progress timer');
  await h.tick();
  assert.equal(h.calls.filter(x => x[0] === 'progress' && x[2] === 'dataTransfer').length, 2,
    'healthy checks must not repeatedly reset the five-minute timer');
  await h.close();
});
await test('watchdog observes resume even when the suspend event arrived but resume event was lost', async () => {
  const h = harness({ deny: ['taskKeeping'] }); await h.guardian.engage(h.context, h.check);
  h.tasks[0].suspendState = true;
  h.guardian.noteExternalSuspend({ requireUserAction: false, category: 'general', reasonCode: 2 }, true);
  h.tasks[0].suspendState = false; await h.tick();
  assert.equal(h.guardian.isRegistered(), true); await h.close();
});
await test('confirmed generic cancellation re-arms after one backoff window', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check);
  const id = h.tasks[0].continuousTaskId; h.tasks = [];
  h.watch.dispatchCancel({ id, reason: 2 }); await h.tick();
  assert.equal(h.starts().length, 2, 'OS cancellation already confirms missing; no second 30s delay');
  await h.close();
});
await test('late cancellation and suspension from an old task cannot revoke the new task', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check);
  const oldId = h.tasks[0].continuousTaskId;
  await h.guardian.release(h.context); await h.guardian.engage(h.context, h.check);
  h.watch.dispatchCancel({ id: oldId, reason: 1 });
  h.watch.dispatchSuspend({ continuousTaskId: oldId, suspendState: true, suspendReason: 2 });
  assert.equal(h.guardian.isRegistered(), true);
  assert.equal(h.guardian.isAutoEngageSuppressed(), false);
  assert.equal(h.guardian.isWatching(), true); await h.close();
});
await test('late old-task cancellation cannot abort a pending replacement registration', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check);
  const oldId = h.tasks[0].continuousTaskId;
  await h.guardian.release(h.context);
  const gate = deferred(); h.startGate = gate;
  const pending = h.guardian.engage(h.context, h.check); await flush();
  h.watch.dispatchCancel({ id: oldId, reason: 1 });
  gate.resolve(); assert.equal(await pending, true);
  assert.equal(h.guardian.isAutoEngageSuppressed(), false); await h.close();
});
await test('generic cancellation after a suspension can still repair the missing task', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check);
  const id = h.tasks[0].continuousTaskId;
  h.guardian.noteExternalSuspend({ requireUserAction: false, category: 'general', reasonCode: 2 }, true);
  h.tasks = []; h.watch.dispatchCancel({ id, reason: 2 }); await h.tick();
  assert.equal(h.guardian.isRegistered(), true); await h.close();
});
await test('the current task user-stop event still suppresses all automatic registration', async () => {
  const h = harness({ audioEnabled: true }); await h.guardian.engage(h.context, h.check);
  h.watch.dispatchCancel({ id: h.tasks[0].continuousTaskId, reason: 1 }); await flush();
  assert.equal(h.guardian.isAutoEngageSuppressed(), true);
  assert.equal(h.guardian.isWatching(), false); assert.equal(h.audio.isActive(), false);
  assert.equal(await h.guardian.engage(h.context, h.check), false); await h.close();
});
await test('old watchdog query neither blocks nor unlocks a new session check', async () => {
  const h = harness(); await h.guardian.engage(h.context, h.check);
  const old = deferred(); h.queryGate = old;
  const first = h.guardian.checkBackgroundTask(); await flush();
  await h.guardian.release(h.context);
  await h.guardian.engage(h.context, h.check);
  const current = deferred(); h.queryGate = current;
  const second = h.guardian.checkBackgroundTask(); await flush();
  assert.equal(h.calls.filter(x => x[0] === 'query').length, 2,
    'an old query must not block the replacement watchdog');
  old.resolve(); await first;
  assert.equal(h.guardian.watchdogBusy, true, 'the old finally must not unlock the new query');
  current.resolve(); await second;
  assert.equal(h.guardian.watchdogBusy, false); await h.close();
});
console.log(`RESULT: ${passed} passed, 0 failed (platform boundaries mocked; not a device test)`);
