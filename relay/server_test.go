package relay

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const deviceA = "672d6104-a890-4c4c-8862-c8f28f55953a"
const deviceB = "73cd4ae1-1f9c-47b3-bc64-4c250106c947"

type fixture struct {
	server      *Server
	address     string
	udpAddress  *net.UDPAddr
	access      []byte
	clientTLS   *tls.Config
	certificate []byte
}

func randomKey(t *testing.T) []byte {
	t.Helper()
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		t.Fatal(err)
	}
	return key
}

func newFixture(t *testing.T, cfg Config) *fixture {
	return newFixtureWithDatagrams(t, cfg, false)
}

type blockedDatagramSocket struct{ net.PacketConn }

func (socket blockedDatagramSocket) ReadFrom(data []byte) (int, net.Addr, error) {
	for {
		if _, _, err := socket.PacketConn.ReadFrom(data); err != nil {
			return 0, nil, err
		}
	}
}

func newFixtureWithDatagrams(t *testing.T, cfg Config, blocked bool) *fixture {
	t.Helper()
	if cfg.AccessKey == nil {
		cfg.AccessKey = randomKey(t)
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "QuietDesk synthetic relay"},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IPAddresses: []net.IP{net.ParseIP("127.0.0.1")},
		DNSNames: []string{"localhost"}, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, BasicConstraintsValid: true, IsCA: true}
	certificate, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(certificate)
	if err != nil {
		t.Fatal(err)
	}
	pool := x509.NewCertPool()
	pool.AddCert(leaf)
	listener, err := tls.Listen("tcp", "127.0.0.1:0", &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{certificate}, PrivateKey: key}}, MinVersion: tls.VersionTLS12})
	if err != nil {
		t.Fatal(err)
	}
	udp, err := net.ListenPacket("udp", listener.Addr().String())
	if err != nil {
		listener.Close()
		t.Fatal(err)
	}
	server, err := NewServer(cfg)
	if err != nil {
		listener.Close()
		udp.Close()
		t.Fatal(err)
	}
	f := &fixture{server, listener.Addr().String(), udp.LocalAddr().(*net.UDPAddr), cfg.AccessKey, &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}, certificate}
	var packets net.PacketConn = udp
	if blocked {
		packets = blockedDatagramSocket{udp}
	}
	go func() {
		if err := server.Serve(listener, packets); err != nil {
			t.Errorf("serve: %v", err)
		}
	}()
	t.Cleanup(func() { server.Close() })
	return f
}

func (f *fixture) dial(t *testing.T) net.Conn {
	t.Helper()
	conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 2 * time.Second}, "tcp", f.address, f.clientTLS)
	if err != nil {
		t.Fatal(err)
	}
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	t.Cleanup(func() { conn.Close() })
	return conn
}

func write(t *testing.T, conn io.Writer, message Message) {
	t.Helper()
	if err := WriteMessage(conn, message); err != nil {
		t.Fatal(err)
	}
}
func read(t *testing.T, conn io.Reader, op string) Message {
	t.Helper()
	message, err := ReadMessage(conn)
	if err != nil {
		t.Fatal(err)
	}
	if message.Op != op {
		t.Fatalf("expected %s, got %s/%s", op, message.Op, message.Error)
	}
	return message
}
func until(t *testing.T, predicate func() bool) {
	t.Helper()
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
		if predicate() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("condition did not settle")
}
func (f *fixture) register(t *testing.T, id string, owner []byte) (net.Conn, Message) {
	t.Helper()
	conn := f.dial(t)
	write(t, conn, Message{Op: "register", AccessKey: f.access, DeviceID: id, OwnerKey: owner})
	return conn, read(t, conn, "registered")
}

type shortWriter struct{ bytes.Buffer }

func (w *shortWriter) Write(data []byte) (int, error) {
	if len(data) > 2 {
		data = data[:2]
	}
	return w.Buffer.Write(data)
}

func TestFramingAndReplayBounds(t *testing.T) {
	writer := &shortWriter{}
	if err := WriteMessage(writer, Message{Op: "ping"}); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadMessage(&writer.Buffer); err != nil {
		t.Fatal(err)
	}
	for _, size := range []uint32{0, MaxMessageBytes + 1, ^uint32(0)} {
		var prefix [4]byte
		binary.BigEndian.PutUint32(prefix[:], size)
		if _, err := ReadMessage(bytes.NewReader(prefix[:])); err == nil {
			t.Fatal("unbounded frame accepted")
		}
	}
	window := ReplayWindow{}
	for _, value := range []uint64{1, 3, 2, 64, 65} {
		if !window.Accept(value) {
			t.Fatal("valid reordered sequence rejected")
		}
	}
	for _, value := range []uint64{0, 1, 2, 3, 65} {
		if window.Accept(value) {
			t.Fatal("replay accepted")
		}
	}
}

func TestServiceAuthAndCertificateValidation(t *testing.T) {
	f := newFixture(t, Config{})
	conn := f.dial(t)
	write(t, conn, Message{Op: "connect", DeviceID: deviceA, AccessKey: randomKey(t)})
	if read(t, conn, "error").Error != "unauthorized" {
		t.Fatal("incorrect service key accepted")
	}
	conn = f.dial(t)
	write(t, conn, Message{Op: "connect", DeviceID: deviceA, AccessKey: f.access})
	if read(t, conn, "error").Error != "offline" {
		t.Fatal("offline device advertised ready")
	}
	bad := f.clientTLS.Clone()
	bad.ServerName = "different.invalid"
	if conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", f.address, bad); err == nil {
		conn.Close()
		t.Fatal("wrong certificate identity accepted")
	}
}

func TestOwnerPersistenceAndDuplicateRegistration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "state.json")
	access, owner := randomKey(t), randomKey(t)
	f := newFixture(t, Config{AccessKey: access, StatePath: path})
	conn, _ := f.register(t, deviceA, owner)
	duplicate := f.dial(t)
	write(t, duplicate, Message{Op: "register", DeviceID: deviceA, AccessKey: access, OwnerKey: owner})
	if read(t, duplicate, "error").Error != "busy" {
		t.Fatal("active owner was replaced")
	}
	conn.Close()
	until(t, func() bool { return f.server.Snapshot().OnlineDevices == 0 })
	f.server.Close()
	data, err := ReadPrivateFile(path, 1024)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(data, owner) || bytes.Contains(data, access) {
		t.Fatal("state persisted routing credentials")
	}
	restarted := newFixture(t, Config{AccessKey: access, StatePath: path})
	wrong := restarted.dial(t)
	write(t, wrong, Message{Op: "register", DeviceID: deviceA, AccessKey: access, OwnerKey: randomKey(t)})
	if read(t, wrong, "error").Error != "owner_mismatch" {
		t.Fatal("device identity was taken over after restart")
	}
	restarted.register(t, deviceA, owner)
}

func TestOpaqueDuplexAndRegistrationShutdown(t *testing.T) {
	f := newFixture(t, Config{})
	registration, registered := f.register(t, deviceA, randomKey(t))
	viewer := f.dial(t)
	write(t, viewer, Message{Op: "connect", DeviceID: deviceA, AccessKey: f.access})
	incoming := read(t, registration, "incoming")
	wrong := f.dial(t)
	write(t, wrong, Message{Op: "accept", DeviceID: deviceA, AccessKey: f.access, CircuitID: incoming.CircuitID, Registration: strings.Repeat("0", 64)})
	if read(t, wrong, "error").Error != "expired" {
		t.Fatal("wrong registration bound a tunnel")
	}
	accepted := f.dial(t)
	write(t, accepted, Message{Op: "accept", DeviceID: deviceA, AccessKey: f.access, CircuitID: incoming.CircuitID, Registration: registered.Registration})
	read(t, viewer, "ready")
	read(t, accepted, "ready")
	left, right := bytes.Repeat([]byte{1, 3, 7, 255}, 64*1024), bytes.Repeat([]byte{0, 9, 128}, 80*1024)
	errors := make(chan error, 2)
	go func() { _, err := viewer.Write(left); errors <- err }()
	go func() { _, err := accepted.Write(right); errors <- err }()
	fromViewer, fromHost := make([]byte, len(left)), make([]byte, len(right))
	if _, err := io.ReadFull(accepted, fromViewer); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(viewer, fromHost); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := <-errors; err != nil {
			t.Fatal(err)
		}
	}
	if !bytes.Equal(left, fromViewer) || !bytes.Equal(right, fromHost) {
		t.Fatal("tunnel changed opaque bytes")
	}
	registration.Close()
	var buffer [1]byte
	if _, err := viewer.Read(buffer[:]); err == nil {
		t.Fatal("host unregister left its tunnel active")
	}
	until(t, func() bool { return f.server.Snapshot().ActiveTunnels == 0 })
}

func TestPendingAndIdleExpiry(t *testing.T) {
	f := newFixture(t, Config{TunnelTimeout: 100 * time.Millisecond, IdleTimeout: 350 * time.Millisecond})
	registration, registered := f.register(t, deviceA, randomKey(t))
	viewer := f.dial(t)
	write(t, viewer, Message{Op: "connect", DeviceID: deviceA, AccessKey: f.access})
	incoming := read(t, registration, "incoming")
	if read(t, viewer, "error").Error != "timeout" {
		t.Fatal("pending tunnel had no deadline")
	}
	late := f.dial(t)
	write(t, late, Message{Op: "accept", DeviceID: deviceA, AccessKey: f.access, CircuitID: incoming.CircuitID, Registration: registered.Registration})
	if read(t, late, "error").Error != "expired" {
		t.Fatal("late accept revived an expired tunnel")
	}
	until(t, func() bool { return f.server.Snapshot().OnlineDevices == 0 && f.server.Snapshot().PendingTunnels == 0 })
}

func TestDatagramAuthReorderingRebindingAndClose(t *testing.T) {
	f := newFixture(t, Config{})
	registration, _ := f.register(t, deviceA, randomKey(t))
	lease := f.dial(t)
	write(t, lease, Message{Op: "datagram", DeviceID: deviceA, AccessKey: f.access})
	host := read(t, registration, "incomingDatagram")
	var id [16]byte
	copy(id[:], host.DatagramID)
	openUDP := func() *net.UDPConn {
		conn, err := net.DialUDP("udp", nil, f.udpAddress)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { conn.Close() })
		conn.SetDeadline(time.Now().Add(2 * time.Second))
		return conn
	}
	hostSocket, viewerSocket, other := openUDP(), openUDP(), openUDP()
	send := func(conn *net.UDPConn, side byte, sequence uint64, payload, key []byte) []byte {
		data, err := EncodeDatagram(Datagram{Side: side, Sequence: sequence, ID: id, Payload: payload}, key)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = conn.Write(data); err != nil {
			t.Fatal(err)
		}
		return data
	}
	send(hostSocket, 1, 1, nil, host.DatagramKey)
	viewer := read(t, lease, "datagramReady")
	if !bytes.Equal(host.DatagramID, viewer.DatagramID) || bytes.Equal(host.DatagramKey, viewer.DatagramKey) {
		t.Fatal("datagram sides were not isolated")
	}
	send(viewerSocket, 0, 1, nil, viewer.DatagramKey)
	until(t, func() bool {
		f.server.mu.Lock()
		defer f.server.mu.Unlock()
		entry := f.server.datagrams[id]
		return entry != nil && entry.addresses[0] != nil && entry.addresses[1] != nil
	})
	receive := func(conn *net.UDPConn, key []byte, expected []byte) {
		buffer := make([]byte, 2048)
		n, err := conn.Read(buffer)
		if err != nil {
			t.Fatal(err)
		}
		packet, err := DecodeDatagram(buffer[:n], key)
		if err != nil || !packet.Downstream || !bytes.Equal(packet.Payload, expected) {
			t.Fatal("forwarded datagram invalid")
		}
	}
	payload := []byte{23, 254, 253, 0, 255, 1}
	replayed := send(viewerSocket, 0, 3, payload, viewer.DatagramKey)
	receive(hostSocket, host.DatagramKey, payload)
	send(viewerSocket, 0, 2, payload, viewer.DatagramKey)
	receive(hostSocket, host.DatagramKey, payload)
	forged := append([]byte(nil), replayed...)
	forged[len(forged)-1] ^= 1
	other.Write(forged)
	other.Write(replayed)
	until(t, func() bool { return f.server.Snapshot().RejectedDatagrams >= 2 })
	send(hostSocket, 1, 2, payload, host.DatagramKey)
	receive(viewerSocket, viewer.DatagramKey, payload)
	// Only a fresh authenticated source packet may move a NAT endpoint.
	send(other, 1, 3, nil, host.DatagramKey)
	until(t, func() bool {
		f.server.mu.Lock()
		defer f.server.mu.Unlock()
		return f.server.datagrams[id].addresses[1].String() == other.LocalAddr().String()
	})
	send(viewerSocket, 0, 4, payload, viewer.DatagramKey)
	receive(other, host.DatagramKey, payload)
	lease.Close()
	read(t, registration, "datagramClosed")
	until(t, func() bool { return f.server.Snapshot().DatagramSessions == 0 })
	if f.server.Snapshot().ForwardedDatagramBytes != uint64(4*len(payload)) {
		t.Fatal("datagram byte accounting was inaccurate")
	}
}

func TestPrivateStateRejectsUnsafeAndDamagedFiles(t *testing.T) {
	root := t.TempDir()
	source := filepath.Join(root, "state.json")
	data := []byte(`{"version":2,"owners":{}}`)
	if err := os.WriteFile(source, data, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := NewServer(Config{AccessKey: randomKey(t), StatePath: source}); err == nil {
		t.Fatal("unknown state version was replaced")
	}
	if current, _ := os.ReadFile(source); !bytes.Equal(data, current) {
		t.Fatal("damaged state changed")
	}
	for _, kind := range []string{"symlink", "hardlink"} {
		path := filepath.Join(root, kind)
		var err error
		if kind == "symlink" {
			err = os.Symlink(source, path)
		} else {
			err = os.Link(source, path)
		}
		if err != nil {
			t.Fatal(err)
		}
		if _, err = ReadPrivateFile(path, 1024); err == nil {
			t.Fatal("unsafe private file accepted")
		}
		os.Remove(path)
	}
	if err := os.Chmod(source, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadPrivateFile(source, 1024); err == nil {
		t.Fatal("publicly readable credential accepted")
	}
}

func TestNativeInteropFixture(t *testing.T) {
	directory := os.Getenv("QUIETDESK_RELAY_FIXTURE_DIR")
	if directory == "" {
		t.Skip("native interoperability fixture is opt-in")
	}
	f := newFixtureWithDatagrams(t, Config{}, os.Getenv("QUIETDESK_RELAY_FIXTURE_BLOCK_UDP") == "1")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "certificate.der"), f.certificate, 0600); err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(struct {
		Address   string `json:"address"`
		AccessKey []byte `json:"accessKey"`
	}{f.address, f.access})
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(directory, "fixture.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(directory, "certificate.pem"), pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: f.certificate}), 0600); err != nil {
		t.Fatal(err)
	}
	for {
		if _, err := os.Stat(filepath.Join(directory, "finish")); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestSharedDatagramVector(t *testing.T) {
	key := make([]byte, 32)
	var id [16]byte
	for index := range key {
		key[index] = byte(index)
	}
	for index := range id {
		id[index] = byte(index)
	}
	data, err := EncodeDatagram(Datagram{Side: 1, Downstream: true, Sequence: 17, ID: id, Payload: []byte{0, 128, 255}}, key)
	if err != nil {
		t.Fatal(err)
	}
	if hex.EncodeToString(data) != "5144523101010000000000000011000102030405060708090a0b0c0d0e0f00030080ff237a249d00e804b083a7d4c2647df028d8d3ce3bca945417f8517a1935c6cd9e" {
		t.Fatal("Go and native authenticated datagram contracts diverged")
	}
}

func TestConnectionAndRegistryResourceBounds(t *testing.T) {
	f := newFixture(t, Config{MaxConnections: 1})
	f.register(t, deviceA, randomKey(t))
	if conn, err := tls.DialWithDialer(&net.Dialer{Timeout: time.Second}, "tcp", f.address, f.clientTLS); err == nil {
		conn.Close()
		t.Fatal("connection resource bound exceeded")
	}
	registry := newFixture(t, Config{MaxDevices: 1})
	conn, _ := registry.register(t, deviceA, randomKey(t))
	conn.Close()
	until(t, func() bool { return registry.server.Snapshot().OnlineDevices == 0 })
	other := registry.dial(t)
	write(t, other, Message{Op: "register", AccessKey: registry.access, DeviceID: deviceB, OwnerKey: randomKey(t)})
	if read(t, other, "error").Error != "capacity" {
		t.Fatal("durable registry grew past its technical bound")
	}
}
