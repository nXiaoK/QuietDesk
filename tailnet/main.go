// QuietDesk's private JSON-lines backend for its embedded Tailscale node.
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"slices"
	"strconv"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/net/tsaddr"
	"tailscale.com/tsnet"
	"tailscale.com/types/logger"
	"tailscale.com/util/dnsname"
)

type request struct {
	ID   int    `json:"id"`
	Op   string `json:"op"`
	Port uint16 `json:"port"`
	Host string `json:"host"`
	UDP  bool   `json:"udp"`
}

type response struct {
	ID      int    `json:"id"`
	State   string `json:"state,omitempty"`
	IP      string `json:"ip,omitempty"`
	AuthURL string `json:"authURL,omitempty"`
	Port    uint16 `json:"port,omitempty"`
	Error   string `json:"error,omitempty"`
	UDP     bool   `json:"udp,omitempty"`
}

type helper struct {
	server    *tsnet.Server
	local     *local.Client
	sharedTCP *bridge
	sharedUDP *bridge
	port      uint16
	boundIP   string
	outbound  map[uint16]*bridge
}

func main() {
	stateDir := flag.String("state-dir", "", "private node state directory")
	flag.Parse()
	if *stateDir == "" || flag.NArg() != 0 {
		os.Exit(2)
	}
	log.SetOutput(io.Discard)
	// Enrollment uses the identity and login explicitly selected inside QuietDesk.
	for _, env := range os.Environ() {
		key, _, _ := strings.Cut(env, "=")
		if strings.HasPrefix(key, "TS_") || strings.HasPrefix(key, "TSNET_") {
			os.Unsetenv(key)
		}
	}
	machine, _ := os.Hostname()
	node := tsnet.Server{Dir: *stateDir, Hostname: dnsname.SanitizeHostname("quietdesk-" + machine), Logf: logger.Discard, UserLogf: logger.Discard}
	h := helper{server: &node, outbound: make(map[uint16]*bridge)}
	defer node.Close()
	defer h.closeRoutes()
	serve(os.Stdin, os.Stdout, h.handle)
}

func serve(in io.Reader, out io.Writer, handle func(request) (response, error)) {
	input := bufio.NewScanner(in)
	encoder := json.NewEncoder(out)
	for input.Scan() {
		var req request
		var res response
		err := json.Unmarshal(input.Bytes(), &req)
		if err == nil && req.ID > 0 {
			res, err = handle(req)
		} else {
			err = errors.New("请求格式无效")
		}
		res.ID = req.ID
		if err != nil {
			res.Error = err.Error()
		}
		if encoder.Encode(res) != nil {
			return
		}
	}
}

func (h *helper) handle(req request) (response, error) {
	var res response
	if h.local == nil {
		lc, err := h.server.LocalClient()
		if err != nil {
			return res, fmt.Errorf("无法启动 Tailscale 节点：%w", err)
		}
		h.local = lc
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	switch req.Op {
	case "status":
		return h.status(ctx)
	case "login":
		if err := h.local.StartLoginInteractive(ctx); err != nil {
			return res, fmt.Errorf("无法开始 Tailscale 登录：%w", err)
		}
		return h.status(ctx)
	case "logout":
		h.closeRoutes()
		if err := h.local.Logout(ctx); err != nil {
			return res, fmt.Errorf("无法退出 Tailscale：%w", err)
		}
		return h.status(ctx)
	case "close":
		if b := h.outbound[req.Port]; b != nil {
			b.close()
			delete(h.outbound, req.Port)
		}
		return res, nil
	case "share":
		err := h.share(ctx, req.Port, req.UDP)
		return response{Port: h.port, UDP: h.sharedUDP != nil}, err
	case "open":
		port, err := h.open(ctx, req.Host, req.Port)
		res.Port = port
		return res, err
	default:
		return res, errors.New("不支持的 Tailscale 请求")
	}
}

func (h *helper) status(ctx context.Context) (response, error) {
	st, err := h.local.StatusWithoutPeers(ctx)
	if err != nil {
		return response{}, fmt.Errorf("无法读取 Tailscale 状态：%w", err)
	}
	res := response{State: st.BackendState, AuthURL: st.AuthURL}
	for _, ip := range st.TailscaleIPs {
		if ip.Is4() {
			res.IP = ip.String()
			break
		}
	}
	if h.sharedTCP != nil && (res.State != ipn.Running.String() || res.IP != h.boundIP) {
		h.stopSharing()
	}
	res.Port, res.UDP = h.port, h.sharedUDP != nil
	return res, nil
}

func (h *helper) stopSharing() {
	h.stopUDP()
	if h.sharedTCP != nil {
		h.sharedTCP.close()
		h.sharedTCP, h.port, h.boundIP = nil, 0, ""
	}
}

func (h *helper) stopUDP() {
	if h.sharedUDP != nil {
		h.sharedUDP.close()
		h.sharedUDP = nil
	}
}

func (h *helper) closeRoutes() {
	h.stopSharing()
	for port, b := range h.outbound {
		b.close()
		delete(h.outbound, port)
	}
}

func (h *helper) share(ctx context.Context, port uint16, udp bool) error {
	if port != h.port {
		h.stopSharing()
	}
	if port == 0 {
		return nil
	}
	p := strconv.Itoa(int(port))
	dest := net.JoinHostPort("127.0.0.1", p)
	var dialer net.Dialer
	dial := func(ctx context.Context, network string) (net.Conn, error) {
		return dialer.DialContext(ctx, network, dest)
	}
	if h.sharedTCP == nil {
		st, err := h.status(ctx)
		if err != nil {
			return err
		}
		if st.State != ipn.Running.String() || st.IP == "" {
			return errors.New("Tailscale 节点尚未联网")
		}
		listener, err := h.server.Listen("tcp4", net.JoinHostPort(st.IP, p))
		if err != nil {
			return fmt.Errorf("无法共享 Tailscale TCP 端口：%w", err)
		}
		h.sharedTCP = startBridge(listener, nil, dial)
		h.port, h.boundIP = port, st.IP
	}
	if !udp {
		h.stopUDP()
	} else if h.sharedUDP == nil {
		listener, err := h.server.ListenPacket("udp4", net.JoinHostPort(h.boundIP, p))
		if err != nil {
			return fmt.Errorf("无法共享 Tailscale UDP 端口：%w", err)
		}
		h.sharedUDP = startBridge(nil, listener, dial)
	}
	return nil
}

func (h *helper) open(ctx context.Context, host string, port uint16) (uint16, error) {
	ip, err := netip.ParseAddr(host)
	if err != nil || !tsaddr.IsTailscaleIPv4(ip) || port == 0 {
		return 0, errors.New("请输入对端的 Tailscale IPv4 地址与共享端口")
	}
	if len(h.outbound) >= 64 {
		return 0, errors.New("Tailscale 连接数已达上限")
	}
	st, err := h.local.Status(ctx)
	if err != nil {
		return 0, fmt.Errorf("无法读取 Tailscale 设备：%w", err)
	}
	if st.BackendState != ipn.Running.String() {
		return 0, errors.New("Tailscale 节点尚未联网")
	}
	peerFound := false
	for _, peer := range st.Peer {
		if peer.InNetworkMap && slices.Contains(peer.TailscaleIPs, ip) {
			peerFound = true
			break
		}
	}
	if !peerFound {
		return 0, errors.New("当前 tailnet 中未找到该 Tailscale 地址，请检查设备登录与访问规则")
	}
	target := netip.AddrPortFrom(ip, port)
	// UserDial falls back to OS routing when a peer disappears. Keep an open bridge
	// attached to the encrypted userspace stack even as the network map changes.
	dialer := h.server.Sys().Dialer.Get()
	tcp, udp, bound, err := listenLoopback()
	if err != nil {
		return 0, err
	}
	h.outbound[bound] = startBridge(tcp, udp, func(ctx context.Context, network string) (net.Conn, error) {
		if network == "tcp" {
			return dialer.NetstackDialTCP(ctx, target)
		}
		return dialer.NetstackDialUDP(ctx, target)
	})
	return bound, nil
}

func listenLoopback() (net.Listener, net.PacketConn, uint16, error) {
	// TCP and UDP are separate ephemeral namespaces; retry if UDP already owns the selected port.
	for range 8 {
		tcp, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			return nil, nil, 0, err
		}
		udp, err := net.ListenPacket("udp4", tcp.Addr().String())
		if err == nil {
			return tcp, udp, uint16(tcp.Addr().(*net.TCPAddr).Port), nil
		}
		tcp.Close()
	}
	return nil, nil, 0, errors.New("无法分配本地 TCP/UDP 连接端口")
}
