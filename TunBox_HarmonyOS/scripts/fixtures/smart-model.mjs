// Real-kernel tests may use an explicitly supplied model, never a packaged asset.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
export function smartModelFixture() {
  const file = process.env.TUNBOX_SMART_MODEL_FIXTURE || path.join(
    process.env.LOCALAPPDATA || path.join(os.homedir(), '.local', 'share'), 'TunBoxTestAssets', 'Model.bin');
  if (!fs.existsSync(file) || fs.statSync(file).size < 1024 * 1024) {
    throw Error('Real-kernel Smart tests require TUNBOX_SMART_MODEL_FIXTURE pointing to a valid local Model.bin; do not bundle it in rawfile.');
  }
  return file;
}
