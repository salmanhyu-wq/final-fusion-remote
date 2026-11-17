package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func loginFrame(t *testing.T, conn net.Conn, kind byte, id uint16, payload []byte) {
	t.Helper()
	frame := make([]byte, 5+len(payload))
	frame[0] = kind
	binary.BigEndian.PutUint16(frame[1:], id)
	binary.BigEndian.PutUint16(frame[3:], uint16(len(payload)))
	copy(frame[5:], payload)
	if _, err := conn.Write(frame); err != nil {
		t.Fatal(err)
	}
}

func expectLoginFrame(t *testing.T, conn net.Conn, kind byte, id uint16, payload string) {
	t.Helper()
	var header [5]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		t.Fatalf("waiting for frame %d on connection %d: %v", kind, id, err)
	}
	body := make([]byte, binary.BigEndian.Uint16(header[3:]))
	if _, err := io.ReadFull(conn, body); err != nil {
		t.Fatal(err)
	}
	if header[0] != kind || binary.BigEndian.Uint16(header[1:]) != id || string(body) != payload {
		t.Fatalf("got frame %d on connection %d with %q, want frame %d on connection %d with %q",
			header[0], binary.BigEndian.Uint16(header[1:]), body, kind, id, payload)
	}
}

func TestLoginWindowBridgesApprovedDevices(t *testing.T) {
	invitation := bytes.Repeat([]byte{1}, 16)
	approved, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	denied, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	trusted := map[string]bool{hex.EncodeToString(devicePublic(approved)): true}
	for _, tc := range []struct {
		name  string
		key   *ecdsa.PrivateKey
		ready bool
		ok    byte
	}{
		{"previously approved", approved, true, 1},
		{"unknown device", denied, true, 0},
		{"screen sharing turned off", approved, false, 2},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			sender, receiver := net.Pipe()
			defer receiver.Close()
			_ = receiver.SetDeadline(time.Now().Add(3 * time.Second))
			// The Screen Sharing app probes on one connection, closes it when the
			// password is submitted, and signs in on a second connection.
			locals := make(chan net.Conn, 2)
			finished := make(chan struct{})
			go func() {
				bridgeLoginWindow(ctx, sender, invitation, trusted, loginBackend{
					account: "studio",
					ready:   func(context.Context) bool { return tc.ready },
					dial: func(context.Context) (net.Conn, error) {
						sharing, local := net.Pipe()
						_ = local.SetDeadline(time.Now().Add(3 * time.Second))
						locals <- local
						return sharing, nil
					},
				}, func(string) {})
				close(finished)
			}()
			id := sha256.Sum256(devicePublic(tc.key))
			greeting := append(append(bytes.Clone(invitation), id[:]...), 0)
			if err := writeFrame(receiver, 1, greeting); err != nil {
				t.Fatal(err)
			}
			if err := answerDevice(receiver, tc.key, greeting); err != nil {
				t.Fatal(err)
			}
			var reply [1]byte
			if _, err := io.ReadFull(receiver, reply[:]); err != nil || reply[0] != tc.ok {
				t.Fatalf("bridge authorization: got %v (%v), want %v", reply, err, tc.ok)
			}
			if tc.ok != 1 {
				<-finished
				if len(locals) != 0 {
					t.Fatal("refused viewer reached macOS Screen Sharing")
				}
				return
			}
			name := make([]byte, 7)
			if _, err := io.ReadFull(receiver, name); err != nil || string(name) != "\x06studio" {
				t.Fatalf("approved viewer did not receive the account name: %q, %v", name, err)
			}

			loginFrame(t, receiver, loginStreamOpen, 1, nil)
			probe := <-locals
			go func() { _, _ = probe.Write([]byte("RFB 003.889\n")) }()
			expectLoginFrame(t, receiver, loginStreamData, 1, "RFB 003.889\n")
			loginFrame(t, receiver, loginStreamData, 1, []byte("RFB 003.889\n"))
			banner := make([]byte, 12)
			if _, err := io.ReadFull(probe, banner); err != nil || string(banner) != "RFB 003.889\n" {
				t.Fatalf("viewer version did not reach Screen Sharing: %q, %v", banner, err)
			}

			// Password submitted: the probe closes and a new connection opens at once.
			loginFrame(t, receiver, loginStreamClose, 1, nil)
			loginFrame(t, receiver, loginStreamOpen, 2, nil)
			if _, err := probe.Read(make([]byte, 1)); err == nil {
				t.Fatal("probe connection stayed open after the viewer closed it")
			}
			login := <-locals
			defer login.Close()
			loginFrame(t, receiver, loginStreamData, 2, []byte("key"))
			control := make([]byte, 3)
			if _, err := io.ReadFull(login, control); err != nil || string(control) != "key" {
				t.Fatalf("sign-in data did not reach the second connection: %q, %v", control, err)
			}
			go func() { _, _ = login.Write([]byte("screen")) }()
			expectLoginFrame(t, receiver, loginStreamData, 2, "screen")

			loginFrame(t, receiver, loginKeepAlive, 0, nil)
			expectLoginFrame(t, receiver, loginKeepAlive, 0, "")

			// Screen Sharing ending a connection is reported to the viewer.
			_ = login.Close()
			expectLoginFrame(t, receiver, loginStreamClose, 2, "")

			cancel()
			select {
			case <-finished:
			case <-time.After(time.Second):
				t.Fatal("boot bridge did not close when the console session changed")
			}
		})
	}
}

func TestSenderClosesRelayBeforeHandoff(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	closed := make(chan websocket.StatusCode, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		socket, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer socket.CloseNow()
		_, _, err = socket.Read(ctx)
		closed <- websocket.CloseStatus(err)
	}))
	defer server.Close()
	socket, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer socket.CloseNow()
	finished := make(chan struct{})
	handoff, stop := context.WithCancel(ctx)
	go func() {
		withRelayViewer(handoff, socket, func(context.Context, net.Conn) {})
		close(finished)
	}()
	stop()
	select {
	case status := <-closed:
		if status != websocket.StatusNormalClosure {
			t.Fatalf("relay lost its sender without a normal close: %v", status)
		}
	case <-ctx.Done():
		t.Fatal("relay did not receive the sender close")
	}
	select {
	case <-finished:
	case <-ctx.Done():
		t.Fatal("sender kept the relay slot after handoff")
	}
}
