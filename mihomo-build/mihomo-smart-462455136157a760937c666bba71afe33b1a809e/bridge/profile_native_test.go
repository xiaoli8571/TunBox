package bridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
)

// A mobile app owns its profile directory, not Go's global temporary directory.
// The OpenHarmony Go port defaults os.TempDir to /data/local/tmp (owned by shell).
func TestValidateProfileDoesNotDependOnSystemTemp(t *testing.T) {
	home := t.TempDir()
	t.Setenv("TMPDIR", filepath.Join(home, "unavailable-system-temp"))
	target := filepath.Join(home, "profiles", "subscription.yaml")
	content := []byte(profileTestProfile)
	if err := ValidateProfile(content, "", target); err != nil {
		t.Fatalf("valid profile rejected because system temp is unavailable: %v", err)
	}
	got, err := os.ReadFile(target)
	if err != nil || string(got) != string(content) {
		t.Fatalf("stored profile differs from input: read error=%v", err)
	}
}

func TestValidateProfileInvalidKeepsExistingFile(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "subscription.yaml")
	original := []byte(profileTestProfile)
	if err := os.WriteFile(target, original, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ValidateProfile([]byte("proxies: [\n"), "", target); err == nil {
		t.Fatal("malformed YAML accepted")
	}
	got, err := os.ReadFile(target)
	if err != nil || string(got) != string(original) {
		t.Fatalf("failed validation changed the working profile: %v", err)
	}
	assertOnlyProfile(t, dir, "subscription.yaml")
}

// Replacing an existing profile commits by rename and leaves no staging file.
func TestValidateProfileReplacesAtomicallyAndStaysPrivate(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "subscription.yaml")
	for _, body := range []string{"proxies: []\n", profileTestProfile} {
		if err := ValidateProfile([]byte(body), "", target); err != nil {
			t.Fatal(err)
		}
		got, err := os.ReadFile(target)
		if err != nil || string(got) != body {
			t.Fatalf("stored profile differs from input: %v", err)
		}
	}
	info, err := os.Stat(target)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		t.Fatalf("profile readable by other users: %o", perm)
	}
	assertOnlyProfile(t, dir, "subscription.yaml")
}

func assertOnlyProfile(t *testing.T, dir, name string) {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != name {
		names := make([]string, 0, len(entries))
		for _, entry := range entries {
			names = append(names, entry.Name())
		}
		t.Fatalf("unexpected files left in profile directory: %v", names)
	}
}

// Optional survey of private real-world profiles (never committed). Set
// TUNBOX_REAL_PROFILE_DIR to a directory of subscription YAML files exported
// from a device. Only counts and error text are logged, never profile content.
//
// Import must accept every profile the kernel can parse. The stricter
// config.PrepareProfile result is logged separately: the app applies that
// check to the merged runtime config before starting the core.
func TestRealProfilesSurvey(t *testing.T) {
	dir := os.Getenv("TUNBOX_REAL_PROFILE_DIR")
	if dir == "" {
		t.Skip("TUNBOX_REAL_PROFILE_DIR not set")
	}
	paths, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no profiles under %s: %v", dir, err)
	}
	for index, path := range paths {
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		label := "profile-" + string(rune('A'+index))
		raw, err := config.UnmarshalRawConfig(content)
		if err != nil {
			t.Errorf("%s: kernel parse failed: %s", label, shorten(err))
			continue
		}
		t.Logf("%s: bytes=%d proxies=%d groups=%d rules=%d proxy-providers=%d rule-providers=%d",
			label, len(content), len(raw.Proxy), len(raw.ProxyGroup), len(raw.Rule),
			len(raw.ProxyProvider), len(raw.RuleProvider))
		target := filepath.Join(t.TempDir(), "profile.yaml")
		if err := ValidateProfile(content, "", target); err != nil {
			t.Errorf("%s: import rejected a profile the kernel parses: %s", label, shorten(err))
			continue
		}
		stored, err := os.ReadFile(target)
		if err != nil || string(stored) != string(content) {
			t.Errorf("%s: stored profile is not byte-identical: %v", label, err)
		}
		outbounds, err := GetProfileOutbounds(target)
		if err != nil {
			t.Errorf("%s: outbound projection failed: %s", label, shorten(err))
		} else if len(outbounds.Proxies) != len(raw.Proxy) || len(outbounds.ProxyGroups) != len(raw.ProxyGroup) {
			t.Errorf("%s: projection lost entries: proxies %d/%d groups %d/%d", label,
				len(outbounds.Proxies), len(raw.Proxy), len(outbounds.ProxyGroups), len(raw.ProxyGroup))
		}
		if _, err := config.PrepareProfile(content); err != nil {
			t.Logf("%s: strict PrepareProfile rejects the raw profile: %s", label, shorten(err))
		} else {
			t.Logf("%s: strict PrepareProfile accepts the raw profile", label)
		}
	}
}

func shorten(err error) string {
	text := strings.ReplaceAll(err.Error(), "\n", " ")
	if len(text) > 240 {
		return text[:240] + "..."
	}
	return text
}
