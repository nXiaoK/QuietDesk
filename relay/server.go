package relay

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	AccessKey        []byte
	StatePath        string
	MaxConnections   int
	MaxDevices       int
	HandshakeTimeout time.Duration
	IdleTimeout      time.Duration
	TunnelTimeout    time.Duration
}

type Snapshot struct {
	Connections            int    `json:"connections"`
	OnlineDevices          int    `json:"onlineDevices"`
	PendingTunnels         int    `json:"pendingTunnels"`
	ActiveTunnels          int    `json:"activeTunnels"`
	DatagramSessions       int    `json:"datagramSessions"`
	ForwardedDatagramBytes uint64 `json:"forwardedDatagramBytes"`
	RejectedDatagrams      uint64 `json:"rejectedDatagrams"`
}

type Server struct {
	cfg           Config
	mu            sync.Mutex
	hosts         map[string]*host
	owners        map[string]string
	circuits      map[string]*circuit
	datagrams     map[[16]byte]*datagramLease
	connections   map[net.Conn]struct{}
	listener      net.Listener
	udp           net.PacketConn
	closed        bool
	slots         chan struct{}
	activeTunnels int
	forwarded     atomic.Uint64
	rejected      atomic.Uint64
	wg            sync.WaitGroup
}

type host struct {
	id           string
	registration string
	conn         net.Conn
	writeMu      sync.Mutex
	done         chan struct{}
}

type circuit struct {
	host     *host
	viewer   net.Conn
	accepted chan net.Conn
	done     chan struct{}
	claimed  bool
	active   bool
}

type datagramLease struct {
	host      *host
	keys      [2][32]byte
	addresses [2]net.Addr
	replay    [2]ReplayWindow
	sequences [2]uint64
	viewer    net.Conn
}

var devicePattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

func NewServer(cfg Config) (*Server, error) {
	if len(cfg.AccessKey) != 32 {
		return nil, errors.New("relay access key must contain 32 bytes")
	}
	if cfg.MaxConnections == 0 {
		cfg.MaxConnections = 1024
	}
	if cfg.MaxDevices == 0 {
		cfg.MaxDevices = 4096
	}
	if cfg.HandshakeTimeout == 0 {
		cfg.HandshakeTimeout = 5 * time.Second
	}
	if cfg.IdleTimeout == 0 {
		cfg.IdleTimeout = 45 * time.Second
	}
	if cfg.TunnelTimeout == 0 {
		cfg.TunnelTimeout = 10 * time.Second
	}
	if cfg.MaxConnections < 1 || cfg.MaxConnections > 65536 || cfg.MaxDevices < 1 || cfg.MaxDevices > 65536 || cfg.HandshakeTimeout <= 0 || cfg.IdleTimeout <= 0 || cfg.TunnelTimeout <= 0 {
		return nil, errors.New("invalid relay resource configuration")
	}
	cfg.AccessKey = append([]byte(nil), cfg.AccessKey...)
	s := &Server{cfg: cfg, hosts: make(map[string]*host), owners: make(map[string]string), circuits: make(map[string]*circuit),
		datagrams: make(map[[16]byte]*datagramLease), connections: make(map[net.Conn]struct{}), slots: make(chan struct{}, cfg.MaxConnections)}
	if cfg.StatePath != "" {
		info, err := os.Lstat(cfg.StatePath)
		if err == nil {
			if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
				return nil, errors.New("relay state must be a private regular file")
			}
			data, err := ReadPrivateFile(cfg.StatePath, 16*1024*1024)
			if err != nil {
				return nil, err
			}
			var state struct {
				Version int               `json:"version"`
				Owners  map[string]string `json:"owners"`
			}
			if json.Unmarshal(data, &state) != nil || state.Version != 1 || state.Owners == nil || len(state.Owners) > cfg.MaxDevices {
				return nil, errors.New("invalid relay state; original file retained")
			}
			for id, digest := range state.Owners {
				bytes, err := hex.DecodeString(digest)
				if !devicePattern.MatchString(id) || err != nil || len(bytes) != 32 {
					return nil, errors.New("invalid relay owner state")
				}
			}
			s.owners = state.Owners
		} else if !os.IsNotExist(err) {
			return nil, err
		}
	}
	return s, nil
}

// The TCP listener must already terminate service TLS. Inner desktop TLS is opaque bytes.
func (s *Server) Serve(listener net.Listener, udp net.PacketConn) error {
	s.mu.Lock()
	if s.closed || s.listener != nil {
		s.mu.Unlock()
		return errors.New("relay server cannot restart")
	}
	s.listener = listener
	s.udp = udp
	if udp != nil {
		s.wg.Add(1)
	}
	s.mu.Unlock()
	if udp != nil {
		go func() { defer s.wg.Done(); s.serveUDP(udp) }()
	}
	for {
		conn, err := listener.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			s.mu.Unlock()
			if closed {
				return nil
			}
			return err
		}
		select {
		case s.slots <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			<-s.slots
			conn.Close()
			return nil
		}
		s.connections[conn] = struct{}{}
		s.wg.Add(1)
		s.mu.Unlock()
		go func() {
			defer s.wg.Done()
			defer func() { conn.Close(); s.mu.Lock(); delete(s.connections, conn); s.mu.Unlock(); <-s.slots }()
			s.handle(conn)
		}()
	}
}

func (s *Server) Close() error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return nil
	}
	s.closed = true
	listener, udp := s.listener, s.udp
	connections := make([]net.Conn, 0, len(s.connections))
	for conn := range s.connections {
		connections = append(connections, conn)
	}
	s.mu.Unlock()
	if listener != nil {
		listener.Close()
	}
	if udp != nil {
		udp.Close()
	}
	for _, conn := range connections {
		conn.Close()
	}
	s.wg.Wait()
	return nil
}

func (s *Server) Snapshot() Snapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	pending := 0
	for _, circuit := range s.circuits {
		if !circuit.active {
			pending++
		}
	}
	return Snapshot{len(s.connections), len(s.hosts), pending, s.activeTunnels, len(s.datagrams), s.forwarded.Load(), s.rejected.Load()}
}

func randomHex() (string, error) {
	var bytes [32]byte
	_, err := rand.Read(bytes[:])
	return hex.EncodeToString(bytes[:]), err
}

func (s *Server) handle(conn net.Conn) {
	secure, ok := conn.(*tls.Conn)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), s.cfg.HandshakeTimeout)
	err := secure.HandshakeContext(ctx)
	cancel()
	if err != nil {
		return
	}
	conn.SetDeadline(time.Now().Add(s.cfg.HandshakeTimeout))
	message, err := ReadMessage(conn)
	if err != nil {
		return
	}
	if len(message.AccessKey) != 32 || subtle.ConstantTimeCompare(message.AccessKey, s.cfg.AccessKey) != 1 {
		WriteMessage(conn, Message{Op: "error", Error: "unauthorized"})
		return
	}
	message.DeviceID = strings.ToLower(message.DeviceID)
	if !devicePattern.MatchString(message.DeviceID) {
		WriteMessage(conn, Message{Op: "error", Error: "protocol"})
		return
	}
	switch message.Op {
	case "register":
		s.register(conn, message)
	case "connect":
		s.connect(conn, message)
	case "accept":
		s.accept(conn, message)
	case "datagram":
		s.openDatagram(conn, message)
	default:
		WriteMessage(conn, Message{Op: "error", Error: "unsupported"})
	}
}

func (s *Server) saveOwner(id, digest string) error {
	if s.cfg.StatePath == "" {
		s.owners[id] = digest
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(s.cfg.StatePath), 0700); err != nil {
		return err
	}
	parent, err := os.Lstat(filepath.Dir(s.cfg.StatePath))
	if err != nil || !parent.IsDir() || parent.Mode().Perm()&0077 != 0 {
		return errors.New("relay state directory must be private and must not be a symlink")
	}
	if info, err := os.Lstat(s.cfg.StatePath); err == nil && (!info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0) {
		return errors.New("unsafe relay state file")
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	owners := make(map[string]string, len(s.owners)+1)
	for key, value := range s.owners {
		owners[key] = value
	}
	owners[id] = digest
	data, err := json.Marshal(struct {
		Version int               `json:"version"`
		Owners  map[string]string `json:"owners"`
	}{1, owners})
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(s.cfg.StatePath), ".relay-state-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if err = file.Chmod(0600); err == nil {
		_, err = file.Write(data)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(file.Name(), s.cfg.StatePath)
	}
	if err != nil {
		return err
	}
	directory, err := os.Open(filepath.Dir(s.cfg.StatePath))
	if err != nil {
		return err
	}
	err = directory.Sync()
	directory.Close()
	if err != nil {
		return err
	}
	s.owners = owners
	return nil
}

func (s *Server) register(conn net.Conn, message Message) {
	if len(message.OwnerKey) != 32 {
		WriteMessage(conn, Message{Op: "error", Error: "protocol"})
		return
	}
	owner := sha256.Sum256(message.OwnerKey)
	digest := hex.EncodeToString(owner[:])
	registration, err := randomHex()
	if err != nil {
		return
	}
	h := &host{id: message.DeviceID, registration: registration, conn: conn, done: make(chan struct{})}
	s.mu.Lock()
	code := ""
	if stored, exists := s.owners[h.id]; exists && subtle.ConstantTimeCompare([]byte(stored), []byte(digest)) != 1 {
		code = "owner_mismatch"
	} else if s.hosts[h.id] != nil {
		code = "busy"
	} else if !exists && len(s.owners) >= s.cfg.MaxDevices {
		code = "capacity"
	} else if !exists {
		if s.saveOwner(h.id, digest) != nil {
			code = "storage"
		}
	}
	if code == "" {
		s.hosts[h.id] = h
	}
	s.mu.Unlock()
	if code != "" {
		WriteMessage(conn, Message{Op: "error", Error: code})
		return
	}
	defer func() {
		close(h.done)
		s.mu.Lock()
		if s.hosts[h.id] == h {
			delete(s.hosts, h.id)
		}
		var closeConnections []net.Conn
		for _, pending := range s.circuits {
			if pending.host == h {
				closeConnections = append(closeConnections, pending.viewer)
			}
		}
		for id, lease := range s.datagrams {
			if lease.host == h {
				delete(s.datagrams, id)
				closeConnections = append(closeConnections, lease.viewer)
			}
		}
		s.mu.Unlock()
		for _, connection := range closeConnections {
			connection.Close()
		}
	}()
	if h.send(Message{Op: "registered", Registration: registration}) != nil {
		return
	}
	for {
		conn.SetReadDeadline(time.Now().Add(s.cfg.IdleTimeout))
		request, err := ReadMessage(conn)
		if err != nil || request.Op != "ping" {
			return
		}
		if h.send(Message{Op: "pong"}) != nil {
			return
		}
	}
}

func (h *host) send(message Message) error {
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	h.conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	return WriteMessage(h.conn, message)
}

func (s *Server) connect(conn net.Conn, message Message) {
	id, err := randomHex()
	if err != nil {
		return
	}
	s.mu.Lock()
	h := s.hosts[message.DeviceID]
	if h == nil {
		s.mu.Unlock()
		WriteMessage(conn, Message{Op: "error", Error: "offline"})
		return
	}
	pending := &circuit{host: h, viewer: conn, accepted: make(chan net.Conn), done: make(chan struct{})}
	s.circuits[id] = pending
	s.mu.Unlock()
	defer func() { s.mu.Lock(); delete(s.circuits, id); s.mu.Unlock(); close(pending.done) }()
	if h.send(Message{Op: "incoming", CircuitID: id}) != nil {
		return
	}
	select {
	case peer := <-pending.accepted:
		defer peer.Close()
		conn.SetDeadline(time.Now().Add(s.cfg.HandshakeTimeout))
		peer.SetDeadline(time.Now().Add(s.cfg.HandshakeTimeout))
		if WriteMessage(conn, Message{Op: "ready"}) != nil || WriteMessage(peer, Message{Op: "ready"}) != nil {
			return
		}
		conn.SetDeadline(time.Time{})
		peer.SetDeadline(time.Time{})
		s.mu.Lock()
		pending.active = true
		s.activeTunnels++
		s.mu.Unlock()
		defer func() { s.mu.Lock(); s.activeTunnels--; s.mu.Unlock() }()
		done := make(chan struct{}, 1)
		go func() {
			copyWithIdleBudget(peer, conn, s.cfg.IdleTimeout)
			peer.Close()
			conn.Close()
			done <- struct{}{}
		}()
		copyWithIdleBudget(conn, peer, s.cfg.IdleTimeout)
		peer.Close()
		conn.Close()
		<-done
	case <-h.done:
		return
	case <-time.After(s.cfg.TunnelTimeout):
		conn.SetWriteDeadline(time.Now().Add(s.cfg.HandshakeTimeout))
		WriteMessage(conn, Message{Op: "error", Error: "timeout"})
	}
}

func (s *Server) accept(conn net.Conn, message Message) {
	s.mu.Lock()
	h := s.hosts[message.DeviceID]
	pending := s.circuits[message.CircuitID]
	valid := h != nil && pending != nil && !pending.claimed && pending.host == h && len(message.Registration) == 64 &&
		subtle.ConstantTimeCompare([]byte(message.Registration), []byte(h.registration)) == 1
	if valid {
		pending.claimed = true
	}
	s.mu.Unlock()
	if !valid {
		WriteMessage(conn, Message{Op: "error", Error: "expired"})
		return
	}
	select {
	case pending.accepted <- conn:
		// The viewer handler owns writes and pumping until its circuit is settled.
		<-pending.done
	case <-pending.done:
		return
	case <-time.After(s.cfg.TunnelTimeout):
		WriteMessage(conn, Message{Op: "error", Error: "expired"})
	}
}

func (s *Server) openDatagram(conn net.Conn, message Message) {
	var id [16]byte
	lease := &datagramLease{viewer: conn}
	if _, err := rand.Read(id[:]); err != nil {
		return
	}
	for index := range lease.keys {
		if _, err := rand.Read(lease.keys[index][:]); err != nil {
			return
		}
	}
	s.mu.Lock()
	h := s.hosts[message.DeviceID]
	if h == nil || s.udp == nil {
		s.mu.Unlock()
		WriteMessage(conn, Message{Op: "error", Error: "offline"})
		return
	}
	lease.host = h
	s.datagrams[id] = lease
	address, ok := s.udp.LocalAddr().(*net.UDPAddr)
	if !ok {
		delete(s.datagrams, id)
		s.mu.Unlock()
		return
	}
	port := address.Port
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.datagrams, id)
		s.mu.Unlock()
		h.send(Message{Op: "datagramClosed", DatagramID: id[:]})
	}()
	if h.send(Message{Op: "incomingDatagram", DatagramID: id[:], DatagramKey: lease.keys[1][:], UDPPort: port}) != nil {
		return
	}
	if WriteMessage(conn, Message{Op: "datagramReady", DatagramID: id[:], DatagramKey: lease.keys[0][:], UDPPort: port}) != nil {
		return
	}
	for {
		conn.SetReadDeadline(time.Now().Add(s.cfg.IdleTimeout))
		request, err := ReadMessage(conn)
		if err != nil || request.Op != "ping" {
			return
		}
		conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if WriteMessage(conn, Message{Op: "pong"}) != nil {
			return
		}
	}
}

func (s *Server) serveUDP(conn net.PacketConn) {
	buffer := make([]byte, MaxDatagramPayload+DatagramOverhead+1)
	for {
		n, address, err := conn.ReadFrom(buffer)
		if err != nil {
			return
		}
		if n < DatagramOverhead || n > MaxDatagramPayload+DatagramOverhead || buffer[4] > 1 || buffer[5] != 0 {
			s.rejected.Add(1)
			continue
		}
		var id [16]byte
		copy(id[:], buffer[14:30])
		side := buffer[4]
		s.mu.Lock()
		lease := s.datagrams[id]
		if lease == nil {
			s.mu.Unlock()
			s.rejected.Add(1)
			continue
		}
		packet, err := DecodeDatagram(buffer[:n], lease.keys[side][:])
		if err != nil || !lease.replay[side].Accept(packet.Sequence) {
			s.mu.Unlock()
			s.rejected.Add(1)
			continue
		}
		lease.addresses[side] = address
		other := byte(1) - side
		destination := lease.addresses[other]
		if destination == nil || len(packet.Payload) == 0 || lease.sequences[other] == ^uint64(0) {
			s.mu.Unlock()
			continue
		}
		lease.sequences[other]++
		packet.Side = other
		packet.Downstream = true
		packet.Sequence = lease.sequences[other]
		outgoing, err := EncodeDatagram(packet, lease.keys[other][:])
		s.mu.Unlock()
		if err == nil {
			if _, err = conn.WriteTo(outgoing, destination); err == nil {
				s.forwarded.Add(uint64(len(packet.Payload)))
			}
		}
	}
}

type idleReader struct {
	net.Conn
	timeout time.Duration
}

func (r idleReader) Read(data []byte) (int, error) {
	r.SetReadDeadline(time.Now().Add(r.timeout))
	return r.Conn.Read(data)
}

type idleWriter struct {
	net.Conn
	timeout time.Duration
}

func (w idleWriter) Write(data []byte) (int, error) {
	w.SetWriteDeadline(time.Now().Add(w.timeout))
	return w.Conn.Write(data)
}
func copyWithIdleBudget(destination, source net.Conn, timeout time.Duration) {
	io.CopyBuffer(idleWriter{destination, timeout}, idleReader{source, timeout}, make([]byte, 32*1024))
}
