package main

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	relay "quietdesk/relay"
	"strings"
	"syscall"
	"time"
)

func main() {
	listen := flag.String("listen", ":443", "service TCP and UDP address")
	certificate := flag.String("cert", "", "server certificate chain PEM path")
	privateKey := flag.String("key", "", "server private key PEM path")
	accessFile := flag.String("access-key-file", "", "private file containing a 256-bit hexadecimal service access key")
	state := flag.String("state", "relay-state/state.json", "private durable device ownership state")
	health := flag.String("health", "127.0.0.1:9091", "loopback HTTP health address; empty disables")
	maxConnections := flag.Int("max-connections", 1024, "technical socket resource bound")
	maxDevices := flag.Int("max-devices", 4096, "technical durable ownership registry bound")
	flag.Parse()
	if err := run(*listen, *certificate, *privateKey, *accessFile, *state, *health, *maxConnections, *maxDevices); err != nil {
		fmt.Fprintln(os.Stderr, "Relay stopped:", err)
		os.Exit(1)
	}
}

func run(address, certificate, privateKey, accessFile, state, health string, maxConnections, maxDevices int) error {
	if certificate == "" || privateKey == "" || accessFile == "" || state == "" {
		return fmt.Errorf("cert, key, access-key-file and state are required")
	}
	data, err := relay.ReadPrivateFile(accessFile, 128)
	if err != nil {
		return fmt.Errorf("cannot read access key file")
	}
	access, err := hex.DecodeString(strings.TrimSpace(string(data)))
	if err != nil || len(access) != 32 {
		return fmt.Errorf("access key file must contain 64 hexadecimal characters")
	}
	identity, err := tls.LoadX509KeyPair(certificate, privateKey)
	if err != nil {
		return fmt.Errorf("cannot load server certificate/key: %w", err)
	}
	server, err := relay.NewServer(relay.Config{AccessKey: access, StatePath: state, MaxConnections: maxConnections, MaxDevices: maxDevices})
	if err != nil {
		return err
	}
	defer server.Close()
	listener, err := tls.Listen("tcp", address, &tls.Config{Certificates: []tls.Certificate{identity}, MinVersion: tls.VersionTLS12})
	if err != nil {
		return err
	}
	defer listener.Close()
	udp, err := net.ListenPacket("udp", listener.Addr().String())
	if err != nil {
		return err
	}
	defer udp.Close()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var healthServer *http.Server
	if health != "" {
		host, _, err := net.SplitHostPort(health)
		if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
			return fmt.Errorf("health endpoint must bind a loopback IP")
		}
		mux := http.NewServeMux()
		mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(server.Snapshot())
		})
		healthServer = &http.Server{Addr: health, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
		healthListener, err := net.Listen("tcp", health)
		if err != nil {
			return fmt.Errorf("cannot bind health endpoint: %w", err)
		}
		go func() {
			if err := healthServer.Serve(healthListener); err != nil && err != http.ErrServerClosed {
				server.Close()
			}
		}()
		defer healthServer.Close()
	}
	go func() { <-ctx.Done(); server.Close() }()
	fmt.Fprintln(os.Stdout, "QuietDesk relay listening on", listener.Addr())
	return server.Serve(listener, udp)
}
