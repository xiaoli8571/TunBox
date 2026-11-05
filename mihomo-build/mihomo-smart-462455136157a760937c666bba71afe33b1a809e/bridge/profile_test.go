package bridge

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/age"
	agecomponent "github.com/metacubex/mihomo/component/age"
)

const profileTestProfile = `x-defaults: &socks {type: socks5, server: 127.0.0.1, port: 1080}
mixed-port: 7000
proxies:
  - {<<: *socks, name: a}
  - name: b
    type: vless
    server: 127.0.0.1
    port: 443
    uuid: 2a70e3a9-b4ce-4f20-908d-e99950a0a611
    network: tcp
    tls: true
    reality-opts: {public-key: SbVKOEMjK0sIlbwg4akyBg5mL5KZwwB-ed4eEE7YnRc, short-id: 0123}
proxy-groups:
  - {name: g, type: select, proxies: [a, b]}
rules:
  - MATCH,g
`

func writeProfile(t *testing.T, content []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "profiles", "1.yaml")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	return path
}

func TestValidateProfilePlainPassesVerbatim(t *testing.T) {
	path := writeProfile(t, nil)
	content := []byte(profileTestProfile)
	if err := ValidateProfile(content, "", path); err != nil {
		t.Fatalf("ValidateProfile(valid) = %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read profile: %v", err)
	}
	// Anchors must NOT be expanded: the file is a verbatim copy of the input.
	if string(got) != string(content) {
		t.Errorf("profile file was rewritten/expanded, want verbatim copy")
	}
}

func TestValidateProfileArmorEmptyKey(t *testing.T) {
	path := writeProfile(t, nil)
	armor := []byte(agecomponent.FileHeader + "\nnot-a-real-key\n")
	err := ValidateProfile(armor, "", path)
	if !errors.Is(err, ErrAgeSecretKeyRequired) {
		t.Fatalf("ValidateProfile(armor, empty key) = %v, want ErrAgeSecretKeyRequired", err)
	}
}

func TestValidateProfileArmorDecrypts(t *testing.T) {
	identity, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatalf("generate identity: %v", err)
	}
	secretKey := identity.String()
	encrypted, err := agecomponent.EncryptBytes([]byte(profileTestProfile), identity.Recipient().String())
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	if !strings.HasPrefix(string(encrypted), agecomponent.FileHeader) {
		t.Fatalf("encrypted fixture missing armor header")
	}
	path := writeProfile(t, nil)
	if err := ValidateProfile(encrypted, secretKey, path); err != nil {
		t.Fatalf("ValidateProfile(armor, key) = %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read profile: %v", err)
	}
	if string(got) != profileTestProfile {
		t.Errorf("decrypted profile mismatch, want plaintext verbatim")
	}
}

func TestValidateProfileShareLinkFallback(t *testing.T) {
	path := writeProfile(t, nil)
	link := "vless://2a70e3a9-b4ce-4f20-908d-e99950a0a611@127.0.0.1:443?encryption=none&security=none&type=tcp#node1"
	if err := ValidateProfile([]byte(link), "", path); err != nil {
		t.Fatalf("ValidateProfile(share link) = %v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read profile: %v", err)
	}
	if !strings.Contains(string(got), "proxies:") || !strings.Contains(string(got), "node1") {
		t.Fatalf("converted profile missing proxies/node1, got %q", string(got))
	}
}

func TestValidateProfileInvalidKeepsFirstIssue(t *testing.T) {
	path := writeProfile(t, nil)
	garbage := []byte("proxies: [\n")
	err := ValidateProfile(garbage, "", path)
	if err == nil {
		t.Fatal("ValidateProfile(garbage) = nil, want first validate issue")
	}
	if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
		t.Fatalf("profile file must not exist on failure, stat err = %v", statErr)
	}
}

func TestGetProfileOutboundsProjectsNameType(t *testing.T) {
	in := filepath.Join(t.TempDir(), "profile.yaml")
	if err := os.WriteFile(in, []byte(profileTestProfile), 0o600); err != nil {
		t.Fatalf("write profile: %v", err)
	}
	out, err := GetProfileOutbounds(in)
	if err != nil {
		t.Fatalf("GetProfileOutbounds = %v", err)
	}
	if len(out.Proxies) != 2 || out.Proxies[0].Name != "a" || out.Proxies[0].Type != "socks5" ||
		out.Proxies[1].Name != "b" || out.Proxies[1].Type != "vless" {
		t.Fatalf("proxies = %+v", out.Proxies)
	}
	if len(out.ProxyGroups) != 1 || out.ProxyGroups[0].Name != "g" || out.ProxyGroups[0].Type != "select" {
		t.Fatalf("proxyGroups = %+v", out.ProxyGroups)
	}
}
