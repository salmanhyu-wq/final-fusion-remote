package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

func TestDirectConnectionChoice(t *testing.T) {
	for _, direct := range []bool{true, false} {
		t.Run(strconv.FormatBool(direct), func(t *testing.T) {
			state, err := loadHostState(filepath.Join(t.TempDir(), "host.json"))
			if err != nil {
				t.Fatal(err)
			}
			tlsServer, err := hostTLS(state)
			if err != nil {
				t.Fatal(err)
			}
			relayServer, relayClient := net.Pipe()
			defer relayClient.Close()
			_ = relayClient.SetDeadline(time.Now().Add(5 * time.Second))
			type decision struct {
				conn net.Conn
				err  error
			}
			chosen := make(chan decision, 1)
			go func() {
				defer relayServer.Close()
				conn, err := chooseDirect(relayServer, tlsServer, []string{"127.0.0.1"})
				chosen <- decision{conn, err}
			}()
			kind, payload := testFrame(t, relayClient)
			var offer directCandidate
			if kind != directOffer || json.Unmarshal(payload, &offer) != nil || len(offer.Addresses) != 1 {
				t.Fatal("expected the direct offer on the relay")
			}
			address := net.JoinHostPort(offer.Addresses[0], strconv.Itoa(offer.Port))
			if !direct {
				if err := writeFrame(relayClient, directChoice, []byte{0}); err != nil {
					t.Fatal(err)
				}
				result := <-chosen
				if result.err != nil || result.conn != nil {
					t.Fatal("declining an offer should keep the relay path")
				}
				if conn, err := net.DialTimeout("tcp4", address, time.Second); err == nil {
					conn.Close()
					t.Fatal("the temporary listener stayed open")
				}
				return
			}

			pin := sha256.Sum256(state.Cert)
			clientConfig := clientTLS(profile{Pin: hex.EncodeToString(pin[:])})
			clientConfig.NextProtos = []string{"studio-direct-1"}
			open := func() *tls.Conn {
				t.Helper()
				raw, err := net.DialTimeout("tcp4", address, time.Second)
				if err != nil {
					t.Fatal(err)
				}
				_ = raw.SetDeadline(time.Now().Add(3 * time.Second))
				return tls.Client(raw, clientConfig)
			}
			bad := open()
			err = writeFrame(bad, directTicket, make([]byte, 32))
			if err == nil {
				if _, err := readDirectPacket(bad, directChoice, 1); err == nil {
					t.Fatal("an incorrect ticket was accepted")
				}
			}
			_ = bad.Close()
			ticket, err := hex.DecodeString(offer.Ticket)
			if err != nil || len(ticket) != 32 {
				t.Fatal("invalid one-time ticket")
			}
			peer := open()
			defer peer.Close()
			if err := writeFrame(peer, directTicket, ticket); err != nil {
				t.Fatal(err)
			}
			ack, err := readDirectPacket(peer, directChoice, 1)
			if err != nil || !bytes.Equal(ack, []byte{1}) || peer.ConnectionState().NegotiatedProtocol != "studio-direct-1" {
				t.Fatal("valid ticket was not acknowledged over pinned TLS")
			}
			if err := writeFrame(relayClient, directChoice, []byte{1}); err != nil {
				t.Fatal(err)
			}
			result := <-chosen
			if result.err != nil || result.conn == nil {
				t.Fatalf("direct path not selected: %v", result.err)
			}
			defer result.conn.Close()
			frame := []byte("screen frame over direct TLS")
			if _, err := result.conn.Write(frame); err != nil {
				t.Fatal(err)
			}
			received := make([]byte, len(frame))
			if _, err := io.ReadFull(peer, received); err != nil || !bytes.Equal(frame, received) {
				t.Fatal("screen bytes did not arrive on the direct connection")
			}
		})
	}
}
