package main

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	"tailscale.com/ipn/ipnstate"
	"tailscale.com/types/key"
)

func TestOutboundPeerRoutesRequireTheBridgedActivePeer(t *testing.T) {
	status := &ipnstate.Status{Peer: make(map[key.NodePublic]*ipnstate.PeerStatus)}
	outbound := make(map[uint16]outboundRoute)
	add := func(address string, port uint16, peer ipnstate.PeerStatus) {
		ip := netip.MustParseAddr(address)
		peer.TailscaleIPs = []netip.Addr{ip}
		peer.InNetworkMap = true
		peer.InMagicSock = true
		status.Peer[key.NewNode().Public()] = &peer
		outbound[port] = outboundRoute{target: ip}
	}
	add("100.100.0.1", 34001, ipnstate.PeerStatus{Active: true, CurAddr: "192.0.2.1:41641", Relay: "home"})
	add("100.100.0.2", 34002, ipnstate.PeerStatus{Active: true, Relay: "test"})
	add("100.100.0.3", 34003, ipnstate.PeerStatus{Relay: "unused"})
	add("100.100.0.4", 34004, ipnstate.PeerStatus{Active: true, Relay: "home", PeerRelay: "192.0.2.9:41641:vni:1"})
	add("100.100.0.5", 34005, ipnstate.PeerStatus{Active: true})
	outbound[34006] = outboundRoute{target: netip.MustParseAddr("100.100.0.6")}
	got := outboundPeerRoutes(status, outbound)
	if len(got) != 2 || got[34001] != (peerRoute{Path: "direct"}) || got[34002] != (peerRoute{Path: "derp", Relay: "test"}) {
		t.Fatalf("route attribution included an inactive, unsupported, or unrelated peer: %+v", got)
	}
	delete(outbound, 34002)
	if got := outboundPeerRoutes(status, outbound); len(got) != 1 {
		t.Fatalf("a closed bridge remains in status: %+v", got)
	}
}

func TestNormalizedControlURL(t *testing.T) {
	for _, value := range []string{"", "https://headscale.example", "https://headscale.example:8443/tailnet",
		"https://192.0.2.1", "https://[2001:db8::1]:8443", "http://127.0.0.1:8080", "http://localhost:8080"} {
		if got, err := normalizedControlURL("  " + value + "  "); err != nil || got != value {
			t.Errorf("normalize %q: got %q, %v", value, got, err)
		}
	}
	for _, value := range []string{"headscale.example", "https:///headscale", "http://headscale.example", "http://127.0.0.2",
		"https://user:pass@headscale.example", "https://headscale.example/path?flag", "https://headscale.example/#", "https://headscale.example?",
		"https://headscale.example:0", "https://headscale.example:65536", "https://headscale.example:", "https://head_scale.example",
		"https://2001:db8::1", "https://[192.0.2.1]", "https://[fe80::1%25en0]"} {
		if got, err := normalizedControlURL(value); err == nil {
			t.Errorf("accepted %q as %q", value, got)
		}
	}
}

func TestControlStatePreservesSeparateEnrollments(t *testing.T) {
	base := t.TempDir()
	if got := nodeStateDir(base, ""); got != base {
		t.Fatalf("official state moved to %s", got)
	}
	stateFor := func(value string) string {
		t.Helper()
		control, err := normalizedControlURL(value)
		if err != nil {
			t.Fatal(err)
		}
		return nodeStateDir(base, control)
	}
	custom := stateFor("https://headscale.example")
	if filepath.Dir(custom) != base || custom == stateFor("https://other.example") || custom == stateFor("https://headscale.example/other") {
		t.Fatal("custom control services must have separate private state directories")
	}
	if equivalent := stateFor("https://Headscale.Example:443/"); equivalent != custom {
		t.Fatalf("equivalent control URL selected a different state directory: %s", equivalent)
	}
}

func TestPersistedListenPort(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	type result struct {
		port uint16
		err  error
	}
	results := make(chan result, 4)
	for range cap(results) {
		go func() {
			port, err := persistedListenPort(dir)
			results <- result{port, err}
		}()
	}
	first := <-results
	if first.err != nil || first.port < 1024 {
		t.Fatalf("failed to create a high UDP port: %v", first)
	}
	for range cap(results) - 1 {
		if got := <-results; got != first {
			t.Errorf("concurrent start chose %v, want %v", got, first)
		}
	}
	if reopened, err := persistedListenPort(dir); err != nil || reopened != first.port {
		t.Fatalf("reopened state used port %d, %v", reopened, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "wg-port"), []byte("65536\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := persistedListenPort(dir); err == nil {
		t.Fatal("accepted an out-of-range persisted port")
	}
}
