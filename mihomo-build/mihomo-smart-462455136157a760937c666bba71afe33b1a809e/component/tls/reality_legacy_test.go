package tls

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/binary"
	"sync"
	"testing"
	"time"
)

// TestBuildRealitySessionIDNewLayout pins the current (>= 1.8.2) session ID
// layout: [0:3] = 1.8.2 marker, [4:8] = uint32 timestamp, [8:16] = short ID.
func TestBuildRealitySessionIDNewLayout(t *testing.T) {
	now := time.Unix(1700000000, 0) // 2023-11-14T22:13:20Z
	var shortID [RealityMaxShortIDLen]byte
	copy(shortID[:], []byte{0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04})

	got := buildRealitySessionID(realityVersionNew, now, shortID)

	if !bytes.Equal(got[0:3], []byte{1, 8, 2}) {
		t.Fatalf("new layout version marker = %v, want [1 8 2]", got[0:3])
	}
	if ts := binary.BigEndian.Uint32(got[4:8]); ts != 1700000000 {
		t.Fatalf("new layout timestamp = %d, want 1700000000", ts)
	}
	if !bytes.Equal(got[8:16], shortID[:]) {
		t.Fatalf("new layout short id = %v, want %v", got[8:16], shortID[:])
	}
	// Bytes [16:32] must stay zero: REALITY only uses the first 16.
	if !bytes.Equal(got[16:], make([]byte, 16)) {
		t.Fatalf("new layout tail not zeroed: %v", got[16:])
	}
	// The version marker must overwrite the timestamp's high bytes.
	if got[3] != 0 {
		t.Fatalf("new layout byte[3] = %d, want 0 (reserved)", got[3])
	}
}

// TestBuildRealitySessionIDLegacyLayout pins the pre-1.8.2 session ID layout:
// NO version marker, 64-bit BE timestamp at [0:8], short ID at [8:16]. This is
// the format sent by sing-box clients (which advertise 1.8.1 and rely on the
// legacy timestamp placement).
func TestBuildRealitySessionIDLegacyLayout(t *testing.T) {
	now := time.Unix(1700000000, 0)
	var shortID [RealityMaxShortIDLen]byte
	copy(shortID[:], []byte{0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88})

	got := buildRealitySessionID(realityVersionLegacy, now, shortID)

	// The 64-bit timestamp is written first and the 3-byte version tuple is
	// stamped on top of its high bytes, exactly like Xray-core does. The low 32
	// bits must therefore stay intact at [4:8] - that is the field every REALITY
	// server reads - while [0:3] advertise the sing-box style 1.8.1 tuple.
	if ts := binary.BigEndian.Uint32(got[4:8]); ts != 1700000000 {
		t.Fatalf("legacy layout [4:8] timestamp = %d, want 1700000000", ts)
	}
	if !bytes.Equal(got[0:3], []byte{1, 8, 1}) {
		t.Fatalf("legacy layout version tuple = %v, want [1 8 1]", got[0:3])
	}
	if bytes.Equal(got[0:3], []byte{1, 8, 2}) {
		t.Fatal("legacy layout must not carry the 1.8.2 version marker")
	}
	if !bytes.Equal(got[8:16], shortID[:]) {
		t.Fatalf("legacy layout short id = %v, want %v", got[8:16], shortID[:])
	}
	if !bytes.Equal(got[16:], make([]byte, 16)) {
		t.Fatalf("legacy layout tail not zeroed: %v", got[16:])
	}
}

// TestRealitySessionIDLayoutsDiffer asserts the two layouts are actually
// distinct for a realistic short ID, i.e. the negotiation is not a no-op.
func TestRealitySessionIDLayoutsDiffer(t *testing.T) {
	now := time.Unix(1700000000, 0)
	var shortID [RealityMaxShortIDLen]byte
	copy(shortID[:], []byte{0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11})

	newID := buildRealitySessionID(realityVersionNew, now, shortID)
	oldID := buildRealitySessionID(realityVersionLegacy, now, shortID)

	if newID == oldID {
		t.Fatal("new and legacy session ID layouts must differ in the version bytes")
	}
	if bytes.Equal(newID[0:3], oldID[0:3]) {
		t.Fatalf("version bytes must differ: new=%v legacy=%v", newID[0:3], oldID[0:3])
	}
}

// TestComputeRealityProofSHA512MatchesStdlib verifies the proof derivation is a
// plain HMAC-SHA512 (the only flavour real REALITY servers have ever shipped)
// over the Ed25519 public key, keyed with the negotiated auth key.
func TestComputeRealityProofSHA512MatchesStdlib(t *testing.T) {
	authKey := []byte("0123456789abcdef0123456789abcdef")
	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = byte(i * 7)
	}

	got := computeRealityProof(authKey, pub, false)

	ref := hmac.New(sha512.New, authKey)
	ref.Write(pub)
	want := ref.Sum(nil)

	if !bytes.Equal(got, want) {
		t.Fatalf("SHA-512 proof mismatch:\n got=%x\nwant=%x", got, want)
	}
	if len(got) != sha512.Size {
		t.Fatalf("SHA-512 proof length = %d, want %d", len(got), sha512.Size)
	}
}

// TestComputeRealityProofSHA256Legacy verifies the legacy SHA-256 derivation
// used for compatibility probing of older/odd panels.
func TestComputeRealityProofSHA256Legacy(t *testing.T) {
	authKey := []byte("fedcba9876543210fedcba9876543210")
	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = byte(255 - i)
	}

	got := computeRealityProof(authKey, pub, true)

	ref := hmac.New(sha256.New, authKey)
	ref.Write(pub)
	want := ref.Sum(nil)

	if !bytes.Equal(got, want) {
		t.Fatalf("SHA-256 proof mismatch:\n got=%x\nwant=%x", got, want)
	}
	if len(got) != sha256.Size {
		t.Fatalf("SHA-256 proof length = %d, want %d", len(got), sha256.Size)
	}
}

// TestVerifyRealityProof covers the two accepted proof flavours and rejection.
func TestVerifyRealityProof(t *testing.T) {
	authKey := []byte("keykeykeykeykeykeykeykeykeykeyke")
	pub := make([]byte, 32)
	for i := range pub {
		pub[i] = byte(i)
	}

	sha512Proof := computeRealityProof(authKey, pub, false)
	sha256Proof := computeRealityProof(authKey, pub, true)

	if ok, legacy := verifyRealityProof(authKey, pub, sha512Proof); !ok || legacy {
		t.Fatalf("sha512 proof: ok=%v legacy=%v, want true/false", ok, legacy)
	}
	if ok, legacy := verifyRealityProof(authKey, pub, sha256Proof); !ok || !legacy {
		t.Fatalf("sha256 proof: ok=%v legacy=%v, want true/true", ok, legacy)
	}
	if ok, _ := verifyRealityProof(authKey, pub, make([]byte, len(sha512Proof))); ok {
		t.Fatal("all-zero proof must not verify")
	}
	// Wrong key must not verify even with a correct proof body.
	if ok, _ := verifyRealityProof([]byte("another-key-another-key-another"), pub, sha512Proof); ok {
		t.Fatal("proof must not verify under a different auth key")
	}
}

// TestRealityVersionCacheRoundTrip checks basic caching semantics.
func TestRealityVersionCacheRoundTrip(t *testing.T) {
	c := newRealityVersionCache()
	if _, ok := c.get("node-a"); ok {
		t.Fatal("empty cache returned a hit")
	}
	if !c.put("node-a", realityVersionLegacy) {
		t.Fatal("first put must succeed")
	}
	v, ok := c.get("node-a")
	if !ok || v != realityVersionLegacy {
		t.Fatalf("get = (%v, %v), want (legacy, true)", v, ok)
	}
	c.invalidate("node-a")
	if _, ok := c.get("node-a"); ok {
		t.Fatal("invalidated entry still present")
	}
	// Empty keys are never cached.
	if _, ok := c.get(""); ok {
		t.Fatal("empty key must not hit")
	}
	if c.put("", realityVersionNew) {
		t.Fatal("empty key must not be stored")
	}
}

// TestRealityVersionCacheBounded verifies the cache never exceeds its capacity.
func TestRealityVersionCacheBounded(t *testing.T) {
	c := newRealityVersionCache()
	for i := 0; i < c.capacity+50; i++ {
		c.put(string(rune('a'+i%26))+string(rune(i)), realityVersionNew)
	}
	if got := c.size(); got > c.capacity {
		t.Fatalf("cache size = %d, want <= %d", got, c.capacity)
	}
}

// TestRealityVersionCacheConcurrent hammers the cache from many goroutines to
// catch data races (run with -race).
func TestRealityVersionCacheConcurrent(t *testing.T) {
	c := newRealityVersionCache()
	var wg sync.WaitGroup
	for g := 0; g < 32; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				key := string(rune('A' + g%8))
				c.put(key, realityVersion(g%2))
				_, _ = c.get(key)
				c.invalidate(string(rune('Z' + g%4)))
				_ = c.size()
			}
		}(g)
	}
	wg.Wait()
}

// TestRealityVersionCacheKeyStable ensures the key function is deterministic and
// distinguishes different short IDs / servers.
func TestRealityVersionCacheKeyStable(t *testing.T) {
	pub := []byte("0123456789abcdef0123456789abcdef")
	var shortA, shortB [RealityMaxShortIDLen]byte
	shortA[0] = 1
	shortB[0] = 2

	a1 := realityVersionCacheKey("node", "example.com", pub, shortA)
	a2 := realityVersionCacheKey("node", "example.com", pub, shortA)
	b := realityVersionCacheKey("node", "example.com", pub, shortB)

	if a1 != a2 {
		t.Fatal("cache key is not deterministic")
	}
	if a1 == b {
		t.Fatal("cache key must incorporate the short ID")
	}
	// Without a node name the key falls back to server name + pubkey/shortID hash.
	n1 := realityVersionCacheKey("", "example.com", pub, shortA)
	n2 := realityVersionCacheKey("", "example.com", pub, shortB)
	if n1 == n2 {
		t.Fatal("fallback cache key must incorporate the short ID")
	}
}
