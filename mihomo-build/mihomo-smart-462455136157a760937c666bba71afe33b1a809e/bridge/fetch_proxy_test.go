package bridge

import (
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestFetchHTTPSUsesProxyAndOneHandshake(t *testing.T) {
	for _, h2 := range []bool{false, true} {
		t.Run(fmt.Sprintf("h2=%v", h2), func(t *testing.T) {
			var handshakes, tunnels atomic.Int32
			srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if (r.ProtoMajor == 2) != h2 {
					t.Errorf("unexpected protocol: %s", r.Proto)
				}
				_, _ = io.WriteString(w, "  proxies: []\n")
			}))
			srv.Config.ConnState = func(_ net.Conn, s http.ConnState) {
				if s == http.StateNew {
					handshakes.Add(1)
				}
			}
			srv.EnableHTTP2 = h2
			srv.StartTLS()
			defer srv.Close()
			pool := x509.NewCertPool()
			pool.AddCert(srv.Certificate())
			previous := testRootCAs
			testRootCAs = pool
			defer func() { testRootCAs = previous }()
			proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodConnect {
					t.Errorf("expected CONNECT, got %s", r.Method)
					w.WriteHeader(400)
					return
				}
				tunnels.Add(1)
				upstream, err := net.Dial("tcp", r.Host)
				if err != nil {
					t.Error(err)
					w.WriteHeader(502)
					return
				}
				client, _, err := w.(http.Hijacker).Hijack()
				if err != nil {
					upstream.Close()
					t.Error(err)
					return
				}
				_, _ = io.WriteString(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
				go func() { _, _ = io.Copy(upstream, client); upstream.Close() }()
				_, _ = io.Copy(client, upstream)
				client.Close()
			}))
			defer proxy.Close()
			result, err := FetchWithProxy(srv.URL, "TunBox/test", "", time.Second, proxy.URL, true)
			if err != nil {
				t.Fatal(err)
			}
			if result.Body != "  proxies: []\n" {
				t.Fatalf("body changed: %q", result.Body)
			}
			if tunnels.Load() != 1 || handshakes.Load() != 1 {
				t.Fatalf("CONNECT=%d TLS=%d, want one each", tunnels.Load(), handshakes.Load())
			}
		})
	}
}

func TestFetchProxyFailureNeverFallsBackToDirect(t *testing.T) {
	var direct atomic.Int32
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { direct.Add(1) }))
	defer target.Close()
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusProxyAuthRequired) }))
	defer proxy.Close()
	_, err := FetchWithProxy(target.URL, "UA", "", time.Second, proxy.URL, true)
	if err == nil || !strings.Contains(err.Error(), "CONNECT HTTP 407") {
		t.Fatalf("expected proxy error, got %v", err)
	}
	if direct.Load() != 0 {
		t.Fatal("request escaped the selected proxy")
	}
}

func TestFetchRedirectDoesNotLeakBasicCredentials(t *testing.T) {
	var leaked string
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		leaked = r.Header.Get("Authorization")
		_, _ = io.WriteString(w, "ok")
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, strings.Replace(target.URL, "127.0.0.1", "localhost", 1), http.StatusFound)
	}))
	defer source.Close()
	_, err := Fetch(source.URL, "UA", "Basic c2VjcmV0", time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if leaked != "" {
		t.Fatal("Basic credentials leaked to a different host")
	}
}

func TestFetchProxyConnectHonorsTotalDeadline(t *testing.T) {
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { time.Sleep(150 * time.Millisecond) }))
	defer proxy.Close()
	start := time.Now()
	_, err := FetchWithProxy("https://example.com/", "UA", "", 25*time.Millisecond, proxy.URL, true)
	if err == nil || time.Since(start) > 120*time.Millisecond {
		t.Fatalf("CONNECT deadline not honored: %v (%v)", err, time.Since(start))
	}
}
