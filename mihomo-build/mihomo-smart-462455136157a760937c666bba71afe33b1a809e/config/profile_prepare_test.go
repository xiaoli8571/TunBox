package config

import (
	"strings"
	"testing"
)

func TestPrepareProfile(t *testing.T) {
	cases := []struct { name, text string; wantError bool }{
		{"flow", "proxies:\n - {name: A, type: socks5, server: 127.0.0.1, port: 9}\n", false},
		{"quoted", "proxies:\n - name: 'A''B'\n   type: socks5\n   server: 127.0.0.1\n   port: 9\n", false},
		{"anchor", "template: &t\n  type: socks5\n  server: 127.0.0.1\n  port: 9\nproxies:\n - name: A\n   <<: *t\n", false},
		{"invalid-protocol", "proxies:\n - {name: A, type: invalid-protocol, server: localhost, port: 9}\n", true},
		{"duplicate", "proxies:\n - {name: A, type: socks5, server: localhost, port: 9}\n - {name: A, type: socks5, server: localhost, port: 9}\n", true},
		{"missing-group-member", "proxy-groups:\n - {name: Main, type: select, proxies: [missing]}\n", true},
		{"missing-rule-target", "proxies:\n - {name: A, type: socks5, server: localhost, port: 9}\nrules:\n - MATCH,missing\n", true},
		{"provider-only", "proxy-providers:\n  airport:\n    type: http\n    url: https://example.invalid/nodes.yaml\n    interval: 3600\nproxy-groups:\n - {name: Main, type: select, use: [airport]}\nrules:\n - MATCH,Main\n", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			result, err := PrepareProfile([]byte(tc.text))
			if (err != nil) != tc.wantError { t.Fatalf("error=%v", err) }
			if err != nil { return }
			if strings.Contains(string(result), "*t") { t.Fatal("unresolved alias") }
			raw, err := UnmarshalRawConfig(result)
			if err != nil || len(raw.ProxyGroup) == 0 || len(raw.Rule) == 0 { t.Fatalf("missing routing: %s (%v)", result, err) }
		})
	}
}
