import { fileIo as fs } from '@kit.CoreFileKit';
import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { AppLogger } from '../utils/AppLogger';

/** Separate per-process files; bounded buffers and rotation survive UI restarts. */
export class PersistentLogStore {
  private static path: string = '';
  private static pending: string = '';
  private static timer: number = -1;

  static init(context: Context, role: string): void {
    if (PersistentLogStore.path.length > 0) { return; }
    try {
      const dir = `${context.filesDir}/diagnostics`;
      try { fs.mkdirSync(dir); } catch (_e) { /* already exists */ }
      PersistentLogStore.path = `${dir}/${role}.log`;
      AppLogger.installFileSink((line: string): void => PersistentLogStore.append(line));
      for (const line of AppLogger.dump()) { PersistentLogStore.append(line); }
      try {
        hiAppEvent.addWatcher({
          name: `TunBoxDiagnostics${role}`,
          appEventFilters: [{ domain: hiAppEvent.domain.OS,
            names: [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE] }],
          onReceive: (domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
            for (const group of groups) {
              for (const event of group.appEventInfos) {
                AppLogger.error('SystemAppEvent', `${domain} ${group.name} ${JSON.stringify(event)}`);
              }
            }
            PersistentLogStore.flush();
          }
        });
      } catch (e) {
        AppLogger.warn('Diagnostics', `crash/freeze event subscription unavailable: ${AppLogger.errText(e)}`);
      }
    } catch (_e) { /* hilog and memory ring remain available */ }
  }

  private static append(line: string): void {
    if (PersistentLogStore.pending.length + line.length > 16384) { PersistentLogStore.flush(); }
    PersistentLogStore.pending += `${line}\n`;
    if (PersistentLogStore.timer < 0) {
      PersistentLogStore.timer = setTimeout((): void => PersistentLogStore.flush(), 1000);
    }
  }

  static flush(): void {
    if (PersistentLogStore.timer >= 0) { clearTimeout(PersistentLogStore.timer); PersistentLogStore.timer = -1; }
    const data = PersistentLogStore.pending;
    PersistentLogStore.pending = '';
    if (data.length === 0 || PersistentLogStore.path.length === 0) { return; }
    try {
      const path = PersistentLogStore.path;
      let size = 0;
      try { size = Number(fs.statSync(path).size); } catch (_e) { /* new file */ }
      if (size + data.length * 4 > 1024 * 1024) {
        try { fs.unlinkSync(`${path}.2`); } catch (_e) { /* absent */ }
        try { fs.renameSync(`${path}.1`, `${path}.2`); } catch (_e) { /* absent */ }
        fs.renameSync(path, `${path}.1`);
      }
      const f = fs.openSync(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try { fs.writeSync(f.fd, data); } finally { fs.closeSync(f); }
    } catch (_e) { /* bounded best-effort logging; never recurse into AppLogger */ }
  }
}
