package main

import (
	"context"
	"io"
	"net"
	"sync"
	"time"
)

type dialFunc func(context.Context, string) (net.Conn, error)

const (
	maxFlows    = 128
	dialTimeout = 10 * time.Second
	udpIdle     = 90 * time.Second
)

type bridge struct {
	ctx     context.Context
	cancel  context.CancelFunc
	tcp     net.Listener
	udp     net.PacketConn
	dial    dialFunc
	workers sync.WaitGroup
}

func startBridge(tcp net.Listener, udp net.PacketConn, dial dialFunc) *bridge {
	ctx, cancel := context.WithCancel(context.Background())
	b := &bridge{ctx: ctx, cancel: cancel, tcp: tcp, udp: udp, dial: dial}
	if tcp != nil {
		b.workers.Go(b.serveTCP)
	}
	if udp != nil {
		b.workers.Go(b.serveUDP)
	}
	return b
}

func (b *bridge) close() {
	b.cancel()
	if b.tcp != nil {
		b.tcp.Close()
	}
	if b.udp != nil {
		b.udp.Close()
	}
	b.workers.Wait()
}

func (b *bridge) connect(network string) (net.Conn, error) {
	ctx, cancel := context.WithTimeout(b.ctx, dialTimeout)
	defer cancel()
	return b.dial(ctx, network)
}

func (b *bridge) serveTCP() {
	slots := make(chan struct{}, maxFlows)
	for {
		client, err := b.tcp.Accept()
		if err != nil {
			return
		}
		select {
		case slots <- struct{}{}:
			b.workers.Go(func() {
				defer func() { <-slots }()
				defer client.Close()
				dest, err := b.connect("tcp")
				if err != nil {
					return
				}
				defer dest.Close()
				stop := context.AfterFunc(b.ctx, func() {
					client.Close()
					dest.Close()
				})
				defer stop()
				var copyBack sync.WaitGroup
				copyBack.Go(func() { copyStream(client, dest) })
				copyStream(dest, client)
				copyBack.Wait()
			})
		default:
			client.Close()
		}
	}
}

func copyStream(dst, src net.Conn) {
	_, err := io.Copy(dst, src)
	if half, ok := dst.(interface{ CloseWrite() error }); err == nil && ok {
		half.CloseWrite()
		return
	}
	src.Close()
	dst.Close()
}

func (b *bridge) serveUDP() {
	var mu sync.Mutex
	flows := make(map[string]net.Conn)
	defer func() {
		mu.Lock()
		defer mu.Unlock()
		for _, conn := range flows {
			conn.Close()
		}
	}()
	buf := make([]byte, 65535)
	for {
		n, client, err := b.udp.ReadFrom(buf)
		if err != nil {
			return
		}
		key := client.String()
		mu.Lock()
		conn := flows[key]
		full := len(flows) >= maxFlows
		mu.Unlock()
		if conn == nil {
			if full {
				continue
			}
			conn, err = b.connect("udp")
			if err != nil {
				continue
			}
			mu.Lock()
			flows[key] = conn
			mu.Unlock()
			b.workers.Go(func() {
				defer func() {
					conn.Close()
					mu.Lock()
					delete(flows, key)
					mu.Unlock()
				}()
				reply := make([]byte, 65535)
				for {
					conn.SetReadDeadline(time.Now().Add(udpIdle))
					n, err := conn.Read(reply)
					if err != nil {
						return
					}
					if _, err = b.udp.WriteTo(reply[:n], client); err != nil {
						return
					}
				}
			})
		}
		conn.SetReadDeadline(time.Now().Add(udpIdle))
		conn.SetWriteDeadline(time.Now().Add(time.Second))
		if _, err := conn.Write(buf[:n]); err != nil {
			conn.Close()
		}
	}
}
