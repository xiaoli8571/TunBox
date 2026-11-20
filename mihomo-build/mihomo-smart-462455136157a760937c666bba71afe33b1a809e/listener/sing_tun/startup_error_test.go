package sing_tun

import (
	"testing"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	LC "github.com/metacubex/mihomo/listener/config"
)

// No tunnel method or OS device is reached before the conflicting route options
// are rejected. Nil embedded methods fail the test if that boundary changes.
type startupProviderTunnel = P.Tunnel

type startupErrorTunnel struct {
	C.Tunnel
	startupProviderTunnel
}

func TestAutoRedirectWithoutAutoRouteReturnsError(t *testing.T) {
	if !supportRedirect {
		t.Skip("requires the Linux/OHOS auto-redirect implementation")
	}
	listener, err := New(LC.Tun{
		Enable: true, Device: "tunbox-fixture",
		AutoRedirect: true, AutoRoute: false, AutoDetectInterface: false,
	}, startupErrorTunnel{})
	if listener != nil {
		_ = listener.Close()
		t.Fatal("invalid route options returned a listener")
	}
	if err == nil || err.Error() != "`auto-route` is required by `auto-redirect`" {
		t.Fatalf("expected original configuration error, got %v", err)
	}
}
