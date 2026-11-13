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
import { util } from '@kit.ArkTS';
import { AppLogger } from '../utils/AppLogger';

const TAG = 'BackupCrypto';
export const ENCRYPTED_APP = 'TunBox-Encrypted';
const KDF_ITERATIONS = 100000;
const KEY_BITS = 256;
const IV_BYTES = 12;
const SALT_BYTES = 16;

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

function toBase64(bytes: Uint8Array): string {
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(bytes);
}

function fromBase64(text: string): Uint8Array {
  const helper = new util.Base64Helper();
  return helper.decodeSync(text);
}

// concatBytes：AAD 扩展预留，当前未消费
function concatBytes(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}
void concatBytes;

export class BackupCrypto {
  /** 用密码加密备份明文 JSON → 封装 JSON 字符串 */
  static encrypt(plainJson: string, password: string): BackupCryptoResult {
    const out = new BackupCryptoResult();
    if (password.length < 4) {
      out.message = '密码至少 4 个字符';
      return out;
    }
    try {
      const rand = cryptoFramework.createRandom();
      const saltBlob = rand.generateRandomSync(SALT_BYTES);
      const ivBlob = rand.generateRandomSync(IV_BYTES);
      const salt = new Uint8Array(saltBlob.data);
      const iv = new Uint8Array(ivBlob.data);
      // PBKDF2 派生 256 位密钥
      const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
      const spec: cryptoFramework.PBKDF2Spec = {
        algName: 'PBKDF2',
        password: password,
        salt: salt,
        iterations: KDF_ITERATIONS,
        keySize: KEY_BITS / 8
      };
      const secretBlob = kdf.generateSecretSync(spec);
      const keyBytes = new Uint8Array(secretBlob.data);
      const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
      const symKey = cryptoFramework.createSymKeyGenerator('AES256').convertKeySync(keyBlob);
      const cipher = cryptoFramework.createCipher('AES256|GCM|NO_padding');
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        algName: 'AESGCM',
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: new Uint8Array(16) }
      };
      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams);
      const plainBlob: cryptoFramework.DataBlob = {
        data: util.TextEncoder.create('utf-8').encodeInto(plainJson)
      };
      const encrypted = cipher.doFinalSync(plainBlob);
      // GCM 密文末尾 16 字节是 authTag，HarmonyOS doFinal 输出已含 tag
      const cipherBytes = new Uint8Array(encrypted.data);
      const envelope = new EncryptedBackupEnvelope();
      envelope.kdf.salt = toBase64(salt);
      envelope.cipher.iv = toBase64(iv);
      envelope.ciphertext = toBase64(cipherBytes);
      out.ok = true;
      out.text = JSON.stringify(envelope, null, 2);
      return out;
    } catch (e) {
      AppLogger.error(TAG, `backup encrypt failed: ${AppLogger.errText(e)}`);
      out.message = '加密失败，请重试';
      return out;
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
    const out = new BackupCryptoResult();
    try {
      const parsed = JSON.parse(envelopeJson) as EncryptedBackupEnvelope;
      if (parsed.app !== ENCRYPTED_APP || typeof parsed.ciphertext !== 'string' || parsed.ciphertext.length === 0) {
        out.message = '不是合法的加密备份文件';
        return out;
      }
      const iterations = typeof parsed.kdf?.iterations === 'number' && parsed.kdf.iterations >= 1000
        ? parsed.kdf.iterations : KDF_ITERATIONS;
      const salt = fromBase64(parsed.kdf.salt);
      const iv = fromBase64(parsed.cipher.iv);
      const cipherBytes = fromBase64(parsed.ciphertext);
      if (salt.length === 0 || iv.length === 0) {
        out.message = '加密备份缺少密钥参数，文件已损坏';
        return out;
      }
      const kdf = cryptoFramework.createKdf('PBKDF2|SHA256');
      const spec: cryptoFramework.PBKDF2Spec = {
        algName: 'PBKDF2',
        password: password,
        salt: salt,
        iterations: iterations,
        keySize: KEY_BITS / 8
      };
      const keyBytes = new Uint8Array(kdf.generateSecretSync(spec).data);
      const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
      const symKey = cryptoFramework.createSymKeyGenerator('AES256').convertKeySync(keyBlob);
      const cipher = cryptoFramework.createCipher('AES256|GCM|NO_padding');
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        algName: 'AESGCM',
        iv: { data: iv },
        aad: { data: new Uint8Array(0) },
        authTag: { data: new Uint8Array(16) }
      };
      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams);
      const decrypted = cipher.doFinalSync({ data: cipherBytes });
      out.ok = true;
      out.text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(decrypted.data));
      return out;
    } catch (e) {
      AppLogger.warn(TAG, `backup decrypt failed: ${AppLogger.errText(e)}`);
      out.message = '解密失败：密码错误或文件已损坏';
      return out;
    }
  }
}
