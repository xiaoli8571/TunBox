import { hidebug } from '@kit.PerformanceAnalysisKit';

/** getPss may be expensive; never run it on the extension's heartbeat thread. */
@Concurrent
export function sampleProcessPss(): number {
  return Number(hidebug.getPss());
}
