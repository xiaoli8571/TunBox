#!/usr/bin/env node
/**
 * 备份自包含闸门（0.6.7 后修复）
 *
 * 背景（2026-10-26 真机反馈）：备份只导出订阅元数据 / 节点表 / settings，
 * 不含 `profiles/<subId>.yaml`（内核真正的节点来源）与 Asset 里的订阅 header 凭据。
 * 卸载重装后导入备份：订阅列表在、节点表在，但内核没有 profile、没有密码，
 * 表现就是「选不了节点 / 刷新不出来 / 启动代理失败」。同版本恢复也会因为
 * current profile 未写回而落在空目录上。
 *
 * 本闸门只做 SOURCE 断言（不构建、不跑真机），守住四个不变量：
 *   1. 备份版本 >= 2.1，且 BackupFile 带 profiles / subscriptionSecrets / currentProfileId；
 *   2. 导出（exportJsonWithSettings）必须采集 profile 原文、订阅凭据与 current；
 *   3. 导入必须写回 profile、切回 current、补订阅凭据，并给旧备份排队后台补拉；
 *   4. 恢复不从备份覆盖本机代理模式（否则装完就是「全局模式」）。
 *
 * 跑法：node scripts/verify-backup-self-contained.mjs
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const ets = path.join(here, '..', 'entry', 'src', 'main', 'ets');
const read = (rel) => fs.readFileSync(path.join(ets, rel), 'utf8').replace(/\r\n/g, '\n');

const backup = read('commons/services/BackupRestoreService.ets');
// 2026-10-27：备份 UI 从 HomePage 迁到独立 BackupPage（设置 → 关于与隐私入口）。
const home = read('pages/BackupPage.ets');

let passed = 0;
const failures = [];
const ok = (cond, label) => {
  if (cond) {
    passed += 1;
    return;
  }
  failures.push(label);
};

// 1. 契约字段
ok(/BACKUP_VERSION\s*=\s*'2\.1'/.test(backup), 'BACKUP_VERSION 必须是 2.1（自包含备份）');
for (const field of ['profiles: ProfileBackupEntry[]', 'subscriptionSecrets: SubscriptionSecretEntry[]',
  'currentProfileId: string']) {
  ok(backup.includes(field), `BackupFile 缺少字段 ${field}`);
}

// 2. 导出必须采集 profile / 凭据 / current
const exportFn = backup.slice(backup.indexOf('static async exportJsonWithSettings'),
  backup.indexOf('private static collectProfiles'));
ok(exportFn.length > 0, 'exportJsonWithSettings 必须是 async 且存在');
ok(/file\.profiles\s*=\s*BackupRestoreService\.collectProfiles\(/.test(exportFn),
  '导出必须采集 profiles（内核节点来源）');
ok(/file\.subscriptionSecrets\s*=\s*await\s+BackupRestoreService\.collectSubscriptionSecrets\(/.test(exportFn),
  '导出必须采集订阅 header 凭据');
ok(/file\.currentProfileId\s*=\s*ProfileRepository\.isReady\(\)\s*\?\s*ProfileRepository\.currentId\(\)/.test(exportFn),
  '导出必须记录 current profile');
ok(/ProfileRepository\.read\(s\.id\)/.test(backup) && /CredentialStore\.subscriptionCredential\(/.test(backup),
  '采集实现必须真读 ProfileRepository / CredentialStore');
ok(/await\s+BackupRestoreService\.exportJsonWithSettings\(/.test(home),
  'BackupPage 导出必须 await 异步导出');

// 3. 导入必须写回 profile / current / 凭据，并给旧备份补拉
ok(/restoreProfiles\(parsed, subIds, restoredSubs\)/.test(backup),
  '导入必须调用 restoreProfiles 写回 profile 原文与 current');
ok(/ProfileRepository\.write\(id, yaml\)/.test(backup), 'restoreProfiles 必须写入 profiles/<id>.yaml');
ok(/await ProfileRepository\.setCurrent\(current\)/.test(backup), 'restoreProfiles 必须切回 current profile');
ok(/CredentialStore\.canonicalize\(\[\], sources, true\)/.test(backup),
  'restoreProfiles 必须把订阅 header 凭据补进 Asset');
ok(/needRefresh\.push\(s\.id\)/.test(backup) && /await svc\.refreshSubscription\(id\)/.test(backup),
  '旧备份（无 profiles）必须给缺原文的订阅排队后台补拉');

// 4. 代理模式不被备份覆盖（否则装完即全局模式）
const settingsBlock = backup.slice(backup.indexOf('// 6. 恢复 settings 全量'),
  backup.indexOf('out.ok = true;'));
ok(/const live = await SettingsService\.load\(\);/.test(settingsBlock),
  '恢复 settings 前必须读取本机当前设置');
ok(/settings\.proxyMode = live\.proxyMode;/.test(settingsBlock),
  '恢复后必须保留本机代理模式，不能用备份里的 global 覆盖');

if (failures.length > 0) {
  console.error('\n备份自包含闸门：FAIL');
  for (const f of failures) {
    console.error('  ❌ ' + f);
  }
  process.exit(1);
}
console.log(`备份自包含闸门：PASS（${passed} 项断言，SOURCE）`);
