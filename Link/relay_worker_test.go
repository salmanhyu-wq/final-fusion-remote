package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
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
	roomHash := sha256.Sum256(secret)
	room := hex.EncodeToString(roomHash[:])
	viewerPath := "/v2/receiver/" + room
	reject := func(path, token string, status int) {
		t.Helper()
		header := http.Header{}
		if token != "" {
			header.Set("Authorization", token)
		}
		socket, response, err := websocket.Dial(ctx, base+path, &websocket.DialOptions{HTTPHeader: header})
		if socket != nil {
			_ = socket.CloseNow()
		}
		if err == nil || response == nil || response.StatusCode != status {
			t.Fatalf("expected HTTP %d for %s, got %v, %v", status, path, response, err)
		}
	}
	reject("/v1/receiver/"+room, "", http.StatusNotFound)
	reject(viewerPath, "", http.StatusForbidden)
	reject("/v2/sender", "Bearer "+hex.EncodeToString(make([]byte, 32)), http.StatusNotFound)
	auth := "Bearer " + hex.EncodeToString(secret)
	header := http.Header{"Authorization": {auth}}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]any{
		"devices":    []string{hex.EncodeToString(devicePublic(key))},
		"enrollment": strings.Repeat("11", 32),
	})
	origin := "http" + strings.TrimPrefix(base, "ws")
	control, err := http.NewRequestWithContext(ctx, http.MethodPost, origin+"/v2/authorize", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	control.Header.Set("Authorization", auth)
	reply, err := http.DefaultClient.Do(control)
	if err != nil {
		t.Fatal(err)
	}
	_ = reply.Body.Close()
	if reply.StatusCode != http.StatusNoContent {
		t.Fatalf("authorize status: %d", reply.StatusCode)
	}
	sender, _, err := websocket.Dial(ctx, base+"/v2/sender", &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		t.Fatal(err)
	}
	defer sender.CloseNow()
	proof, err := receiverAuthorization(room, http.MethodGet, key)
	if err != nil {
		t.Fatal(err)
	}
	receiver, _, err := websocket.Dial(ctx, base+viewerPath, &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {proof}}})
	if err != nil {
		t.Fatal(err)
	}
	defer receiver.CloseNow()
	kind, ready, err := sender.Read(ctx)
	if err != nil || kind != websocket.MessageText || string(ready) != "paired" {
		t.Fatalf("sender was not paired: %s, %v", ready, err)
	}
	reject(viewerPath, "", http.StatusForbidden)

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
