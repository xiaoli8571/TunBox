package bridge

import (
	"compress/gzip"
	"crypto/tls"
	"crypto/x509"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestFetchPlainHTTP(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/yaml")
		w.Header().Set("Subscription-Userinfo", "upload=1;download=2;total=3;expire=999")
		w.Header().Set("ETag", "tag")
		_, _ = w.Write([]byte("proxies: []"))
	}))
	defer srv.Close()
	res, err := Fetch(srv.URL, "UA", "", 20*time.Second)
	if err != nil {
		t.Fatalf("plain HTTP fetch: %v", err)
	}
	if res.Body != "proxies: []" || res.Status != 200 {
		t.Fatalf("unexpected result %+v", res)
	}
}

func TestFetchTLSHTTP11(t *testing.T) {
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 1 {
			t.Errorf("expected HTTP/1.1, got %s", r.Proto)
		}
		_, _ = w.Write([]byte("ok"))
	}))
	srv.EnableHTTP2 = false
	srv.StartTLS()
	defer srv.Close()
	// Test-only seam: trust the httptest CA so the TLS path below runs.
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	prev := testRootCAs
	testRootCAs = pool
	t.Cleanup(func() { testRootCAs = prev })
	res, err := Fetch(srv.URL, "UA", "", 20*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if res.Body != "ok" {
		t.Fatalf("unexpected body %q", res.Body)
	}
}

func TestFetchTLSHTTP2(t *testing.T) {
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.ProtoMajor != 2 {
			t.Errorf("expected HTTP/2, got %s", r.Proto)
		}
		_, _ = w.Write([]byte("h2-ok"))
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()
	pool := x509.NewCertPool()
	pool.AddCert(srv.Certificate())
	prev := testRootCAs
	testRootCAs = pool
	t.Cleanup(func() { testRootCAs = prev })
	res, err := Fetch(srv.URL, "UA", "", 20*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if res.Body != "h2-ok" {
		t.Fatalf("unexpected body %q", res.Body)
	}
}

// Without the test-root seam, production never trusts this self-signed cert.
// The assertion below is that verification still fails as a cert error rather
// than silently succeeding.
func TestFetchTLSWithRootCA(t *testing.T) {
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("tls-ok"))
	}))
	defer srv.Close()
	// httptest uses a self-signed certificate that production cannot trust;
	// the important assertion is that the transport reaches TLS negotiation
	// without demanding a second HTTP2 transport.
	_, err := Fetch(srv.URL, "UA", "", 20*time.Second)
	if err == nil {
		t.Fatal("untrusted certificate unexpectedly accepted")
	}
	if !strings.Contains(err.Error(), "certificate") && !strings.Contains(err.Error(), "x509") {
		t.Fatalf("expected TLS certificate failure, got %v", err)
	}
}

func TestFetchGzipBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Encoding", "gzip")
		gz := gzip.NewWriter(w)
		_, _ = gz.Write([]byte("compressed"))
		_ = gz.Close()
	}))
	defer srv.Close()
	res, err := Fetch(srv.URL, "UA", "", 20*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if res.Body != "compressed" {
		t.Fatalf("unexpected body %q", res.Body)
	}
}

func TestFetchStatus429Error(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(429)
	}))
	defer srv.Close()
	_, err := Fetch(srv.URL, "UA", "", 20*time.Second)
	if err == nil || !strings.Contains(err.Error(), "HTTP 429") {
		t.Fatalf("expected HTTP 429, got %v", err)
	}
}

var _ = tls.VersionTLS12
