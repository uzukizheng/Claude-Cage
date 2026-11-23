package cage

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"testing"

	"github.com/miekg/dns"
	"github.com/sylvinus/agent-vm/internal/managedproxy"
)

type clashXTestDialer struct {
	http, dns string
}

func (d clashXTestDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	switch {
	case network == "tcp" && address == "127.0.0.1:7890":
		address = d.http
	case network == "udp" && address == "127.0.0.1:1053":
		address = d.dns
	default:
		return nil, errors.New("unexpected destination")
	}
	return (&net.Dialer{}).DialContext(ctx, network, address)
}

func TestHostClashXDNSAndGate(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ProxyURL = managedproxy.HostClashXURL
	g, err := NewEgressGate(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { g.Close("test complete") })
	listener, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ready := make(chan struct{})
	server := &dns.Server{PacketConn: listener, NotifyStartedFunc: func() { close(ready) }, Handler: dns.HandlerFunc(func(w dns.ResponseWriter, r *dns.Msg) {
		reply := new(dns.Msg).SetReply(r)
		reply.Answer = []dns.RR{&dns.A{Hdr: dns.RR_Header{Name: r.Question[0].Name, Rrtype: dns.TypeA, Class: dns.ClassINET, Ttl: 60}, A: net.IPv4(1, 1, 1, 1)}}
		_ = w.WriteMsg(reply)
	})}
	go server.ActivateAndServe()
	<-ready
	t.Cleanup(func() { _ = server.Shutdown() })
	g.raw.connect = clashXTestDialer{dns: listener.LocalAddr().String()}
	q := new(dns.Msg).SetQuestion("example.com.", dns.TypeA)
	if _, err := g.ExchangeDNS(t.Context(), q); !errors.Is(err, ErrGateClosed) {
		t.Fatalf("closed gate: %v", err)
	}
	fixtureGrant(t, g)
	r, err := g.ExchangeDNS(t.Context(), q)
	if err != nil || len(r.Answer) != 1 {
		t.Fatalf("ClashX DNS: %v %v", r, err)
	}
	if g.Allows("tcp", netip.MustParseAddrPort("127.0.0.1:7890")) {
		t.Fatal("guest can dial the host proxy")
	}
	if _, err := g.failedDiagnostic.ExchangeDNS(t.Context(), q); err == nil {
		t.Fatal("faulted transport answered DNS")
	}
}

func TestClashXPrivateNetworks(t *testing.T) {
	cfg := DefaultConfig()
	cfg.ProxyURL = managedproxy.HostClashXURL
	e, err := NewEgress(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, dst := range []string{
		"10.0.0.1:1", "10.88.196.59:22", "10.255.255.254:65535",
		"172.16.0.0:22", "172.31.255.255:65535",
		"192.168.0.1:80", "192.168.255.254:443",
	} {
		if !e.Allows("tcp", netip.MustParseAddrPort(dst)) {
			t.Fatalf("expected private TCP grant: %s", dst)
		}
	}
	for _, dst := range []string{"100.64.0.1:22", "127.0.0.1:7890", "169.254.169.254:80"} {
		if e.Allows("tcp", netip.MustParseAddrPort(dst)) {
			t.Fatalf("unexpected grant: %s", dst)
		}
	}
	if e.Allows("udp", netip.MustParseAddrPort("10.88.196.59:22")) {
		t.Fatal("allowed UDP")
	}
	if e.Allows("udp", netip.MustParseAddrPort("172.16.0.1:443")) {
		t.Fatal("allowed UDP for 172.16.0.0/12")
	}

	cfg.ProxyURL = "http://127.0.0.1:17896"
	other, err := NewEgress(cfg)
	if err != nil {
		t.Fatal(err)
	}
	for _, dst := range []string{"10.88.196.59:22", "172.16.0.1:443", "192.168.0.1:80"} {
		if other.Allows("tcp", netip.MustParseAddrPort(dst)) {
			t.Fatalf("allowed without the selected ClashX transport: %s", dst)
		}
	}
}
