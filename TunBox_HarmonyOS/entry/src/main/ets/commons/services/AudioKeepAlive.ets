import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'AudioKeepAlive';
const SAMPLE_RATE: number = 44100;
const OUTPUT_VOLUME: number = 0.03;

/** Optional continuous low-volume playback. No microphone, network or external media. */
export class AudioKeepAlive {
  private static generation: number = 0;
  private static renderer: audio.AudioRenderer | null = null;
  private static session: avSession.AVSession | null = null;
  private static pcm: Uint8Array = new Uint8Array(0);
  private static position: number = 0;

  static isActive(): boolean {
    return AudioKeepAlive.renderer !== null && AudioKeepAlive.session !== null;
  }

  static async start(context: Context, onInterrupted: () => void): Promise<boolean> {
    if (AudioKeepAlive.isActive()) {
      return true;
    }
    const generation = ++AudioKeepAlive.generation;
    let renderer: audio.AudioRenderer | null = null;
    let session: avSession.AVSession | null = null;
    let committed: boolean = false;
    try {
      session = await avSession.createAVSession(context, 'TunBoxKeepAlive', 'audio');
      if (generation !== AudioKeepAlive.generation) { return false; }
      await session.setAVMetadata({ assetId: 'tunbox-keepalive', title: 'TunBox 音频保活', artist: 'TunBox' });
      if (generation !== AudioKeepAlive.generation) { return false; }
      session.on('pause', (): void => {
        if (generation === AudioKeepAlive.generation) { onInterrupted(); }
      });
      session.on('stop', (): void => {
        if (generation === AudioKeepAlive.generation) { onInterrupted(); }
      });
      await session.activate();
      if (generation !== AudioKeepAlive.generation) { return false; }
      renderer = await audio.createAudioRenderer({
        streamInfo: {
          samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_44100,
          channels: audio.AudioChannel.CHANNEL_1,
          sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
          encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
        },
        rendererInfo: { usage: audio.StreamUsage.STREAM_USAGE_MUSIC, rendererFlags: 0 }
      });
      if (generation !== AudioKeepAlive.generation) { return false; }
      AudioKeepAlive.pcm = AudioKeepAlive.makePcm();
      AudioKeepAlive.position = 0;
      renderer.on('writeData', (data: ArrayBuffer): audio.AudioDataCallbackResult => {
        if (generation !== AudioKeepAlive.generation) {
          new Uint8Array(data).fill(0);
          return audio.AudioDataCallbackResult.INVALID;
        }
        AudioKeepAlive.fill(new Uint8Array(data));
        return audio.AudioDataCallbackResult.VALID;
      });
      renderer.on('audioInterrupt', (event: audio.InterruptEvent): void => {
        if (generation !== AudioKeepAlive.generation) { return; }
        if (event.hintType === audio.InterruptHint.INTERRUPT_HINT_PAUSE
          || event.hintType === audio.InterruptHint.INTERRUPT_HINT_STOP) {
          onInterrupted();
        }
      });
      // Set volume before starting: never emit a frame at the renderer's default volume.
      await renderer.setVolume(OUTPUT_VOLUME);
      if (generation !== AudioKeepAlive.generation) { return false; }
      await renderer.start();
      if (generation !== AudioKeepAlive.generation) { return false; }
      await session.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_PLAY });
      if (generation !== AudioKeepAlive.generation) { return false; }
      AudioKeepAlive.renderer = renderer;
      AudioKeepAlive.session = session;
      committed = true;
      AppLogger.info(TAG, 'optional playback started');
      return true;
    } catch (e) {
      AppLogger.warn(TAG, `playback unavailable: ${AppLogger.errText(e)}`);
      return false;
    } finally {
      if (!committed) {
        await AudioKeepAlive.dispose(renderer, session);
      }
    }
  }

  /** Invalidates in-flight starts synchronously, before waiting for platform cleanup. */
  static async stop(): Promise<void> {
    AudioKeepAlive.generation++;
    const renderer = AudioKeepAlive.renderer;
    const session = AudioKeepAlive.session;
    AudioKeepAlive.renderer = null;
    AudioKeepAlive.session = null;
    AudioKeepAlive.pcm = new Uint8Array(0);
    AudioKeepAlive.position = 0;
    await AudioKeepAlive.dispose(renderer, session);
  }

  private static async dispose(renderer: audio.AudioRenderer | null,
    session: avSession.AVSession | null): Promise<void> {
    if (renderer !== null) {
      try { await renderer.stop(); } catch (e) { /* May not have started. */ }
      try { await renderer.release(); } catch (e) {
        AppLogger.warn(TAG, `renderer release failed: ${AppLogger.errText(e)}`);
      }
    }
    if (session !== null) {
      try { await session.destroy(); } catch (e) {
        AppLogger.warn(TAG, `session release failed: ${AppLogger.errText(e)}`);
      }
    }
  }

  /** A one-second seamless, nonzero PCM signal generated locally; no media asset dependency. */
  private static makePcm(): Uint8Array {
    const pcm = new Uint8Array(SAMPLE_RATE * 2);
    for (let i = 0; i < SAMPLE_RATE; i++) {
      const sample = Math.round(Math.sin(2 * Math.PI * 441 * i / SAMPLE_RATE) * 1024);
      pcm[i * 2] = sample & 255;
      pcm[i * 2 + 1] = (sample >> 8) & 255;
    }
    return pcm;
  }

  private static fill(dst: Uint8Array): void {
    const pcm = AudioKeepAlive.pcm;
    if (pcm.length === 0) { dst.fill(0); return; }
    let written: number = 0;
    while (written < dst.length) {
      const count = Math.min(dst.length - written, pcm.length - AudioKeepAlive.position);
      dst.set(pcm.subarray(AudioKeepAlive.position, AudioKeepAlive.position + count), written);
      written += count;
      AudioKeepAlive.position = (AudioKeepAlive.position + count) % pcm.length;
    }
  }
}
