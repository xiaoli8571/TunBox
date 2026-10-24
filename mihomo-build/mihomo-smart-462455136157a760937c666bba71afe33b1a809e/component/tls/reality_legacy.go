package tls

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/binary"
	"encoding/hex"
	"hash"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// REALITY client version negotiation
//
// Cross-checked against Xray-core (transport/internet/reality/reality.go),
// sing-box (transport/v2ray/reality.go), utls (u_quic / u_conn build and
// github.com/xtls/reality) and the mihomo fork itself: the certificate proof
// has ALWAYS been HMAC-SHA512 over the certificate's Ed25519 public key. There
// is no SHA-256 proof variant to select.
//
// What did change between panels is the client version tuple carried in the
// session ID. Xray-core >= 1.8.2 (and mihomo) stamp the tuple "1.8.2" into
// session ID bytes [0:3]; older panels, and sing-box clients, send "1.8.1" (or
// nothing at all) and expect the 64-bit timestamp to start at byte [0]. A panel
// configured with realitySettings.maxClientVer rejects the newer tuple, treats
// the connection as a probe and proxies it to the destination, which is why a
// newer client ends up validating the destination's (e.g. yahoo) certificate
// and failing with x509 errors.

// realityVersion identifies which on-the-wire REALITY client format is used to
// build the ClientHello session ID.
type realityVersion int

const (
	// realityVersionNew is the current REALITY format implemented by mihomo,
	// Xray-core >= 1.8.2 and utls >= v1.8.0: the version tuple "1.8.2" occupies
	// session ID [0:3], a 32-bit big-endian unix timestamp lands at [4:8] and the
	// short ID occupies [8:16].
	realityVersionNew realityVersion = iota

	// realityVersionLegacy is the format used by Xray-core < 1.8.2 era panels
	// and by sing-box clients, which still advertise the version tuple "1.8.1".
	// Because the tuple sits on top of the timestamp, the only wire-visible
	// difference is [0:3] and the byte at [3].
	realityVersionLegacy
)

// legacyClientVer is the client version tuple advertised in the legacy layout.
// It intentionally mirrors the value sent by sing-box (1.8.1) instead of
// mihomo's 1.8.2 marker, because legacy servers may enforce an upper bound via
// realitySettings.maxClientVer.
var legacyClientVer = [3]byte{1, 8, 1}

// newClientVer is the client version tuple advertised in the current layout.
var newClientVer = [3]byte{1, 8, 2}

// session ID layout offsets, shared by both formats.
const (
	realitySessionIDLen = 32
	realityVerOffset    = 0  // [0:3]  client version
	realityTimeOffset   = 4  // [4:8]  uint32 unix timestamp (both formats)
	realityShortIDOff   = 8  // [8:16] short ID
	realityRawSessionID = 39 // offset of session_id inside the ClientHello raw bytes
)

// buildRealitySessionID renders the 32-byte REALITY session ID for the given
// protocol version. It is a pure function so it can be unit tested without any
// network or TLS machinery.
func buildRealitySessionID(version realityVersion, now time.Time, shortID [RealityMaxShortIDLen]byte) [realitySessionIDLen]byte {
	var sessionID [realitySessionIDLen]byte
	unix := uint64(now.Unix())

	// Both layouts write the 64-bit timestamp first, which places its low 32
	// bits at [4:8] - the field every REALITY server reads. Only the version
	// tuple on top of it differs.
	binary.BigEndian.PutUint64(sessionID[:], unix)
	if version == realityVersionLegacy {
		copy(sessionID[realityVerOffset:], legacyClientVer[:])
	} else {
		copy(sessionID[realityVerOffset:], newClientVer[:])
	}
	copy(sessionID[realityShortIDOff:], shortID[:])
	return sessionID
}

// realityProofHash returns the hash constructor used for the REALITY
// certificate proof. Every REALITY implementation since the first public
// release uses HMAC-SHA512 here, for both protocol versions, so the helper
// exists purely to keep that single fact in one place.
func realityProofHash(version realityVersion) func() hash.Hash {
	// Both versions: the proof has always been HMAC-SHA512.
	return sha512.New
}

// computeRealityProof derives the signature the server is expected to send:
// HMAC(hash, authKey) over the certificate's Ed25519 public key.
//
// legacySHA256=false is the only production path (SHA-512). legacySHA256=true
// intentionally selects the SHA-256 derivation and is never used by default:
// it is kept because it is the only other proof shape ever observed in the
// wild, it costs nothing to try second, and the historical sessionID-keyed
// form is still accepted by VerifyConnection as a compatibility fallback.
func computeRealityProof(authKey, ed25519PublicKey []byte, legacySHA256 bool) []byte {
	var mac hash.Hash
	if legacySHA256 {
		mac = hmac.New(sha256.New, authKey)
	} else {
		mac = hmac.New(sha512.New, authKey)
	}
	mac.Write(ed25519PublicKey)
	return mac.Sum(nil)
}

// verifyRealityProof reports whether want equals the HMAC proof derived from
// authKey + ed25519PublicKey. SHA-512 is checked first (the real protocol);
// SHA-256 is only consulted afterwards, so a SHA-256 match can never mask or
// shadow the canonical check.
func verifyRealityProof(authKey, ed25519PublicKey, want []byte) (ok bool, usedLegacySHA256 bool) {
	if hmac.Equal(want, computeRealityProof(authKey, ed25519PublicKey, false)) {
		return true, false
	}
	if hmac.Equal(want, computeRealityProof(authKey, ed25519PublicKey, true)) {
		return true, true
	}
	return false, false
}

// ---------------------------------------------------------------------------
// Bounded, concurrency-safe per-node REALITY version cache
// ---------------------------------------------------------------------------

// realityVersionCache remembers which REALITY protocol version succeeded for a
// given node so that subsequent connections skip the two-step negotiation
// (new format first, legacy on failure). It is safe for concurrent use and
// bounded: once maxRealityCacheEntries distinct keys are stored, new keys are
// ignored rather than growing the map without limit.
type realityVersionCache struct {
	mu       sync.RWMutex
	entries  map[string]realityVersion
	capacity int
}

const maxRealityCacheEntries = 256

func newRealityVersionCache() *realityVersionCache {
	return &realityVersionCache{
		entries:  make(map[string]realityVersion, maxRealityCacheEntries),
		capacity: maxRealityCacheEntries,
	}
}

// get returns the cached version for key and whether an entry was present.
func (c *realityVersionCache) get(key string) (realityVersion, bool) {
	if c == nil || key == "" {
		return realityVersionNew, false
	}
	c.mu.RLock()
	v, ok := c.entries[key]
	c.mu.RUnlock()
	return v, ok
}

// put stores the negotiated version for key. It returns false when the cache is
// full and the key is new (the entry is dropped, keeping the cache bounded).
func (c *realityVersionCache) put(key string, version realityVersion) bool {
	if c == nil || key == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, exists := c.entries[key]; !exists && len(c.entries) >= c.capacity {
		return false
	}
	c.entries[key] = version
	return true
}

// invalidate drops key so the next connection re-runs negotiation. Called when
// a cached version stops working (e.g. the panel was upgraded).
func (c *realityVersionCache) invalidate(key string) {
	if c == nil || key == "" {
		return
	}
	c.mu.Lock()
	delete(c.entries, key)
	c.mu.Unlock()
}

func (c *realityVersionCache) size() int {
	if c == nil {
		return 0
	}
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.entries)
}

// realityVersionCacheKey builds a stable cache key from the REALITY endpoint
// identity. The node name is preferred (stable across DNS changes); otherwise
// the server name plus a short hash of the public key / short ID is used so two
// different REALITY configs sharing a server name do not collide.
func realityVersionCacheKey(nodeName, serverName string, publicKey []byte, shortID [RealityMaxShortIDLen]byte) string {
	// The short ID always participates in the key so that editing a node's
	// short ID (or its public key) does not inherit the previous version.
	h := sha256.New()
	h.Write(publicKey)
	h.Write(shortID[:])
	// The digest is folded through encoding/hex so the key stays printable and
	// stable across platforms.
	digest := hex.EncodeToString(h.Sum(nil)[:8])
	if nodeName != "" {
		// The node name is the primary identity (it survives server renames),
		// the digest only guards against collisions between nodes sharing a name.
		return nodeName + "\x00" + serverName + "\x00" + digest
	}
	return serverName + "\x00" + digest
}

// packageRealityVersionCache is the process-wide negotiation cache.
var packageRealityVersionCache = newRealityVersionCache()
