package main

import (
	"bytes"
	"context"
	"io"
	"net"
	"testing"
	"time"
)

func TestBridgeTCPHalfCloseAndRevoke(t *testing.T) {
	tcp, udp, _, err := listenLoopback()
	if err != nil {
		t.Fatal(err)
	}
	dest, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dest.Close()
	var d net.Dialer
	b := startBridge(tcp, udp, func(ctx context.Context, network string) (net.Conn, error) {
		return d.DialContext(ctx, network, dest.Addr().String())
	})
	t.Cleanup(b.close)
	client, err := net.Dial("tcp4", tcp.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	server, err := dest.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	server.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := client.Write([]byte("request")); err != nil {
		t.Fatal(err)
	}
	if err := client.(*net.TCPConn).CloseWrite(); err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(server)
	if err != nil || string(got) != "request" {
		t.Fatalf("request: %q %v", got, err)
	}
	if _, err := server.Write([]byte("reply")); err != nil {
		t.Fatal(err)
	}
	got = make([]byte, 5)
	if _, err := io.ReadFull(client, got); err != nil || string(got) != "reply" {
		t.Fatalf("reply: %q %v", got, err)
	}
	b.close()
	if _, err := client.Read(got); err == nil {
		t.Fatal("live client after unshare")
	}
}

func TestBridgeUDPKeepsSourcesSeparate(t *testing.T) {
	tcp, udp, _, err := listenLoopback()
	if err != nil {
		t.Fatal(err)
	}
	dest, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer dest.Close()
	var d net.Dialer
	b := startBridge(tcp, udp, func(ctx context.Context, network string) (net.Conn, error) {
		return d.DialContext(ctx, network, dest.LocalAddr().String())
	})
	defer b.close()
	dest.SetDeadline(time.Now().Add(5 * time.Second))
	received := make(map[byte]net.Addr)
	clients := make([]net.Conn, 2)
	for i := range clients {
		client, err := net.Dial("udp4", udp.LocalAddr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer client.Close()
		client.SetDeadline(time.Now().Add(5 * time.Second))
		clients[i] = client
		if _, err := client.Write([]byte{byte(i)}); err != nil {
			t.Fatal(err)
		}
	}
	var data [2]byte
	for range clients {
		n, addr, err := dest.ReadFrom(data[:])
		if err != nil || n != 1 {
			t.Fatalf("read: %d %v", n, err)
		}
		received[data[0]] = addr
	}
	if received[0].String() == received[1].String() {
		t.Fatal("UDP flows shared a source")
	}
	for i := range clients {
		if _, err := dest.WriteTo([]byte{byte(i)}, received[byte(i)]); err != nil {
			t.Fatal(err)
		}
	}
	for i, client := range clients {
		n, err := client.Read(data[:])
		if err != nil || n != 1 || data[0] != byte(i) {
			t.Fatalf("client %d received %x: %v", i, data[:n], err)
		}
	}
}

func TestPrivateControlRepliesToEachRequest(t *testing.T) {
	in := bytes.NewBufferString("{\"id\":1,\"op\":\"close\",\"port\":42}\n{\"id\":2,\"port\":70000}\n")
	var out bytes.Buffer
	serve(in, &out, func(req request) (response, error) {
		if req.Op != "close" || req.Port != 42 {
			t.Fatalf("unexpected command: %+v", req)
		}
		return response{}, nil
	})
	want := "{\"id\":1}\n{\"id\":2,\"error\":\"请求格式无效\"}\n"
	if got := out.String(); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestWithdrawingUDPClosesAnEstablishedMapping(t *testing.T) {
	tcp, udp, port, err := listenLoopback()
	if err != nil {
		t.Fatal(err)
	}
	upstream, backend := net.Pipe()
	defer backend.Close()
	h := helper{port: port, sharedTCP: startBridge(tcp, nil, nil),
		sharedUDP: startBridge(nil, udp, func(context.Context, string) (net.Conn, error) { return upstream, nil })}
	defer h.stopSharing()
	client, err := net.Dial("udp4", udp.LocalAddr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	backend.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := client.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	var packet [1]byte
	if _, err := io.ReadFull(backend, packet[:]); err != nil {
		t.Fatal(err)
	}
	if err := h.share(context.Background(), port, false); err != nil {
		t.Fatal(err)
	}
	if _, err := backend.Read(packet[:]); err != io.EOF {
		t.Fatalf("backend mapping remained active: %v", err)
	}
}
