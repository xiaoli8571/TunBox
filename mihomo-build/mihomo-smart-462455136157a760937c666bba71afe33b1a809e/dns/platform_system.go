package dns

import (
	"fmt"
	"net"
	"net/netip"
	"sync"
)

// Platform-supplied physical DNS bypasses resolv.conf (which may point at the VPN).
// It only changes the system:// client, never replaces configured DoH/DoT policies.
var platformDNS struct {
	sync.RWMutex
	installed bool
	clients   []dnsClient
}

func UpdatePlatformSystemDNS(addresses []string) error {
	servers := make([]NameServer, 0, len(addresses))
	for _, raw := range addresses {
		address, err := netip.ParseAddr(raw)
		if err != nil || address.IsUnspecified() || address.IsMulticast() {
			return fmt.Errorf("invalid physical DNS address")
		}
		if address.String() == "172.19.0.2" || address.String() == "fdfe:dcba:9876::2" {
			return fmt.Errorf("VPN sentinel is not a physical DNS server")
		}
		servers = append(servers, NameServer{Addr: net.JoinHostPort(address.String(), "53"), Net: "udp"})
	}
	clients := transform(servers, nil)
	platformDNS.Lock()
	previous := platformDNS.clients
	platformDNS.clients = clients
	platformDNS.installed = true
	platformDNS.Unlock()
	for _, client := range previous {
		client.ResetConnection()
	}
	return nil
}

func platformSystemClients() ([]dnsClient, bool) {
	platformDNS.RLock()
	defer platformDNS.RUnlock()
	return append([]dnsClient(nil), platformDNS.clients...), platformDNS.installed
}
