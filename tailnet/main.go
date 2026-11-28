// QuietDesk's private JSON-lines backend for its embedded Tailscale node.
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"tailscale.com/client/local"
	"tailscale.com/ipn"
	"tailscale.com/ipn/ipnstate"
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
	ID        int    `json:"id"`
	State     string `json:"state,omitempty"`
	IP        string `json:"ip,omitempty"`
	AuthURL   string `json:"authURL,omitempty"`
	Port      uint16 `json:"port,omitempty"`
	Error     string `json:"error,omitempty"`
	UDP       bool   `json:"udp,omitempty"`
	PeerPath  string `json:"peerPath,omitempty"`
	PeerRelay string `json:"peerRelay,omitempty"`
}

type helper struct {
	server       *tsnet.Server
	portStateDir string
	local        *local.Client
	sharedTCP    *bridge
	sharedUDP    *bridge
	port         uint16
	boundIP      string
	outbound     map[uint16]*bridge
	lastPeerIP   netip.Addr
	lastPeerPort uint16
}

func main() {
	stateDir := flag.String("state-dir", "", "private node state directory")
	controlURL := flag.String("control-url", "", "custom HTTPS control server URL")
	listenPort := flag.Uint("listen-port", 0, "WireGuard UDP port (0 reuses a port in the state directory)")
	flag.Parse()
	if *stateDir == "" || flag.NArg() != 0 || *listenPort > 65535 {
		os.Exit(2)
	}
	control, err := normalizedControlURL(*controlURL)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
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
	node := tsnet.Server{Dir: nodeStateDir(*stateDir, control), Hostname: dnsname.SanitizeHostname("quietdesk-" + machine),
		Logf: logger.Discard, UserLogf: logger.Discard, ControlURL: control, Port: uint16(*listenPort)}
	h := helper{server: &node, portStateDir: *stateDir, outbound: make(map[uint16]*bridge)}
	defer node.Close()
	defer h.closeRoutes()
	serve(os.Stdin, os.Stdout, h.handle)
}

func normalizedControlURL(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", nil
	}
	invalid := errors.New("control URL must use HTTPS (or loopback HTTP for testing) without credentials, query, or fragment")
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.ForceQuery || parsed.RawQuery != "" || strings.Contains(value, "#") {
		return "", invalid
	}
	host := parsed.Hostname()
	loopback := host == "127.0.0.1" || strings.EqualFold(host, "localhost")
	if parsed.Scheme != "https" && (parsed.Scheme != "http" || !loopback) {
		return "", invalid
	}
	host = strings.ToLower(host)
	canonicalHost := host
	if strings.HasPrefix(parsed.Host, "[") {
		ip, err := netip.ParseAddr(host)
		if err != nil || !ip.Is6() || ip.Zone() != "" {
			return "", invalid
		}
		host = ip.String()
		canonicalHost = "[" + host + "]"
	} else if dnsname.ValidHostname(host) != nil {
		return "", invalid
	}
	if port := parsed.Port(); port != "" || strings.HasSuffix(parsed.Host, ":") {
		n, err := strconv.ParseUint(port, 10, 16)
		if err != nil || n == 0 {
			return "", invalid
		}
		if !(parsed.Scheme == "https" && n == 443 || parsed.Scheme == "http" && n == 80) {
			canonicalHost = net.JoinHostPort(host, strconv.FormatUint(n, 10))
		}
	}
	parsed.Host = canonicalHost
	if parsed.EscapedPath() == "/" {
		parsed.Path = ""
	}
	return parsed.String(), nil
}

func nodeStateDir(stateDir, controlURL string) string {
	if controlURL == "" {
		return stateDir
	}
	// tsnet reuses saved enrollment when its ControlURL changes in the same directory.
	return filepath.Join(stateDir, fmt.Sprintf("control-%x", sha256.Sum256([]byte(controlURL))))
}

func persistedListenPort(stateDir string) (uint16, error) {
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return 0, err
	}
	path := filepath.Join(stateDir, "wg-port")
	if port, err := readListenPort(path); !errors.Is(err, os.ErrNotExist) {
		return port, err
	}
	udp, err := net.ListenUDP("udp", nil)
	if err != nil {
		return 0, err
	}
	defer udp.Close()
	port := uint16(udp.LocalAddr().(*net.UDPAddr).Port)
	if port < 1024 {
		return 0, errors.New("automatic UDP port is outside the unprivileged range")
	}
	file, err := os.CreateTemp(stateDir, ".wg-port-*")
	if err != nil {
		return 0, err
	}
	defer os.Remove(file.Name())
	if _, err = fmt.Fprintln(file, port); err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return 0, err
	}
	// Publish a complete file without replacing a port chosen by another process.
	if err := os.Link(file.Name(), path); err != nil {
		if errors.Is(err, os.ErrExist) {
			return readListenPort(path)
		}
		return 0, err
	}
	return port, nil
}

func readListenPort(path string) (uint16, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return 0, err
	}
	invalid := errors.New("invalid wg-port file")
	if !info.Mode().IsRegular() || info.Size() > 32 {
		return 0, invalid
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	port, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 16)
	if err != nil || port < 1024 {
		return 0, invalid
	}
	return uint16(port), nil
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
		if h.server.Port == 0 && h.portStateDir != "" {
			port, err := persistedListenPort(h.portStateDir)
			if err != nil {
				return res, fmt.Errorf("无法保存 WireGuard UDP 端口：%w", err)
			}
			h.server.Port = port
		}
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
			if req.Port == h.lastPeerPort {
				h.lastPeerIP, h.lastPeerPort = netip.Addr{}, 0
			}
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
	readStatus := h.local.StatusWithoutPeers
	if h.sharedTCP != nil || len(h.outbound) > 0 {
		readStatus = h.local.Status
	}
	st, err := readStatus(ctx)
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
	if res.State == ipn.Running.String() && (h.sharedTCP != nil || len(h.outbound) > 0) {
		if peer := statusPeer(st, h.lastPeerIP); peer != nil {
			if peer.CurAddr != "" {
				res.PeerPath, res.PeerRelay = "direct", peer.Relay
			} else if peer.Active || peer.InMagicSock || peer.Relay != "" {
				res.PeerPath, res.PeerRelay = "derp", peer.Relay
			}
		}
	}
	res.Port, res.UDP = h.port, h.sharedUDP != nil
	return res, nil
}

func statusPeer(st *ipnstate.Status, target netip.Addr) *ipnstate.PeerStatus {
	var active *ipnstate.PeerStatus
	for _, peer := range st.Peer {
		if peer == nil {
			continue
		}
		if target.IsValid() && peer.InNetworkMap && slices.Contains(peer.TailscaleIPs, target) {
			return peer
		}
		if active == nil && peer.Active {
			active = peer
		}
	}
	return active
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
	h.lastPeerIP, h.lastPeerPort = netip.Addr{}, 0
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
	h.lastPeerIP, h.lastPeerPort = ip, bound
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
