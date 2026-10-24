package config

import (
	"fmt"
	"strings"

	"github.com/metacubex/mihomo/common/yaml"
	C "github.com/metacubex/mihomo/constant"
	R "github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"
)

// PrepareProfile resolves YAML aliases in the complete document before any
// sections are moved. It validates outbound definitions without applying a
// configuration, opening listeners, or initializing/downloading providers.
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
	if len(raw.Proxy) == 0 && len(raw.ProxyProvider) == 0 && len(raw.ProxyGroup) == 0 {
		return nil, fmt.Errorf("profile has no proxies, proxy-groups or proxy-providers")
	}
	if len(raw.ProxyGroup) == 0 && len(raw.Proxy) > 0 && len(raw.ProxyProvider) == 0 {
		names := make([]string, 0, len(raw.Proxy))
		for _, proxy := range raw.Proxy {
			name, ok := proxy["name"].(string)
			if !ok || name == "" {
				return nil, fmt.Errorf("proxy has no name")
			}
			names = append(names, name)
		}
		document["proxy-groups"] = []map[string]any{
			{"name": "手动选择", "type": "select", "proxies": append(append([]string{}, names...), "DIRECT")},
			{"name": "自动选择", "type": "url-test", "interval": 300, "tolerance": 50, "proxies": names},
		}
		if len(raw.Rule) == 0 {
			document["rules"] = []string{"MATCH,手动选择"}
		}
	}
	normalized, err := yaml.Marshal(document)
	if err != nil {
		return nil, err
	}
	raw, err = UnmarshalRawConfig(normalized)
	if err != nil {
		return nil, err
	}
	if len(raw.Proxy) > 2000 {
		return nil, fmt.Errorf("profile exceeds 2000 static proxies")
	}
	proxies, _, err := parseProxies(raw)
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
