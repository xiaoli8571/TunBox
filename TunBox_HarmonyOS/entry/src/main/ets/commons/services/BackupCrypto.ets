/**
 * 备份加密引擎（P0-4）—— AES-256-GCM + PBKDF2 密钥派生
 *
 * 加密备份 JSON 契约：
 * {
 *   app: 'TunBox-Encrypted',
 *   version: '1',
 *   kdf: { name: 'PBKDF2-SHA256', iterations: 100000, salt: <base64> },
 *   cipher: { name: 'AES-256-GCM', iv: <base64> },
 *   ciphertext: <base64>   // 明文 JSON（BackupFile 结构）加密后的字节
 * }
 * - 导出带密码 → 加密封装；不带密码 → 维持原明文格式（旧版兼容）
 * - 导入先探测 app 字段：TunBox-Encrypted → 请求密码解密；其余走明文路径
 * - base64 用 @kit.CryptoArchitectureKit 的 cryptoFramework DataBlob + util Base64Helper
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { taskpool, util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'BackupCrypto';
export const ENCRYPTED_APP = 'TunBox-Encrypted';
const KDF_ITERATIONS = 100000;
const KEY_BITS = 256;
const IV_BYTES = 12;
const SALT_BYTES = 16;
const TAG_BYTES = 16;

export class EncryptedBackupEnvelope {
  app: string = ENCRYPTED_APP;
  version: string = '1';
  kdf: KdfParams = new KdfParams();
  cipher: CipherParams = new CipherParams();
  ciphertext: string = '';
}

class KdfParams {
  name: string = 'PBKDF2-SHA256';
  iterations: number = KDF_ITERATIONS;
  salt: string = '';
}

class CipherParams {
  name: string = 'AES-256-GCM';
  iv: string = '';
}

export class BackupCryptoResult {
  ok: boolean = false;
  /** 加密成功时为封装 JSON；解密成功时为明文 JSON */
  text: string = '';
  message: string = '';
}

/**
 * Worker payload: self-contained for ArkTS @Concurrent execution across taskpool threads.
 * Uses GCM authTag concatenation [ciphertext || 16-byte tag] so the JSON envelope schema stays v1-compatible.
 */
@Concurrent
export function runBackupEncryptWorker(plainJson: string, password: string): string {
  const kdfIterations = 100000;
  const keyBytesLen = 32;
  const ivBytesLen = 12;
  const saltBytesLen = 16;
  const tagBytesLen = 16;
  const pack = (ok: boolean, text: string, msg: string, err: string): string =>
    `{"ok":${ok},"text":${JSON.stringify(text)},"message":${JSON.stringify(msg)},"err":${JSON.stringify(err)}}`;
  if (password.length < 4) {
    return pack(false, '', '密码至少 4 个字符', '');
  }
  try {
    const rand = cryptoFramework.createRandom();
    const salt = new Uint8Array(rand.generateRandomSync(saltBytesLen).data);
    const iv = new Uint8Array(rand.generateRandomSync(ivBytesLen).data);
    const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: salt,
      iterations: kdfIterations,
      keySize: keyBytesLen
    };
    const keyBytes = new Uint8Array(kdf.generateSecretSync(spec).data);
    const symKey = cryptoFramework.createSymKeyGenerator('AES256').convertKeySync({ data: keyBytes });
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: new Uint8Array(tagBytesLen) }
    };
    cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);
    const plainBytes = util.TextEncoder.create('utf-8').encodeInto(plainJson);
    const updateOut = plainBytes.length > 0 ? cipher.updateSync({ data: plainBytes }) : null;
    const tagOut = cipher.doFinalSync(null);
    const cipherPart = updateOut !== null && updateOut !== undefined ? new Uint8Array(updateOut.data) : new Uint8Array(0);
    const tagPart = tagOut !== null && tagOut !== undefined ? new Uint8Array(tagOut.data) : new Uint8Array(0);
    if (tagPart.length !== tagBytesLen) {
      return pack(false, '', '加密失败，请重试', `unexpected GCM auth tag length: ${tagPart.length}`);
    }
    const cipherBytes = new Uint8Array(cipherPart.length + tagPart.length);
    cipherBytes.set(cipherPart, 0);
    cipherBytes.set(tagPart, cipherPart.length);
    const base64 = new util.Base64Helper();
    const saltB64 = base64.encodeToStringSync(salt);
    const ivB64 = base64.encodeToStringSync(iv);
    const cipherB64 = base64.encodeToStringSync(cipherBytes);
    const envelope = `{\n`
      + `  "app": "TunBox-Encrypted",\n`
      + `  "version": "1",\n`
      + `  "kdf": {\n`
      + `    "name": "PBKDF2-SHA256",\n`
      + `    "iterations": ${kdfIterations},\n`
      + `    "salt": ${JSON.stringify(saltB64)}\n`
      + `  },\n`
      + `  "cipher": {\n`
      + `    "name": "AES-256-GCM",\n`
      + `    "iv": ${JSON.stringify(ivB64)}\n`
      + `  },\n`
      + `  "ciphertext": ${JSON.stringify(cipherB64)}\n`
      + `}`;
    return pack(true, envelope, '', '');
  } catch (e) {
    return pack(false, '', '加密失败，请重试', String(e));
  }
}

@Concurrent
export function runBackupDecryptWorker(envelopeJson: string, password: string): string {
  const defaultIterations = 100000;
  const keyBytesLen = 32;
  const tagBytesLen = 16;
  const pack = (ok: boolean, text: string, msg: string, err: string): string =>
    `{"ok":${ok},"text":${JSON.stringify(text)},"message":${JSON.stringify(msg)},"err":${JSON.stringify(err)}}`;
  try {
    const parsed = JSON.parse(envelopeJson) as Record<string, Object>;
    const app = parsed['app'];
    const ciphertextB64 = parsed['ciphertext'];
    if (app !== 'TunBox-Encrypted' || typeof ciphertextB64 !== 'string' || ciphertextB64.length === 0) {
      return pack(false, '', '不是合法的加密备份文件', '');
    }
    const kdfObj = parsed['kdf'] as Record<string, Object> | undefined;
    const cipherObj = parsed['cipher'] as Record<string, Object> | undefined;
    const rawIter = kdfObj !== undefined && kdfObj !== null ? kdfObj['iterations'] : undefined;
    const iterations = typeof rawIter === 'number' && rawIter >= 1000 ? rawIter : defaultIterations;
    const saltB64 = kdfObj !== undefined && kdfObj !== null ? kdfObj['salt'] : undefined;
    const ivB64 = cipherObj !== undefined && cipherObj !== null ? cipherObj['iv'] : undefined;
    if (typeof saltB64 !== 'string' || typeof ivB64 !== 'string') {
      return pack(false, '', '加密备份缺少密钥参数，文件已损坏', '');
    }
    const base64 = new util.Base64Helper();
    const salt = base64.decodeSync(saltB64);
    const iv = base64.decodeSync(ivB64);
    const cipherBytes = base64.decodeSync(ciphertextB64);
    if (salt.length === 0 || iv.length === 0 || cipherBytes.length < tagBytesLen) {
      return pack(false, '', '加密备份缺少密钥参数，文件已损坏', '');
    }
    const body = cipherBytes.slice(0, cipherBytes.length - tagBytesLen);
    const tag = cipherBytes.slice(cipherBytes.length - tagBytesLen);
    const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
    const spec: cryptoFramework.PBKDF2Spec = {
      algName: 'PBKDF2',
      password: password,
      salt: salt,
      iterations: iterations,
      keySize: keyBytesLen
    };
    const keyBytes = new Uint8Array(kdf.generateSecretSync(spec).data);
    const symKey = cryptoFramework.createSymKeyGenerator('AES256').convertKeySync({ data: keyBytes });
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const gcmParams: cryptoFramework.GcmParamsSpec = {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: tag }
    };
    cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);
    const part1 = body.length > 0 ? cipher.updateSync({ data: body }) : null;
    const part2 = cipher.doFinalSync(null);
    const b1 = part1 !== null && part1 !== undefined ? new Uint8Array(part1.data) : new Uint8Array(0);
    const b2 = part2 !== null && part2 !== undefined ? new Uint8Array(part2.data) : new Uint8Array(0);
    const plainBytes = new Uint8Array(b1.length + b2.length);
    plainBytes.set(b1, 0);
    plainBytes.set(b2, b1.length);
    const plainText = util.TextDecoder.create('utf-8').decodeToString(plainBytes);
    return pack(true, plainText, '', '');
  } catch (e) {
    return pack(false, '', '解密失败：密码错误或文件已损坏', String(e));
  }
}

function parseWorkerOutcome(raw: string, actionLabel: string): BackupCryptoResult {
  const out = new BackupCryptoResult();
  try {
    const obj = JSON.parse(raw) as Record<string, Object>;
    out.ok = obj['ok'] === true;
    out.text = typeof obj['text'] === 'string' ? obj['text'] as string : '';
    out.message = typeof obj['message'] === 'string' ? obj['message'] as string : '';
    const err = typeof obj['err'] === 'string' ? obj['err'] as string : '';
    if (!out.ok && err.length > 0) {
      AppLogger.warn(TAG, `backup ${actionLabel} failed: ${err}`);
    }
  } catch (e) {
    AppLogger.error(TAG, `backup ${actionLabel} reply invalid: ${AppLogger.errText(e)}`);
    out.message = `${actionLabel}失败，请重试`;
  }
  return out;
}

export class BackupCrypto {
  /** 用密码加密备份明文 JSON → 封装 JSON 字符串 */
  static encrypt(plainJson: string, password: string): BackupCryptoResult {
    return parseWorkerOutcome(runBackupEncryptWorker(plainJson, password), 'encrypt');
  }

  /** 在后台任务池中执行 PBKDF2 + AES-256-GCM 加密，避免阻塞 UI 线程。 */
  static async encryptAsync(plainJson: string, password: string): Promise<BackupCryptoResult> {
    try {
      const raw = await taskpool.execute(runBackupEncryptWorker, plainJson, password) as string;
      return parseWorkerOutcome(raw, 'encrypt');
    } catch (e) {
      AppLogger.warn(TAG, `taskpool encrypt fallback to sync: ${AppLogger.errText(e)}`);
      return BackupCrypto.encrypt(plainJson, password);
    }
  }

  /** 判断备份文本是否为加密封装 */
  static isEncrypted(text: string): boolean {
    try {
      const parsed = JSON.parse(text) as Object;
      const app = (parsed as Record<string, Object>)['app'];
      return typeof app === 'string' && app === ENCRYPTED_APP;
    } catch (e) {
      return false;
    }
  }

  /** 用密码解密封装 JSON → 明文 JSON 字符串 */
  static decrypt(envelopeJson: string, password: string): BackupCryptoResult {
    return parseWorkerOutcome(runBackupDecryptWorker(envelopeJson, password), 'decrypt');
  }

  /** 在后台任务池中执行 PBKDF2 + AES-256-GCM 解密，避免阻塞 UI 线程。 */
  static async decryptAsync(envelopeJson: string, password: string): Promise<BackupCryptoResult> {
    try {
      const raw = await taskpool.execute(runBackupDecryptWorker, envelopeJson, password) as string;
      return parseWorkerOutcome(raw, 'decrypt');
    } catch (e) {
      AppLogger.warn(TAG, `taskpool decrypt fallback to sync: ${AppLogger.errText(e)}`);
      return BackupCrypto.decrypt(envelopeJson, password);
    }
  }
}
