package route

import (
	"context"
	"encoding/json"
	"net/url"
	"strings"
	"testing"

	"github.com/metacubex/http/httptest"
	"github.com/metacubex/mihomo/common/utils"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

type delayFixtureProxy struct {
	C.Proxy
	name  string
	delay uint16
}

func (p *delayFixtureProxy) Name() string { return p.name }
func (p *delayFixtureProxy) MarshalJSON() ([]byte, error) {
	return json.Marshal(map[string]string{"name": p.name, "type": "Direct"})
}
func (p *delayFixtureProxy) URLTest(context.Context, string, utils.IntRanges[uint16]) (uint16, error) {
	return p.delay, nil
}

type delayFixtureProvider struct {
	P.ProxyProvider
	nodes []C.Proxy
}

func (p *delayFixtureProvider) Proxies() []C.Proxy { return p.nodes }

func TestProviderDelayCatalog(t *testing.T) {
	oldProxies, oldProviders := tunnel.Proxies(), tunnel.Providers()
	defer tunnel.UpdateProxies(oldProxies, oldProviders)
	name := "🇯🇵 日本 provider / 01"
	p := &delayFixtureProxy{name: name, delay: 42}
	provider := &delayFixtureProvider{nodes: []C.Proxy{p}}
	tunnel.UpdateProxies(map[string]C.Proxy{}, map[string]P.ProxyProvider{"airport": provider})
	router := proxyRouter()
	probe := func(name string, code int, body string) {
		t.Helper()
		w := httptest.NewRecorder()
		router.ServeHTTP(w, httptest.NewRequest("GET", "/"+url.PathEscape(name)+"/delay?timeout=8000&url=https%3A%2F%2Fexample.com", nil))
		if w.Code != code || !strings.Contains(w.Body.String(), body) {
			t.Fatalf("delay %q: %d %s", name, w.Code, w.Body.String())
		}
	}
	probe(name, 200, `"delay":42`)
	w := httptest.NewRecorder()
	router.ServeHTTP(w, httptest.NewRequest("GET", "/", nil))
	var catalog struct {
		Proxies map[string]json.RawMessage `json:"proxies"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &catalog); err != nil || catalog.Proxies[name] == nil {
		t.Fatalf("provider missing from catalog: %s (%v)", w.Body.String(), err)
	}
	if _, injected := tunnel.Proxies()[name]; injected {
		t.Fatal("controller mutated forwarding map")
	}
	// Provider refresh must be reflected immediately, not cached under a dead name.
	provider.nodes = []C.Proxy{&delayFixtureProxy{name: "replacement", delay: 17}}
	probe(name, 404, "not found")
	probe("replacement", 200, `"delay":17`)
	// Static names win, then alphabetically first provider; repeated reads are stable.
	provider.nodes = []C.Proxy{p}
	static := &delayFixtureProxy{name: name, delay: 8}
	tunnel.UpdateProxies(map[string]C.Proxy{name: static}, map[string]P.ProxyProvider{"airport": provider})
	probe(name, 200, `"delay":8`)
	tunnel.UpdateProxies(map[string]C.Proxy{}, map[string]P.ProxyProvider{
		"z": provider, "a": &delayFixtureProvider{nodes: []C.Proxy{static}},
	})
	for i := 0; i < 20; i++ {
		probe(name, 200, `"delay":8`)
	}
}
