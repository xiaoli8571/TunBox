import { fileIo as fs } from '@kit.CoreFileKit';
import { taskpool, util } from '@kit.ArkTS';
import deviceInfo from '@ohos.deviceInfo';
import { AppLogger, LogRedactor } from '../utils/AppLogger';
import { AppInfo } from '../utils/AppInfo';
import { PersistentLogStore } from './PersistentLogStore';

/** Only an explicit allowlist: never export YAML, preference stores or node credentials. */
@Concurrent
export function writeDiagnosticReport(filesDir: string, cacheDir: string, uri: string, header: string): number {
  const output = fs.openSync(uri, fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
  let collected = 0;
  try {
    const write = (value: string): void => {
      const bytes = new util.TextEncoder().encodeInto(value);
      if (fs.writeSync(output.fd, bytes.buffer) !== bytes.byteLength) { throw new Error('Incomplete diagnostic write'); }
    };
    write(LogRedactor.redact(header));
    const logs: string[] = [];
    for (const role of ['app', 'vpn', 'quick', 'work']) {
      for (const suffix of ['.2', '.1', '']) { logs.push(`diagnostics/${role}.log${suffix}`); }
    }
    logs.push('diagnostics/memory-pressure.json');
    const runtime: string[] = ['core.log.3', 'core.log.2', 'core.log.1', 'core.log',
      'core_resources.jsonl.2', 'core_resources.jsonl.1', 'core_resources.jsonl', 'core_resources.json',
      'vpn_mem.json', 'vpn_status.json', 'vpn_heartbeat.txt', 'vpn_start_error.txt', 'vpn_launch_epoch.txt'];
    for (let i = 0; i < logs.length + runtime.length; i++) {
      const isLog = i < logs.length;
      const name = isLog ? logs[i] : runtime[i - logs.length];
      const path = `${isLog ? filesDir : cacheDir}/${name}`;
      let section: string;
      try {
        const size = Number(fs.statSync(path).size);
        const limit = 2 * 1024 * 1024;
        const offset = Math.max(0, size - limit);
        let content = size > 0 ? fs.readTextSync(path, { offset: offset, length: Math.min(size, limit) }) : '';
        // Discard a cut first record, including any cut credential. Never export partial prefix.
        if (offset > 0) {
          const newline = content.indexOf('\n');
          content = newline >= 0 ? content.substring(newline + 1) : '[oversized single record omitted]';
        }
        section = `\n\n===== ${name} (${size} bytes${offset > 0 ? ', tail truncated' : ''}) =====\n`
          + LogRedactor.redact(content);
        collected++;
      } catch (e) {
        section = `\n\n===== ${name}: unavailable =====\n${LogRedactor.redact(String(e))}`;
      }
      // Source errors are isolated; destination errors must fail the whole export.
      write(section);
    }
    write(`\n\nEND collectedSources=${collected}\n`);
  } finally { fs.closeSync(output); }
  return collected;
}

export class DiagnosticExportService {
  static async export(context: Context, uri: string, state: string): Promise<number> {
    PersistentLogStore.flush();
    const header = `TunBox diagnostics v1\nversion=${AppInfo.version()}\ncollectedAt=${new Date().toISOString()}\n`
      + `deviceType=${deviceInfo.deviceType}\nmodel=${deviceInfo.productModel}\nos=${deviceInfo.osFullName}\n`
      + `sdk=${deviceInfo.sdkApiVersion}\nstate=${state}\n`
      + 'Memory display: VPN process PSS+SwapPss in KiB, fresh within 15s. Core RSS and Go heap are separate metrics.\n'
      + 'Coverage: bounded app/VPN process logs, native core stdout/stderr, resource history and runtime markers.\n'
      + 'System-wide hilog and privileged crash dumps are not accessible to a normal application. Missing sources are listed.\n'
      + 'Privacy: no configuration YAML, subscription database or preferences; URLs/credentials/IPs are redacted.\n'
      + 'Please review this report before sharing; arbitrary log content may still identify your network.\n\n'
      + `===== current UI log ring =====\n${AppLogger.dump().join('\n')}\n`;
    return await taskpool.execute(writeDiagnosticReport, context.filesDir, context.cacheDir, uri, header) as number;
  }
}
