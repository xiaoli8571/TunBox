const fs = require('node:fs');
const p = 'entry/src/main/ets/commons/services/ConnectionOrchestrator.ets';
let t = fs.readFileSync(p, 'utf8');
// ① 记下发起下载时的会话标识
t = t.replace(`  async refreshGeoAsset(id: string, source: string): Promise<string> {
    if (this.context === null) {
      return '应用尚未初始化完成';
    }
    let ok = false;`,
`  async refreshGeoAsset(id: string, source: string): Promise<string> {
    if (this.context === null) {
      return '应用尚未初始化完成';
    }
    // 手工下载可能耗时数秒：记下发起时的会话标识，下载完成后若用户已重连/断开，
    // 迟到的结果不能改写新会话的配置（PR #5 的会话代次校验）。
    const seq = this.connectSeq;
    const generation = this.sessionGeneration;
    let ok = false;`);
// ② 应用阶段带上代次校验
t = t.replace(`    // 去广告规则集更新成功 → 热加载新规则（失败由 applyRulesChanged 内部回退重连）
    if (ok && id === 'ruleset') {
      await this.applyRulesChanged('ruleset-updated');
    }`,
`    // 去广告规则集更新成功 → 热加载新规则（失败由 applyRulesChanged 内部回退重连）
    if (ok && id === 'ruleset' && this.isRuleSessionCurrent(seq, generation)) {
      await this.applyRulesChanged('ruleset-updated');
    }`);
fs.writeFileSync(p, t);
console.log('patched:', t.includes('const seq = this.connectSeq;\n    const generation = this.sessionGeneration;\n    let ok = false;') ? 'ok' : 'check');
