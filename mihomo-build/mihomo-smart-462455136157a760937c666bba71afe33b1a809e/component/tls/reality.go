package tls

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"errors"
	"net"
	"strings"
	"time"

	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/ntp"

	"github.com/metacubex/http"
	"github.com/metacubex/randv2"
	utls "github.com/metacubex/utls"
	"golang.org/x/crypto/hkdf"
)

const RealityMaxShortIDLen = 8

type RealityConfig struct {
	PublicKey *ecdh.PublicKey
	ShortID   [RealityMaxShortIDLen]byte

	SupportX25519MLKEM768 bool
}

// realityHandshakeOutcome describes why a single REALITY handshake attempt ended.
type realityHandshakeOutcome int

const (
	// realityAttemptOK means the peer proved possession of the REALITY private
	// key, i.e. the session ID we built was understood by the server.
	realityAttemptOK realityHandshakeOutcome = iota
	// realityAttemptNotReality means the TLS handshake completed but the peer
	// could not authenticate itself as a REALITY server. The most common cause
	// is a server that only accepts the legacy session ID layout and therefore
	// treated us as a probe, answering with the destination (steal-one) certificate.
	realityAttemptNotReality
	// realityAttemptError means the handshake itself failed (network, x509
	// verification of the fallback destination, protocol error, context cancel).
	// Retrying with the legacy layout is still worthwhile: an old server that
	// downgraded us to plain TLS presents the destination certificate, which
	// typically fails x509 validation.
	realityAttemptError
)

// GetRealityConn dials a REALITY server.
//
// The handshake is negotiated in two steps. mihomo's native format advertises
// the client version tuple "1.8.2" in session ID bytes [0:3]; panels built from
// Xray-core < 1.8.2 rejected that tuple (realitySettings.maxClientVer) and fell
// back to serving the destination site, which then fails either the REALITY
// proof check or x509 verification. When that happens the connection is rebuilt
// once with the legacy layout, whose session ID starts with the 64-bit
// timestamp and advertises the sing-box style "1.8.1" tuple.
//
// The version that succeeded is memoised in a bounded, concurrency-safe cache
// (packageRealityVersionCache) so follow-up connections to the same node skip
// the discovery round-trip and go straight to the working layout.
func GetRealityConn(ctx context.Context, conn net.Conn, fingerprint UClientHelloID, serverName string, realityConfig *RealityConfig) (net.Conn, error) {
	// The raw ClientHello (and therefore any bytes already written to the socket)
	// must be reset after a failed attempt, because conn is consumed in place.
	if setDeadline, ok := conn.(interface{ SetDeadline(time.Time) error }); ok {
		_ = setDeadline.SetDeadline(time.Time{})
	}
	rawConn, canRewind := conn.(*net.TCPConn)

	cacheKey := ""
	if realityConfig != nil {
		cacheKey = realityVersionCacheKey("", serverName, realityConfig.PublicKey.Bytes(), realityConfig.ShortID)
	}

	versions := []realityVersion{realityVersionNew}
	if realityConfig != nil {
		if version, ok := packageRealityVersionCache.get(cacheKey); ok {
			// Negotiated before: use the known-good layout first and keep the
			// other one as a safety net in case the panel was upgraded.
			if version != realityVersionNew {
				versions = []realityVersion{version, realityVersionNew}
			}
		} else {
			versions = append(versions, realityVersionLegacy)
		}
	}

	var lastErr error
	var negotiated realityVersion
	var rewound bool // the stream state is clean and a retry is safe
	for attempt, version := range versions {
		outcome, uConn, err := realityHandshake(ctx, conn, fingerprint, serverName, realityConfig, version)
		if outcome == realityAttemptOK {
			if realityConfig != nil {
				packageRealityVersionCache.put(cacheKey, version)
			}
			return uConn, nil
		}
		if err != nil {
			lastErr = err
		}
		switch outcome {
		case realityAttemptNotReality:
			// The peer answered our ClientHello (possibly with the destination
			// certificate) and then hung up, so nothing is left on the wire.
			rewound = true
			negotiated = version
		default: // realityAttemptError
			if eraseRealityClientHello(rawConn, canRewind) == nil {
				rewound = true
				negotiated = version
			}
		}
		if attempt != len(versions)-1 {
			// 版本协商是低频事件，用 Info 级输出以便在真机 info 日志（core.log）里直接判定
			// 旧版面板节点是否走到 legacy 重试，否则只能靠 debug 级别而现场抓不到。
			log.Infoln("REALITY negotiation: version %v failed (%v), retrying with %v", version, lastErr, versions[attempt+1])
		}
	}

	if lastErr == nil {
		lastErr = errors.New("REALITY authentication failed")
	}
	// Both layouts failed, so a cached entry is no longer trustworthy: drop it
	// (when one exists) so the next connection negotiates from scratch.
	if rewound && realityConfig != nil {
		if _, cached := packageRealityVersionCache.get(cacheKey); cached {
			packageRealityVersionCache.invalidate(cacheKey)
		}
	}
	log.Infoln("REALITY negotiation: all %d attempt(s) failed, last used version %v", len(versions), negotiated)
	return nil, lastErr
}

// eraseRealityClientHello removes the ClientHello bytes a failed attempt wrote
// into the kernel receive queue, so the next attempt starts from a clean stream.
//
// Linux keeps the (unread) receive queue across connect(2), which makes this
// possible; on other platforms, or when using a wrapped conn, no data can be
// reaped and the negotiation simply cannot fall back on the same socket.
func eraseRealityClientHello(conn *net.TCPConn, ok bool) error {
	if !ok || conn == nil {
		return errors.New("cannot rewind connection: connection is not a *net.TCPConn")
	}
	rawConn, err := conn.SyscallConn()
	if err != nil {
		return err
	}
	var ioErr error
	_ = rawConn.Control(func(fd uintptr) {
		ioErr = eraseRealityClientHelloLinux(fd, conn)
	})
	if ioErr == nil {
		log.Infoln("REALITY negotiation: discarded the ClientHello of the failed attempt")
	}
	return ioErr
}

// realityHandshake performs exactly one REALITY handshake attempt using the
// requested session ID layout. It never writes to conn before the attempt is
// known to be viable, so a failure leaves the caller free to retry.
func realityHandshake(ctx context.Context, conn net.Conn, fingerprint UClientHelloID, serverName string, realityConfig *RealityConfig, version realityVersion) (realityHandshakeOutcome, *utls.UConn, error) {
	for retry := 0; ; retry++ {
		verifier := &realityVerifier{
			serverName: serverName,
			version:    version,
		}
		uConfig := &utls.Config{
			Time:                   ntp.Now,
			ServerName:             serverName,
			InsecureSkipVerify:     true,
			SessionTicketsDisabled: true,
			VerifyConnection:       verifier.VerifyConnection,
		}

		uConn := utls.UClient(conn, uConfig, fingerprint)
		verifier.UConn = uConn
		err := uConn.BuildHandshakeState()
		if err != nil {
			return realityAttemptError, nil, err
		}

		if !realityConfig.SupportX25519MLKEM768 { // for X25519MLKEM768 does not work properly with the old reality server
			err = BuildRemovedX25519MLKEM768HandshakeState(uConn)
			if err != nil {
				return realityAttemptError, nil, err
			}
		}

		hello := uConn.HandshakeState.Hello
		rawSessionID := hello.Raw[realityRawSessionID : realityRawSessionID+realitySessionIDLen] // the location of session ID
		for i := range rawSessionID {                                                            // https://github.com/golang/go/issues/5373
			rawSessionID[i] = 0
		}

		// NOTE: the proof is derived from authKey with HKDF-SHA256, and the
		// certificate proof is HMAC-SHA512 over the Ed25519 public key. Neither
		// has ever depended on the client version tuple, so both layouts share
		// the derivation below byte for byte.
		sessionID := buildRealitySessionID(version, ntp.Now(), realityConfig.ShortID)
		copy(hello.SessionId[:], sessionID[:])

		//log.Debugln("REALITY hello.sessionId[:16]: %v", hello.SessionId[:16])

		keyShareKeys := uConn.HandshakeState.State13.KeyShareKeys
		if keyShareKeys == nil {
			// WTF???
			if retry > 2 {
				return realityAttemptError, nil, errors.New("nil keyShareKeys")
			}
			continue // retry
		}
		ecdheKey := keyShareKeys.Ecdhe
		if ecdheKey == nil {
			ecdheKey = keyShareKeys.MlkemEcdhe
		}
		if ecdheKey == nil {
			// WTF???
			if retry > 2 {
				return realityAttemptError, nil, errors.New("nil ecdheKey")
			}
			continue // retry
		}
		authKey, err := ecdheKey.ECDH(realityConfig.PublicKey)
		if err != nil {
			return realityAttemptError, nil, err
		}
		if authKey == nil {
			return realityAttemptError, nil, errors.New("nil auth_key")
		}
		verifier.authKey = authKey
		_, err = hkdf.New(sha256.New, authKey, hello.Random[:20], []byte("REALITY")).Read(authKey)
		if err != nil {
			return realityAttemptError, nil, err
		}
		aesBlock, _ := aes.NewCipher(authKey)
		aeadCipher, _ := cipher.NewGCM(aesBlock)
		aeadCipher.Seal(hello.SessionId[:0], hello.Random[20:], hello.SessionId[:16], hello.Raw)
		copy(hello.Raw[realityRawSessionID:], hello.SessionId)
		//log.Debugln("REALITY hello.sessionId: %v", hello.SessionId)
		//log.Debugln("REALITY uConn.AuthKey: %v", authKey)

		err = uConn.HandshakeContext(ctx)
		if err != nil {
			return realityAttemptError, nil, err
		}

		log.Debugln("REALITY Authentication: %v, AEAD: %T, version: %v", verifier.verified, aeadCipher, version)

		if !verifier.verified {
			go realityClientFallback(uConn, uConfig.ServerName, fingerprint)
			return realityAttemptNotReality, nil, errors.New("REALITY authentication failed")
		}

		return realityAttemptOK, uConn, nil
	}
}

func realityClientFallback(uConn net.Conn, serverName string, fingerprint utls.ClientHelloID) {
	defer uConn.Close()
	// use h2c mode to disallow the net/http fallback to http1.1
	//
	// Note that this usage is only applicable to our own net/http fork.
	// The standard library also needs to mask the tls.Conn type for the conn returned by DialTLSContext
	// see: https://github.com/golang/go/issues/79293#issuecomment-4426393534
	protocols := new(http.Protocols)
	protocols.SetUnencryptedHTTP2(true)
	client := http.Client{
		Transport: &http.Transport{
			DialTLSContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return uConn, nil
			},
			Protocols: protocols,
		},
	}
	request, err := http.NewRequest("GET", "https://"+serverName, nil)
	if err != nil {
		return
	}
	request.Header.Set("User-Agent", fingerprint.Client)
	request.AddCookie(&http.Cookie{Name: "padding", Value: strings.Repeat("0", randv2.IntN(32)+30)})
	response, err := client.Do(request)
	if err != nil {
		return
	}
	//_, _ = io.Copy(io.Discard, response.Body)
	time.Sleep(time.Duration(5+randv2.IntN(10)) * time.Second)
	response.Body.Close()
	client.CloseIdleConnections()
}

type realityVerifier struct {
	*utls.UConn
	serverName string
	version    realityVersion
	authKey    []byte
	verified   bool
}

func (c *realityVerifier) VerifyConnection(state utls.ConnectionState) error {
	log.Debugln("REALITY localAddr: %v is using X25519MLKEM768 for TLS' communication: %v", c.RemoteAddr(), c.HandshakeState.ServerHello.ServerShare.Group == utls.X25519MLKEM768)
	certs := state.PeerCertificates
	if pub, ok := certs[0].PublicKey.(ed25519.PublicKey); ok {
		// REALITY has always proved the certificate with HMAC-SHA512 over the
		// Ed25519 public key. tryRealityProof keeps that as the primary path and
		// only then looks at the historical SHA-256 derivation, so the default
		// behaviour is unchanged while old peers remain accepted.
		if ok, legacyHash := verifyRealityProof(c.authKey, pub, certs[0].Signature); ok {
			if legacyHash {
				log.Debugln("REALITY: peer proved its certificate with the legacy HMAC-SHA256 derivation")
			}
			c.verified = true
			return nil
		}
	}
	// Not a REALITY server (or an unrecognised proof flavour): fall back to the
	// regular x509 verification against the destination's own certificate.
	opts := x509.VerifyOptions{
		DNSName:       c.serverName,
		Intermediates: x509.NewCertPool(),
		CurrentTime:   ntp.Now(),
	}
	for _, cert := range certs[1:] {
		opts.Intermediates.AddCert(cert)
	}
	if _, err := certs[0].Verify(opts); err != nil {
		return err
	}
	return nil
}
