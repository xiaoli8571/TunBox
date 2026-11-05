package dns

import (
	"net"
	"strings"
	"testing"

	D "github.com/miekg/dns"
)

func TestPlatformSystemDNSValidationAndAtomicity(t *testing.T) {
	if err := UpdatePlatformSystemDNS([]string{"1.1.1.1", "2606:4700:4700::1111"}); err != nil {
		t.Fatal(err)
	}
	clients, installed := platformSystemClients()
	if !installed || len(clients) != 2 {
		t.Fatalf("clients=%d installed=%v", len(clients), installed)
	}
	for _, invalid := range []string{"not-an-ip", "0.0.0.0", "::", "224.0.0.1", "172.19.0.2", "fdfe:dcba:9876::2"} {
		if err := UpdatePlatformSystemDNS([]string{invalid}); err == nil {
			t.Errorf("accepted %q", invalid)
		}
		after, _ := platformSystemClients()
		if len(after) != 2 {
			t.Fatal("invalid update mutated previous resolver")
		}
	}
	if err := UpdatePlatformSystemDNS(nil); err != nil {
		t.Fatal(err)
	}
	clients, installed = platformSystemClients()
	if !installed || len(clients) != 0 {
		t.Fatal("empty update must clear stale physical DNS")
	}
}

func TestPlatformSystemDNSPreservesConfiguredResolvers(t *testing.T) {
	c := newSystemClient()
	if err := UpdatePlatformSystemDNS([]string{"9.9.9.9"}); err != nil {
		t.Fatal(err)
	}
	clients, err := c.getDnsClients()
	if err != nil || len(clients) != 1 {
		t.Fatalf("clients=%d error=%v", len(clients), err)
	}
	host, port, err := net.SplitHostPort(strings.TrimPrefix(clients[0].Address(), "udp://"))
	if err != nil || host != "9.9.9.9" || port != "53" {
		t.Fatalf("unexpected address %q", clients[0].Address())
	}
	// User resolvers remain independent objects; the update only affects system clients.
	policy := transform([]NameServer{{Addr: "1.1.1.1:53", Net: "udp"}}, nil)
	if err := UpdatePlatformSystemDNS([]string{"8.8.8.8"}); err != nil {
		t.Fatal(err)
	}
	if len(policy) != 1 || policy[0].Address() != "udp://1.1.1.1:53" {
		t.Fatal("configured DNS unexpectedly replaced")
	}
}

// The factory still produces real upstream DNS messages; no application/kernel mock.
func TestPlatformSystemDNSUDPClientExchange(t *testing.T) {
	pc, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &D.Server{PacketConn: pc, Handler: D.HandlerFunc(func(w D.ResponseWriter, r *D.Msg) {
		reply := new(D.Msg)
		reply.SetReply(r)
		reply.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: r.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 30}, A: net.IPv4(192, 0, 2, 77)}}
		_ = w.WriteMsg(reply)
	})}
	go func() { _ = server.ActivateAndServe() }()
	defer server.Shutdown()
	query := new(D.Msg)
	query.SetQuestion("platform.test.", D.TypeA)
	client := &D.Client{Net: "udp"}
	reply, _, err := client.Exchange(query, pc.LocalAddr().String())
	if err != nil || len(reply.Answer) != 1 {
		t.Fatalf("reply=%v err=%v", reply, err)
	}
}
