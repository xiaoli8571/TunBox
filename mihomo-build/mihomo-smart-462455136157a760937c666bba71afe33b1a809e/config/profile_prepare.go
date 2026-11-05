package config

import (
	"fmt"
	"strings"

	"github.com/metacubex/mihomo/common/yaml"
	C "github.com/metacubex/mihomo/constant"
	R "github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"
)

// PrepareProfile resolves YAML aliases in the complete document and validates
// outbound/provider/rule references without applying a configuration, opening
// listeners, or initializing/downloading providers.
//
// 2026-11-05（FlClash 全量照抄）：**合成组注入已删除**。此前本函数会在 profile
// 只有 proxies 没有 proxy-groups 时就地补「手动选择/自动选择 + MATCH,手动选择」
// —— 那是 App 自造的节点准入推断。FlClash 对这类 profile 的处理就是原样交给
// mihomo（GLOBAL 组兜底、无规则时按内核自身语义路由），App 不补组、不改名、
// 不推断。profile 文件存原文（不再经本函数归一化后落盘），本函数只剩
// 「锚点展开 + 校验」一个职责，供 App 侧预览解析继续使用。
func PrepareProfile(content []byte) ([]byte, error) {
	if len(content) == 0 || len(content) > 8*1024*1024 {
		return nil, fmt.Errorf("profile size out of range")
	}
	var document map[string]any
	if err := yaml.Unmarshal(content, &document); err != nil {
		return nil, err
	}
	raw, err := UnmarshalRawConfig(content)
	if err != nil {
		return nil, err
	}
	normalized, err := yaml.Marshal(document)
	if err != nil {
		return nil, err
	}
	raw, err = UnmarshalRawConfig(normalized)
	if err != nil {
		return nil, err
	}
	proxies, _, err := parseProxiesWithMode(raw, true)
	if err != nil {
		return nil, err
	}
	if _, err := parseRuleProviders(raw); err != nil {
		return nil, err
	}
	// Check policy/provider references without loading GeoIP/GeoSite assets.
	checkRules := func(rules []string) error {
		for _, rule := range rules {
			kind, payload, target, params := RC.ParseRulePayload(rule, true)
			if target == "" {
				return fmt.Errorf("invalid rule: %s", rule)
			}
			// Geo datasets are intentionally not loaded during import. Other
			// rule syntax is checked by the same parser used at runtime.
			geoDependent := strings.Contains(rule, "GEOIP,") || strings.Contains(rule, "GEOSITE,") || strings.Contains(rule, "IP-ASN,")
			if !geoDependent {
				subRules := make(map[string][]C.Rule)
				for name := range raw.SubRules {
					subRules[name] = nil
				}
				parsed, err := R.ParseRule(kind, payload, target, params, subRules)
				if err != nil {
					return err
				}
				for _, name := range parsed.ProviderNames() {
					if _, ok := raw.RuleProvider[name]; !ok {
						return fmt.Errorf("rule provider %s not found", name)
					}
				}
			} else if payload == "" {
				return fmt.Errorf("missing geo rule payload")
			}
			if kind == "SUB-RULE" {
				if _, ok := raw.SubRules[target]; !ok {
					return fmt.Errorf("sub-rule %s not found", target)
				}
			} else if _, ok := proxies[target]; !ok {
				return fmt.Errorf("rule proxy %s not found", target)
			}
		}
		return nil
	}
	if err := checkRules(raw.Rule); err != nil {
		return nil, err
	}
	for _, rules := range raw.SubRules {
		if err := checkRules(rules); err != nil {
			return nil, err
		}
	}
	return normalized, nil
}
