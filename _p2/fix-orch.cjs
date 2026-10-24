const fs = require('node:fs');
const p = 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets';
let t = fs.readFileSync(p, 'utf8');
// ① 后台补下载：改调本地已有的单一入口（PR 用 task 单航班实现，本地只保留它）
t = t.replace(
  "        this.downloadRuleProviderInBackground('auto');",
  "        this.downloadRuleProviderAsset('auto').catch((e: Object): void => {\n"
  + "          AppLogger.warn(TAG, `hyper-adrules background download error: ${e}`);\n"
  + "        });");
// ② performRuleProviderDownload 里残留的旧标志位
t = t.replace(`      return await this.downloadAsset(HYPER_AD_RULES_MIRRORS, dest, RULE_SET_MIN_BYTES - 1,
        (buf: ArrayBuffer): boolean => buf.byteLength >= RULE_SET_MIN_BYTES
          && ConnectionOrchestrator.bufferMagicOk(buf, ZSTD_MAGIC),
        source, 'hyper-adrules');
    } finally {
      this.ruleProviderDownloading = false;
    }`,
`      return await this.downloadAsset(HYPER_AD_RULES_MIRRORS, dest, RULE_SET_MIN_BYTES - 1,
        (buf: ArrayBuffer): boolean => buf.byteLength >= RULE_SET_MIN_BYTES
          && ConnectionOrchestrator.bufferMagicOk(buf, ZSTD_MAGIC),
        source, 'hyper-adrules');
    } catch (e) {
      AppLogger.warn(TAG, \`hyper-adrules download failed: \${AppLogger.errText(e)}\`);
      return false;
    }`);
fs.writeFileSync(p, t);
console.log('patched; leftovers =', ['downloadRuleProviderInBackground', 'ruleProviderDownloading'].map(k => k + '=' + (t.includes(k) ? 'YES' : 'no')).join(' '));
