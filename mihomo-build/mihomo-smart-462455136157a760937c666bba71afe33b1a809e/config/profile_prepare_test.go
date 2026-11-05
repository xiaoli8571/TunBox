package config

import (
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

func TestPrepareProfileLargeSubscription(t *testing.T) {
	var source strings.Builder
	source.WriteString("proxies:\n")
	for i := 0; i < 2001; i++ {
		fmt.Fprintf(&source, "  - {name: node-%d, type: socks5, server: 127.0.0.1, port: 9}\n", i)
	}
	result, err := PrepareProfile([]byte(source.String()))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := UnmarshalRawConfig(result)
	if err != nil || len(raw.Proxy) != 2001 {
		t.Fatalf("nodes lost: %v", err)
	}
}

func TestPrepareProfile(t *testing.T) {
	cases := []struct {
		name, text string
		wantError  bool
	}{
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
			if (err != nil) != tc.wantError {
				t.Fatalf("error=%v", err)
			}
			if err != nil {
				return
			}
			if strings.Contains(string(result), "*t") {
				t.Fatal("unresolved alias")
			}
			raw, err := UnmarshalRawConfig(result)
			if err != nil {
				t.Fatal(err)
			}
			source, err := UnmarshalRawConfig([]byte(tc.text))
			if err != nil {
				t.Fatal(err)
			}
			if len(raw.Proxy) != len(source.Proxy) || !reflect.DeepEqual(raw.ProxyGroup, source.ProxyGroup) || !reflect.DeepEqual(raw.Rule, source.Rule) {
				t.Fatalf("profile policies changed during preparation: %s", result)
			}
		})
	}
}

func TestPrepareProfileSmartDoesNotInitialize(t *testing.T) {
	home := t.TempDir()
	previous := C.Path.HomeDir()
	C.SetHomeDir(home)
	t.Cleanup(func() { C.SetHomeDir(previous) })
	// Preparation must preserve the home, even when every optional Smart resource
	// is requested and none of its runtime assets have been installed.
	if err := os.WriteFile(home+"/marker", []byte("unchanged"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, lightGBM := range []string{"true", "1", "false", "0"} {
		text := fmt.Sprintf("proxy-groups:\n - {name: '♻️ 自动选择', type: smart, proxies: [DIRECT], uselightgbm: %s, prefer-asn: true, collectdata: true}\nrules:\n - MATCH,♻️ 自动选择\n", lightGBM)
		prepared, err := PrepareProfile([]byte(text))
		if err != nil {
			t.Fatal(err)
		}
		source, _ := UnmarshalRawConfig([]byte(text))
		result, err := UnmarshalRawConfig(prepared)
		if err != nil || !reflect.DeepEqual(source.ProxyGroup, result.ProxyGroup) {
			t.Fatalf("Smart options changed: %v", err)
		}
		entries, err := os.ReadDir(home)
		if err != nil || len(entries) != 1 || entries[0].Name() != "marker" {
			t.Fatalf("preparation created runtime files: %v %v", entries, err)
		}
	}
	if _, err := PrepareProfile([]byte("proxy-groups:\n - {name: Smart, type: smart, proxies: [missing], uselightgbm: true}\n")); err == nil {
		t.Fatal("Smart validation accepted a missing member")
	}
	if _, err := PrepareProfile([]byte("proxy-groups:\n - {name: Smart, type: smart, proxies: [DIRECT], uselightgbm: invalid}\n")); err == nil {
		t.Fatal("Smart validation accepted an invalid option")
	}
}
