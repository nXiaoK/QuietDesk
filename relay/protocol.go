package relay

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
)

const (
	Version            = 1
	MaxMessageBytes    = 8192
	MaxDatagramPayload = 1152
	DatagramOverhead   = 64
)

// These credentials authorize routing, never the inner desktop TLS/DTLS session.
type Message struct {
	Version      int    `json:"version"`
	Op           string `json:"op"`
	AccessKey    []byte `json:"accessKey,omitempty"`
	DeviceID     string `json:"deviceID,omitempty"`
	OwnerKey     []byte `json:"ownerKey,omitempty"`
	Registration string `json:"registration,omitempty"`
	CircuitID    string `json:"circuitID,omitempty"`
	DatagramID   []byte `json:"datagramID,omitempty"`
	DatagramKey  []byte `json:"datagramKey,omitempty"`
	UDPPort      int    `json:"udpPort,omitempty"`
	Error        string `json:"error,omitempty"`
}

func ReadMessage(r io.Reader) (Message, error) {
	var prefix [4]byte
	var message Message
	if _, err := io.ReadFull(r, prefix[:]); err != nil {
		return message, err
	}
	n := binary.BigEndian.Uint32(prefix[:])
	if n == 0 || n > MaxMessageBytes {
		return message, errors.New("invalid relay message length")
	}
	data := make([]byte, int(n))
	if _, err := io.ReadFull(r, data); err != nil {
		return message, err
	}
	if err := json.Unmarshal(data, &message); err != nil {
		return message, errors.New("invalid relay message")
	}
	if message.Version != Version {
		return message, errors.New("unsupported relay version")
	}
	return message, nil
}

func WriteMessage(w io.Writer, message Message) error {
	message.Version = Version
	data, err := json.Marshal(message)
	if err != nil || len(data) > MaxMessageBytes {
		return errors.New("invalid relay message")
	}
	var prefix [4]byte
	binary.BigEndian.PutUint32(prefix[:], uint32(len(data)))
	for _, part := range [][]byte{prefix[:], data} {
		for len(part) > 0 {
			n, err := w.Write(part)
			if err != nil {
				return err
			}
			if n == 0 {
				return io.ErrShortWrite
			}
			part = part[n:]
		}
	}
	return nil
}

type ReplayWindow struct {
	highest uint64
	bits    uint64
}

func (w *ReplayWindow) Accept(sequence uint64) bool {
	if sequence == 0 {
		return false
	}
	if sequence > w.highest {
		distance := sequence - w.highest
		if distance >= 64 {
			w.bits = 1
		} else {
			w.bits = (w.bits << distance) | 1
		}
		w.highest = sequence
		return true
	}
	distance := w.highest - sequence
	if distance >= 64 || w.bits&(uint64(1)<<distance) != 0 {
		return false
	}
	w.bits |= uint64(1) << distance
	return true
}

type Datagram struct {
	Side       byte
	Downstream bool
	Sequence   uint64
	ID         [16]byte
	Payload    []byte
}

func EncodeDatagram(packet Datagram, key []byte) ([]byte, error) {
	if len(key) != 32 || packet.Side > 1 || packet.Sequence == 0 || len(packet.Payload) > MaxDatagramPayload {
		return nil, errors.New("invalid relay datagram")
	}
	data := make([]byte, 32+len(packet.Payload), DatagramOverhead+len(packet.Payload))
	copy(data[:4], "QDR1")
	data[4] = packet.Side
	if packet.Downstream {
		data[5] = 1
	}
	binary.BigEndian.PutUint64(data[6:14], packet.Sequence)
	copy(data[14:30], packet.ID[:])
	binary.BigEndian.PutUint16(data[30:32], uint16(len(packet.Payload)))
	copy(data[32:], packet.Payload)
	mac := hmac.New(sha256.New, key)
	mac.Write(data)
	return append(data, mac.Sum(nil)...), nil
}

func DecodeDatagram(data, key []byte) (Datagram, error) {
	var packet Datagram
	if len(key) != 32 || len(data) < DatagramOverhead || len(data) > DatagramOverhead+MaxDatagramPayload ||
		string(data[:4]) != "QDR1" || data[4] > 1 || data[5] > 1 ||
		int(binary.BigEndian.Uint16(data[30:32])) != len(data)-DatagramOverhead {
		return packet, errors.New("invalid relay datagram")
	}
	mac := hmac.New(sha256.New, key)
	mac.Write(data[:len(data)-32])
	if !hmac.Equal(mac.Sum(nil), data[len(data)-32:]) {
		return packet, errors.New("unauthenticated relay datagram")
	}
	packet.Side = data[4]
	packet.Downstream = data[5] == 1
	packet.Sequence = binary.BigEndian.Uint64(data[6:14])
	if packet.Sequence == 0 {
		return packet, errors.New("invalid relay sequence")
	}
	copy(packet.ID[:], data[14:30])
	packet.Payload = data[32 : len(data)-32]
	return packet, nil
}
