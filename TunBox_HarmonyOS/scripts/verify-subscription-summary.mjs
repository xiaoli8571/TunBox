#!/usr/bin/env node
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
const root = new URL('../', import.meta.url);
const source = fs.readFileSync(new URL('entry/src/main/ets/commons/utils/SubscriptionSummary.ets', root), 'utf8');
const js = stripTypeScriptTypes(source, { mode: 'transform' });
const { SubscriptionSummary: S } = await import(`data:text/javascript;base64,${Buffer.from(js).toString('base64')}`);
const now = Date.UTC(2026, 9, 27, 10);
const G = 1024 ** 3;
const cases = [
  [S.traffic(G, 9 * G, 100 * G), '10G/100G'],
  [S.traffic(-1, 9 * G, 100 * G), '--/100G'],
  [S.traffic(G, -1, 100 * G), '--/100G'],
  [S.traffic(-1, -1, -1), '--/--'],
  [S.traffic(0, 0, 0), '0B/0B'],
  [S.traffic(NaN, 0, Infinity), '--/--'],
  [S.traffic(0, 1.5 * G, -1), '1.5G/--'],
  [S.bytes(1024), '1K'], [S.bytes(1024 ** 4), '1T'],
  [S.updateTime(0, now), '未更新'], [S.updateTime(NaN, now), '未更新'],
  [S.updateTime(now + 60000, now), '刚刚'],
  [S.updateTime(now - 59999, now), '刚刚'],
  [S.updateTime(now - 60000, now), '1分钟前'],
  [S.updateTime(now - 59 * 60000, now), '59分钟前'],
  [S.updateTime(now - 3600000, now), '1小时前'],
  [S.updateTime(now - 86400000, now), '1天前']
];
for (const [actual, expected] of cases) assert.equal(actual, expected);
const page = fs.readFileSync(new URL('entry/src/main/ets/pages/SubscriptionPage.ets', root), 'utf8');
assert.ok(page.includes('SubscriptionSummary.traffic(sub.uploadBytes, sub.downloadBytes, sub.totalBytes)'));
assert.ok(page.includes('${this.trafficSummaryOf(sub)}'));
console.log(`PASS subscription summary: ${cases.length} behavior cases + 2 UI wiring checks`);
