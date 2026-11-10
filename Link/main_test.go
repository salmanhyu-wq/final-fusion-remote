package main

import (
	"bufio"
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func testFrame(t *testing.T, conn io.Reader) (byte, []byte) {
	t.Helper()
	var header [9]byte
	if _, err := io.ReadFull(conn, header[:]); err != nil {
		t.Fatal(err)
	}
	length := binary.BigEndian.Uint32(header[5:])
	if length > 8192 {
		t.Fatal("unexpected frame")
	}
	data := make([]byte, length)
	if _, err := io.ReadFull(conn, data); err != nil {
		t.Fatal(err)
	}
	return header[0], data
}

func TestReadHelloUpdateCheck(t *testing.T) {
	for _, tc := range []struct {
		size int
		mode byte
		want bool
	}{
		{49, 0, true},
		{54, 1, true},
		{49, 2, true},
		{54, 2, false},
		{49, 3, false},
		{49, directGreeting, true},
		{54, directGreeting | 1, true},
		{49, directGreeting | 2, false},
		{58, directGreeting, true},
		{58, 0, false},
	} {
		payload := make([]byte, tc.size)
		payload[48] = tc.mode
		if tc.size >= 54 {
			payload[49] = 3
			binary.BigEndian.PutUint16(payload[50:52], 1440)
			binary.BigEndian.PutUint16(payload[52:54], 900)
		}
		if tc.size == 58 {
			binary.BigEndian.PutUint16(payload[54:56], 2880)
			binary.BigEndian.PutUint16(payload[56:58], 1800)
		}
		var frame bytes.Buffer
		if err := writeFrame(&frame, 1, payload); err != nil {
			t.Fatal(err)
		}
		got, err := readHello(&frame)
		if (err == nil) != tc.want || (err == nil && !bytes.Equal(got, payload)) {
			t.Errorf("size %d mode %d: readHello returned %v", tc.size, tc.mode, err)
		}
	}
}

func TestPairingAndReconnect(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	state, err := loadHostState(path)
	if err != nil {
		t.Fatal(err)
	}
	hostCode := randomBytes(16)
	pin := sha256.Sum256(state.Cert)
	p := profile{"https://relay.example.com", hex.EncodeToString(make([]byte, 32)), hex.EncodeToString(pin[:]), state.Invitation}
	backend, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	auth := make(chan []byte, 3)
	go func() {
		for {
			conn, err := backend.Accept()
			if err != nil {
				return
			}
			_ = conn.SetDeadline(time.Now().Add(4 * time.Second))
			data := make([]byte, 26)
			if _, err := io.ReadFull(conn, data); err == nil {
				auth <- data
				_ = writeFrame(conn, 2, []byte("screen"))
			}
			_ = conn.Close()
		}
	}()
	events, eventSink := io.Pipe()
	defer events.Close()
	defer eventSink.Close()
	eventReader := bufio.NewReader(events)
	g := &gateway{state: state, path: path, hostCode: hostCode, out: eventSink, sink: backend.Addr().String()}
	sock, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer sock.Close()
	listener := tls.NewListener(sock, &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{{
		Certificate: [][]byte{state.Cert}, PrivateKey: ed25519.PrivateKey(state.Key),
	}}})
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go g.handle(conn)
		}
	}()
	dialer := &net.Dialer{Timeout: 4 * time.Second}
	wrong := p
	wrong.Pin = hex.EncodeToString(make([]byte, 32))
	if conn, err := tls.DialWithDialer(dialer, "tcp4", sock.Addr().String(), clientTLS(wrong)); err == nil {
		conn.Close()
		t.Fatal("connection trusted a mismatched certificate")
	}
	join := func(token []byte) net.Conn {
		conn, err := tls.DialWithDialer(dialer, "tcp4", sock.Addr().String(), clientTLS(p))
		if err != nil {
			t.Fatal(err)
		}
		_ = conn.SetDeadline(time.Now().Add(4 * time.Second))
		invitation, _ := hex.DecodeString(p.Invitation)
		if err = writeFrame(conn, 1, append(append(invitation, token...), 1)); err != nil {
			t.Fatal(err)
		}
		return conn
	}
	approve := func(conn net.Conn, accept bool) {
		kind, code := testFrame(t, conn)
		var event map[string]string
		line, err := eventReader.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(line, &event); err != nil {
			t.Fatal(err)
		}
		if kind != 8 || len(code) != 6 || event["code"] != string(code) {
			t.Fatal("comparison code differs")
		}
		select {
		case <-auth:
			t.Fatal("reached capture service before approval")
		default:
		}
		if g.decide(event["id"], true, "") {
			t.Fatal("approved without the receiver's six-digit number")
		}
		if g.decide("another-request", true, string(code)) {
			t.Fatal("approved a different request")
		}
		if !g.decide(event["id"], accept, string(code)) {
			t.Fatal("valid decision did not reach the pending receiver")
		}
	}
	token := randomBytes(32)
	first := join(token)
	approve(first, true)
	if kind, data := testFrame(t, first); kind != 2 || string(data) != "screen" {
		t.Fatal("approved viewer did not reach capture")
	}
	_ = first.Close()
	if data := <-auth; !bytes.Equal(data[9:25], hostCode) || data[25] != 1 {
		t.Fatal("incorrect local credentials")
	}
	next := join(token)
	if kind, _ := testFrame(t, next); kind != 2 {
		t.Fatal("approved device was asked to pair again")
	}
	_ = next.Close()
	<-auth
	unknown := join(randomBytes(32))
	approve(unknown, false)
	if kind, _ := testFrame(t, unknown); kind != 7 {
		t.Fatal("denied device received a screen")
	}
	_ = unknown.Close()
	loaded, err := loadHostState(path)
	hash := sha256.Sum256(token)
	if err != nil || !loaded.Trusted[hex.EncodeToString(hash[:])] || len(loaded.Trusted) != 1 {
		t.Fatal("approval did not persist")
	}
}

func TestReceiverOverlayAndBrowserIsolation(t *testing.T) {
	p := profile{"https://relay.example.com", hex.EncodeToString(make([]byte, 32)), hex.EncodeToString(make([]byte, 32)), hex.EncodeToString(make([]byte, 16))}
	blob, _ := json.Marshal(p)
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(blob)))
	path := filepath.Join(t.TempDir(), "receiver.exe")
	file := append(append(append([]byte("MZ"), blob...), length[:]...), []byte(trailer)...)
	if err := os.WriteFile(path, file, 0600); err != nil {
		t.Fatal(err)
	}
	if got, err := attachedProfile(path); err != nil || got != p {
		t.Fatalf("could not read packaged connection: %v", err)
	}
	v := &browserViewer{profile: p, origin: "http://127.0.0.1:47399", prefix: "/launch-token", last: time.Now()}
	handler := v.handler()
	for _, test := range []struct {
		method, url, origin string
		status              int
	}{
		{"GET", "http://127.0.0.1:47399/launch-token/", "", 200},

		{"GET", "http://127.0.0.1:47399/launch-token/viewer.js", "", 200},
		{"GET", "http://127.0.0.1:47399/incorrect/details", "", 404},
		{"GET", "http://external.example/launch-token/", "", 404},
		{"POST", "http://127.0.0.1:47399/launch-token/disconnect", "http://external.example", 403},
		{"POST", "http://127.0.0.1:47399/launch-token/disconnect", "http://127.0.0.1:47399", 204},
	} {
		req := httptest.NewRequest(test.method, test.url, nil)
		if test.origin != "" {
			req.Header.Set("Origin", test.origin)
		}
		resp := httptest.NewRecorder()
		handler.ServeHTTP(resp, req)
		if resp.Code != test.status {
			t.Errorf("%s: %d != %d", test.url, resp.Code, test.status)
		}
		if resp.Code == http.StatusOK && resp.Header().Get("Cache-Control") != "no-store" {
			t.Error("browser resources may be cached")
		}
	}
}

func TestGatewayForwardsMacDisplayOptions(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "host.json")
	state, err := loadHostState(statePath)
	if err != nil {
		t.Fatal(err)
	}
	device := bytes.Repeat([]byte{7}, 32)
	hash := sha256.Sum256(device)
	state.Trusted[hex.EncodeToString(hash[:])] = true
	invitation, err := hex.DecodeString(state.Invitation)
	if err != nil {
		t.Fatal(err)
	}

	backend, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	_ = backend.SetDeadline(time.Now().Add(3 * time.Second))

	hostCode := bytes.Repeat([]byte{4}, 16)
	g := &gateway{state: state, path: statePath, hostCode: hostCode, out: io.Discard, sink: backend.Addr().String()}
	client, server := net.Pipe()
	defer client.Close()
	go g.handle(server)
	_ = client.SetDeadline(time.Now().Add(3 * time.Second))
	options := []byte{0, 3, 6, 144, 4, 26}
	greeting := []byte{directGreeting, 3, 6, 144, 4, 26, 11, 64, 7, 8}
	hello := append(append(invitation, device...), greeting...)
	if err := writeFrame(client, 1, hello); err != nil {
		t.Fatal(err)
	}

	conn, err := backend.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	kind, payload := testFrame(t, conn)
	if kind != 1 || !bytes.Equal(payload, append(hostCode, options...)) {
		t.Fatal("relay fallback must keep the high preset without the native dimensions")
	}
}

func TestAppleManufacturer(t *testing.T) {
	for name, want := range map[string]bool{"Apple Inc.": true, " apple inc. ": true, "LENOVO": false, "": false, "Dell Inc.": false} {
		if appleManufacturer(name) != want {
			t.Fatalf("appleManufacturer(%q) = %v", name, !want)
		}
	}
	if keyboardLayout != "mac" && keyboardLayout != "pc" {
		t.Fatalf("unexpected keyboard layout %q", keyboardLayout)
	}
}
