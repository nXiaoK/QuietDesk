package main

import (
	"io"
	"net"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"tailscale.com/envknob"
	"tailscale.com/tsnet"
	"tailscale.com/tstest/integration"
	"tailscale.com/tstest/integration/testcontrol"
	"tailscale.com/types/logger"
)

// Both nodes use a private test coordinator and DERP server. Forcing DERP
// exercises the desktop transport when a peer-to-peer UDP path is unavailable.
func TestPairedNodesUseRelayedTailnet(t *testing.T) {
	envknob.SetenvForTest(t, "TS_DISABLE_PORTMAPPER", "true")
	envknob.SetenvForTest(t, "TS_DEBUG_ALWAYS_USE_DERP", "true")
	control := &testcontrol.Server{
		RequireAuth: true,
		DERPMap:     integration.RunDERPAndSTUN(t, logger.Discard, "127.0.0.1"),
	}
	control.HTTPTestServer = httptest.NewServer(control)
	t.Cleanup(control.HTTPTestServer.Close)
	node := func(name string) (*helper, string) {
		t.Helper()
		s := &tsnet.Server{Hostname: name, ControlURL: control.HTTPTestServer.URL,
			Dir: t.TempDir(), UserLogf: logger.Discard, Logf: logger.Discard}
		h := &helper{server: s}
		t.Cleanup(func() { h.closeRoutes(); s.Close() })
		r, err := h.handle(request{Op: "login"})
		if err != nil {
			t.Fatal(err)
		}
		approved := false
		for deadline := time.Now().Add(30 * time.Second); time.Now().Before(deadline); {
			if !approved && r.AuthURL != "" {
				if !control.CompleteAuth(r.AuthURL) {
					t.Fatal("test coordinator rejected interactive login")
				}
				approved = true
			}
			if approved && r.State == "Running" && r.IP != "" {
				return h, r.IP
			}
			time.Sleep(50 * time.Millisecond)
			r, err = h.handle(request{Op: "status"})
			if err != nil {
				t.Fatal(err)
			}
		}
		t.Fatalf("test node failed to join: state %s, approved %t", r.State, approved)
		return nil, ""
	}
	host, hostIP := node("quietdesk-host")
	viewer, _ := node("quietdesk-viewer")
	tcp, udp, port, err := listenLoopback()
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	defer udp.Close()
	if _, err := host.handle(request{Op: "share", Port: port}); err != nil {
		t.Fatal(err)
	}
	go func() {
		conn, err := tcp.Accept()
		if err == nil {
			defer conn.Close()
			io.Copy(conn, conn)
		}
	}()
	go func() {
		buf := make([]byte, 1500)
		for {
			n, src, err := udp.ReadFrom(buf)
			if err != nil {
				return
			}
			udp.WriteTo(buf[:n], src)
		}
	}()
	var route response
	for deadline := time.Now().Add(15 * time.Second); time.Now().Before(deadline); {
		route, err = viewer.handle(request{Op: "open", Host: hostIP, Port: port})
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	dest := net.JoinHostPort("127.0.0.1", strconv.Itoa(int(route.Port)))
	tcpClient, err := net.DialTimeout("tcp", dest, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer tcpClient.Close()
	roundTrip := func(conn net.Conn, msg string) {
		t.Helper()
		conn.SetDeadline(time.Now().Add(10 * time.Second))
		if _, err := io.WriteString(conn, msg); err != nil {
			t.Fatal(err)
		}
		got := make([]byte, len(msg))
		if _, err := io.ReadFull(conn, got); err != nil || string(got) != msg {
			t.Fatalf("round trip through both nodes: %q, %v", got, err)
		}
	}
	roundTrip(tcpClient, "paired control")
	if _, err := host.handle(request{Op: "share", Port: port, UDP: true}); err != nil {
		t.Fatal(err)
	}
	udpClient, err := net.DialTimeout("udp", dest, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer udpClient.Close()
	roundTrip(udpClient, "datagram")
	for _, node := range []*helper{viewer, host} {
		status, err := node.handle(request{Op: "status"})
		if err != nil {
			t.Fatal(err)
		}
		if status.PeerPath != "derp" {
			t.Fatalf("embedded node reported path %q and region %q with forced DERP", status.PeerPath, status.PeerRelay)
		}
		if node == viewer && status.BridgeRoutes[route.Port].Path != "derp" {
			t.Fatalf("viewer bridge did not report its observed DERP route: %+v", status.BridgeRoutes)
		}
	}
	if _, err := host.handle(request{Op: "share", Port: port}); err != nil {
		t.Fatal(err)
	}
	roundTrip(tcpClient, "control after UDP closed")
	udpClient.SetDeadline(time.Now().Add(400 * time.Millisecond))
	if _, err := io.WriteString(udpClient, "after revoke"); err != nil {
		t.Fatal(err)
	}
	if n, err := udpClient.Read(make([]byte, 100)); n != 0 || err == nil {
		t.Fatal("a disabled tailnet UDP route still forwarded a datagram")
	}
	if _, err := host.handle(request{Op: "share"}); err != nil {
		t.Fatal(err)
	}
	if _, err := viewer.handle(request{Op: "close", Port: route.Port}); err != nil {
		t.Fatal(err)
	}
	if status, err := viewer.handle(request{Op: "status"}); err != nil || status.PeerPath != "" || status.PeerRelay != "" || len(status.BridgeRoutes) != 0 {
		t.Fatalf("closed route returned a peer path: %+v, %v", status, err)
	}
}
