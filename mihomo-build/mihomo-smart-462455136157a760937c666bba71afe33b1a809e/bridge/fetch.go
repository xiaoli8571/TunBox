package bridge

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"context"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	utls "github.com/metacubex/utls"
	"golang.org/x/net/http2"
)

// Subscription download transport. The 20s deadline and explicit app proxy
// follow FlClash v0.9.3 request.dart/http.dart. The TLS implementation differs:
// this ArkTS/Go app uses uTLS, while upstream uses Dart HttpClient. This is a
// runtime choice, not evidence that HarmonyOS cannot support another TLS stack.
const (
	maxFetchBytes   = 8 * 1024 * 1024
	downloadTimeout = 20 * time.Second
)

// FetchResult is the JSON payload consumed by the App layer.
type FetchResult struct {
	Status     int               `json:"status"`
	Body       string            `json:"body"`
	ETag       string            `json:"etag"`
	UserInfo   string            `json:"userInfo"`
	Dispos     string            `json:"disposition"`
	ContentTyp string            `json:"contentType"`
	Headers    map[string]string `json:"-"`
}

var errFetchRedirect = errors.New("stopped after 5 redirects")

// testRootCAs lets the isolated test CA (httptest self-signed) be trusted in
// tests only. Production leaves it nil so system roots apply and certificate
// failures remain failures. Tests must restore it via defer.
var testRootCAs *x509.CertPool

func Fetch(rawURL, userAgent, authHeader string, timeout time.Duration) (FetchResult, error) {
	return fetchWithProxy(rawURL, userAgent, authHeader, timeout, "", false)
}

// FetchWithProxy delegates subscription downloads to the local mixed-port
// listener when the app reports that the core is running.
//
// The C/NAPI caller supplies the ready mixed-port; disconnected calls use DIRECT.
func FetchWithProxy(rawURL, userAgent, authHeader string, timeout time.Duration, proxyURL string, useProxy bool) (FetchResult, error) {
	return fetchWithProxy(rawURL, userAgent, authHeader, timeout, proxyURL, useProxy)
}

func fetchWithProxy(rawURL, userAgent, authHeader string, timeout time.Duration, proxyURL string, useProxy bool) (FetchResult, error) {
	var out FetchResult
	if strings.TrimSpace(rawURL) == "" {
		return out, errors.New("empty url")
	}
	if timeout <= 0 {
		timeout = downloadTimeout
	}

	_, _, err := parseFetchTarget(rawURL)
	if err != nil {
		return out, err
	}

	proxy := ""
	if useProxy && proxyURL != "" {
		u, err := url.Parse(proxyURL)
		if err != nil || u.Scheme != "http" || u.Hostname() == "" {
			return out, errors.New("invalid HTTP proxy URL")
		}
		proxy = proxyURL
	}

	tr := newFetchTransport(proxy)
	client := &http.Client{Transport: tr, Timeout: timeout}
	client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		if len(via) > 5 {
			return errFetchRedirect
		}
		// net/http retains Authorization only for the original host or its
		// subdomains. Never re-insert credentials on unrelated redirects.
		return nil
	}

	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return out, err
	}
	ua := strings.TrimSpace(userAgent)
	if ua == "" {
		ua = "TunBox/v0 clash-verge Platform/OpenHarmony"
	}
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Accept", "*/*")
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}

	resp, err := client.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()

	out.Status = resp.StatusCode
	out.ETag = resp.Header.Get("ETag")
	out.UserInfo = resp.Header.Get("Subscription-Userinfo")
	out.Dispos = resp.Header.Get("Content-Disposition")
	out.ContentTyp = resp.Header.Get("Content-Type")
	out.Headers = make(map[string]string, len(resp.Header))
	for k, v := range resp.Header {
		if len(v) > 0 {
			out.Headers[k] = v[0]
		}
	}

	body, readErr := io.ReadAll(io.LimitReader(resp.Body, maxFetchBytes+1))
	if readErr != nil {
		return out, readErr
	}
	body = applyContentEncoding(body, resp.Header.Get("Content-Encoding"))
	if len(body) > maxFetchBytes {
		return out, fmt.Errorf("response exceeds %d byte limit", maxFetchBytes)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return out, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	out.Body = string(body)
	return out, nil
}

func parseFetchTarget(rawURL string) (string, string, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", "", err
	}
	if u.Host == "" {
		return "", "", fmt.Errorf("empty host in url")
	}
	return u.Host, u.Host, nil
}

func newFetchTransport(proxyURL string) http.RoundTripper {
	dialer := &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second}
	base := &http.Transport{
		Proxy:                 nil,
		DialContext:           dialer.DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}
	if proxyURL != "" {
		if u, err := url.Parse(proxyURL); err == nil {
			base.Proxy = http.ProxyURL(u)
		}
	}
	return &browserTransport{base: base, dialer: dialer, proxyURL: proxyURL}
}

// browserTransport preserves Go's ordinary HTTP/1.1 and HTTP/2 negotiation
// while using a Chrome-like UTLS ClientHello for TLS connections.
type browserTransport struct {
	base     *http.Transport
	dialer   *net.Dialer
	proxyURL string
}

func (t *browserTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Scheme != "https" {
		return t.base.RoundTrip(req)
	}
	return t.roundTripTLS(req)
}

// Dispatch on the negotiated ALPN using the same connection. Both protocols
// must use CONNECT when a proxy is selected; a TLS probe must never bypass it.
func (t *browserTransport) roundTripTLS(req *http.Request) (*http.Response, error) {
	host := req.URL.Hostname()
	addr := req.URL.Host
	if _, _, err := net.SplitHostPort(addr); err != nil {
		addr = net.JoinHostPort(addr, "443")
	}
	conn, err := t.dialUTLS(req.Context(), "tcp", addr, host)
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(req.Context(), func() { _ = conn.Close() })
	var resp *http.Response
	if conn.ConnectionState().NegotiatedProtocol == "h2" {
		transport := &http2.Transport{}
		var client *http2.ClientConn
		client, err = transport.NewClientConn(conn)
		if err == nil {
			resp, err = client.RoundTrip(req)
		}
	} else {
		direct := req.Clone(req.Context())
		direct.Close = true
		if err = direct.Write(conn); err == nil {
			resp, err = http.ReadResponse(bufio.NewReader(conn), direct)
		}
	}
	if err != nil {
		stop()
		_ = conn.Close()
		return nil, err
	}
	resp.Body = &fetchBody{ReadCloser: resp.Body, conn: conn, stop: stop}
	return resp, nil
}

type fetchBody struct {
	io.ReadCloser
	conn net.Conn
	stop func() bool
}

func (b *fetchBody) Close() error {
	b.stop()
	err := b.ReadCloser.Close()
	_ = b.conn.Close()
	return err
}

func (t *browserTransport) dialUTLS(ctx context.Context, network, addr, host string) (*utls.UConn, error) {
	dialAddr := addr
	var proxy *url.URL
	if t.proxyURL != "" {
		proxy, _ = url.Parse(t.proxyURL) // validated by fetchWithProxy
		dialAddr = proxy.Host
		if proxy.Port() == "" {
			dialAddr = net.JoinHostPort(proxy.Hostname(), "80")
		}
	}
	raw, err := t.dialer.DialContext(ctx, network, dialAddr)
	if err != nil {
		return nil, err
	}
	stop := context.AfterFunc(ctx, func() { _ = raw.Close() })
	defer stop()
	if deadline, ok := ctx.Deadline(); ok {
		_ = raw.SetDeadline(deadline)
	}
	if proxy != nil {
		connect := &http.Request{Method: http.MethodConnect, URL: &url.URL{Opaque: addr}, Host: addr, Header: make(http.Header)}
		if proxy.User != nil {
			password, _ := proxy.User.Password()
			credentials := proxy.User.Username() + ":" + password
			connect.Header.Set("Proxy-Authorization", "Basic "+base64.StdEncoding.EncodeToString([]byte(credentials)))
		}
		if err := connect.Write(raw); err != nil {
			_ = raw.Close()
			return nil, err
		}
		response, err := http.ReadResponse(bufio.NewReader(raw), connect)
		if err != nil {
			_ = raw.Close()
			return nil, err
		}
		if response.StatusCode != http.StatusOK {
			_ = raw.Close()
			return nil, fmt.Errorf("proxy CONNECT HTTP %d", response.StatusCode)
		}
	}
	u := utls.UClient(raw, &utls.Config{ServerName: host, RootCAs: testRootCAs, NextProtos: []string{"h2", "http/1.1"}}, utls.HelloChrome_Auto)
	if err := u.HandshakeContext(ctx); err != nil {
		_ = raw.Close()
		return nil, err
	}
	return u, nil
}

// applyContentEncoding follows FlClash's decompressUnlabeled behavior for
// gzip/zlib bodies that arrive without validation status.
func applyContentEncoding(body []byte, encoding string) []byte {
	enc := strings.TrimSpace(strings.ToLower(encoding))
	switch enc {
	case "gzip":
		r, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return body
		}
		defer r.Close()
		if out, err := io.ReadAll(io.LimitReader(r, maxFetchBytes+1)); err == nil {
			return out
		}
	case "deflate":
		r, err := zlib.NewReader(bytes.NewReader(body))
		if err != nil {
			return body
		}
		defer r.Close()
		if out, err := io.ReadAll(io.LimitReader(r, maxFetchBytes+1)); err == nil {
			return out
		}
	default:
		// Some panels return compressed subscriptions without the header.
		if len(body) >= 2 && body[0] == 0x1f && body[1] == 0x8b {
			return applyContentEncoding(body, "gzip")
		}
		if len(body) >= 2 && ((int(body[0])<<8)|int(body[1]))%31 == 0 {
			return applyContentEncoding(body, "deflate")
		}
		_ = mime.TypeByExtension
	}
	return body
}
