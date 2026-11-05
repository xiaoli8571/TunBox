package bridge

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLogRotationIsBounded(t *testing.T) {
	path := filepath.Join(t.TempDir(), "core.log")
	w := RotatingLog{Path: path, MaxBytes: 8, Backups: 2}
	for _, s := range []string{"11111111", "22222222", "33333333", "44444444"} {
		if _, err := w.Write([]byte(s)); err != nil {
			t.Fatal(err)
		}
	}
	for i, want := range []string{"44444444", "33333333", "22222222"} {
		p := path
		if i > 0 {
			p += string([]byte{'.', byte('0' + i)})
		}
		got, err := os.ReadFile(p)
		if err != nil || string(got) != want {
			t.Fatalf("%s=%s err=%v", p, got, err)
		}
	}
	if _, err := os.Stat(path + ".3"); !os.IsNotExist(err) {
		t.Fatal("unbounded backups")
	}
	if _, err := w.Write([]byte("oversized-abcdefgh")); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(path)
	if string(got) != "abcdefgh" {
		t.Fatalf("oversized tail=%s", got)
	}
}

func TestDiskFailureDoesNotCloseLogCollector(t *testing.T) {
	w := BestEffortLog{Writer: &RotatingLog{Path: filepath.Join(t.TempDir(), "absent", "core.log"), MaxBytes: 8, Backups: 1}}
	n, err := w.Write([]byte("evidence"))
	if n != 8 || err != nil {
		t.Fatalf("pipe collector stopped: %d %v", n, err)
	}
}
