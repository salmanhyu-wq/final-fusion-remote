package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// Run against the local Worker with STUDIO_ROOM set to the hash of 32 bytes of 0x13.
func TestLocalWorkerCarriesPinnedTLS(t *testing.T) {
	base := strings.TrimSuffix(os.Getenv("STUDIO_LOCAL_RELAY"), "/")
	if base == "" {
		t.Skip("set STUDIO_LOCAL_RELAY to a local Worker WebSocket address")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	secret := bytes.Repeat([]byte{19}, 32)
	room := sha256.Sum256(secret)
	viewerPath := "/v1/receiver/" + hex.EncodeToString(room[:])
	reject := func(path, token string, status int) {
		t.Helper()
		header := http.Header{}
		if token != "" {
			header.Set("Authorization", "Bearer "+token)
		}
		socket, response, err := websocket.Dial(ctx, base+path, &websocket.DialOptions{HTTPHeader: header})
		if socket != nil {
			_ = socket.CloseNow()
		}
		if err == nil || response == nil || response.StatusCode != status {
			t.Fatalf("expected HTTP %d for %s, got %v, %v", status, path, response, err)
		}
	}
	reject(viewerPath, "", http.StatusServiceUnavailable)
	reject("/v1/sender", hex.EncodeToString(make([]byte, 32)), http.StatusNotFound)
	header := http.Header{"Authorization": {"Bearer " + hex.EncodeToString(secret)}}
	sender, _, err := websocket.Dial(ctx, base+"/v1/sender", &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		t.Fatal(err)
	}
	defer sender.CloseNow()
	receiver, _, err := websocket.Dial(ctx, base+viewerPath, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.CloseNow()
	kind, ready, err := sender.Read(ctx)
	if err != nil || kind != websocket.MessageText || string(ready) != "paired" {
		t.Fatalf("sender was not paired: %s, %v", ready, err)
	}
	reject(viewerPath, "", http.StatusConflict)

	state, err := loadHostState(filepath.Join(t.TempDir(), "host.json"))
	if err != nil {
		t.Fatal(err)
	}
	pin := sha256.Sum256(state.Cert)
	server := tls.Server(websocket.NetConn(ctx, sender, websocket.MessageBinary), &tls.Config{
		MinVersion:   tls.VersionTLS13,
		Certificates: []tls.Certificate{{Certificate: [][]byte{state.Cert}, PrivateKey: ed25519.PrivateKey(state.Key)}},
	})
	client := tls.Client(websocket.NetConn(ctx, receiver, websocket.MessageBinary),
		clientTLS(profile{Pin: hex.EncodeToString(pin[:])}))
	input := []byte("keyboard input")
	screen := bytes.Repeat([]byte("remote screen frame "), 8192)
	done := make(chan error, 1)
	go func() {
		data := make([]byte, len(input))
		if _, err := io.ReadFull(server, data); err != nil {
			done <- err
			return
		}
		if !bytes.Equal(data, input) {
			done <- io.ErrUnexpectedEOF
			return
		}
		_, err := server.Write(screen)
		done <- err
	}()
	if _, err := client.Write(input); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, len(screen))
	if _, err := io.ReadFull(client, data); err != nil || !bytes.Equal(data, screen) {
		t.Fatalf("TLS screen frame changed: %v", err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
