package outboundgroup

import (
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

func TestSmartValidationOwnsNoRuntimeResources(t *testing.T) {
	proxies := map[string]C.Proxy{"DIRECT": adapter.NewProxy(outbound.NewDirect()), "COMPATIBLE": adapter.NewProxy(outbound.NewCompatible())}
	group, err := ParseProxyGroupForValidation(map[string]any{
		"name": "real-smart", "type": "smart", "proxies": []string{"DIRECT"},
		"uselightgbm": true, "collectdata": true, "prefer-asn": true,
	}, proxies, map[string]P.ProxyProvider{}, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	s, ok := group.(*Smart)
	if !ok || s.Type() != C.Smart || !s.useLightGBM || !s.collectData || !s.preferASN {
		t.Fatal("validation did not decode the real Smart policy")
	}
	if s.store != nil || s.ctx != nil || s.cancel != nil || s.weightModel != nil || s.dataCollector != nil || s.exitWatch != nil {
		t.Fatal("validation initialized Smart runtime resources")
	}
	// An uninitialized group must also be safe to discard without touching the
	// running process's global collector/store lifecycle.
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
}
