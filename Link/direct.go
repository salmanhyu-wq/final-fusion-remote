package main

import (
	"crypto/subtle"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/netip"
	"time"
)

const (
	directGreeting byte = 0x80
	directOffer    byte = 13
	directChoice   byte = 14
	directTicket   byte = 15
)

type directCandidate struct {
	Addresses []string `json:"addresses"`
	Port      int      `json:"port"`
	Ticket    string   `json:"ticket"`
}

func directAddresses() []string {
	addresses, _ := net.InterfaceAddrs()
	result := make([]string, 0, 4)
	for _, address := range addresses {
		prefix, err := netip.ParsePrefix(address.String())
		if err == nil {
			ip := prefix.Addr()
			if ip.Is4() && ip.IsGlobalUnicast() {
				result = append(result, ip.String())
			}
		}
		if len(result) == cap(result) {
			break
		}
	}
	return result
}

// Only an approved viewer on the pinned relay can get a one-time direct ticket.
func chooseDirect(relay net.Conn, config *tls.Config, addresses []string) (net.Conn, error) {
	if len(addresses) == 0 {
		return nil, nil
	}
	bind := &net.TCPAddr{}
	if len(addresses) == 1 {
		bind.IP = net.ParseIP(addresses[0])
	}
	listener, err := net.ListenTCP("tcp4", bind)
	if err != nil {
		return nil, nil
	}
	deadline := time.Now().Add(6 * time.Second)
	_ = listener.SetDeadline(deadline)
	ticket := randomBytes(32)
	offer, _ := json.Marshal(directCandidate{addresses, listener.Addr().(*net.TCPAddr).Port, hex.EncodeToString(ticket)})
	ready := make(chan net.Conn, 1)
	go func() {
		defer close(ready)
		for {
			peer, err := listener.AcceptTCP()
			if err != nil {
				return
			}
			if direct := acceptDirectTicket(peer, config, ticket, deadline); direct != nil {
				ready <- direct
				return
			}
		}
	}()
	defer func() {
		_ = listener.Close()
		if unused := <-ready; unused != nil {
			_ = unused.Close()
		}
	}()

	_ = relay.SetDeadline(deadline)
	if err := writeFrame(relay, directOffer, offer); err != nil {
		return nil, err
	}
	choice, err := readDirectPacket(relay, directChoice, 1)
	if err != nil || choice[0] > 1 {
		return nil, errors.New("invalid direct connection choice")
	}
	if choice[0] == 0 {
		return nil, nil
	}
	direct := <-ready
	if direct == nil {
		return nil, errors.New("direct connection expired")
	}
	return direct, nil
}

func acceptDirectTicket(peer net.Conn, config *tls.Config, ticket []byte, deadline time.Time) net.Conn {
	handshakeDeadline := time.Now().Add(2 * time.Second)
	if deadline.Before(handshakeDeadline) {
		handshakeDeadline = deadline
	}
	_ = peer.SetDeadline(handshakeDeadline)
	conn := tls.Server(peer, config)
	proof, err := readDirectPacket(conn, directTicket, len(ticket))
	if err != nil || subtle.ConstantTimeCompare(proof, ticket) != 1 ||
		writeFrame(conn, directChoice, []byte{1}) != nil {
		_ = peer.Close()
		return nil
	}
	return conn
}

func readDirectPacket(reader io.Reader, kind byte, length int) ([]byte, error) {
	var header [9]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	if header[0] != kind || binary.BigEndian.Uint32(header[1:5]) != 0 ||
		binary.BigEndian.Uint32(header[5:]) != uint32(length) {
		return nil, errors.New("invalid direct connection packet")
	}
	data := make([]byte, length)
	_, err := io.ReadFull(reader, data)
	return data, err
}
