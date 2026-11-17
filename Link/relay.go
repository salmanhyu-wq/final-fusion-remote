package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

var relayHost = regexp.MustCompile(`^[A-Za-z0-9]+(?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9]+(?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$`)

type relaySlotBusy struct{}

func (relaySlotBusy) Error() string {
	return tr("다른 기기가 이미 연결 중이에요. 잠시 뒤 다시 시도하세요.", "Another device is already connected. Try again in a moment.")
}

func relayOrigin(value string) (*url.URL, error) {
	u, err := url.Parse(value)
	if err != nil || u.Scheme != "https" || !relayHost.MatchString(u.Host) ||
		u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || (u.Path != "" && u.Path != "/") {
		return nil, errors.New(tr("https://로 시작하는 연결 서버 주소를 확인하세요.", "Check the connection server address. It must start with https://."))
	}
	u.Path = ""
	return u, nil
}

func relayIdentity(dir string) ([]byte, string, error) {
	if err := os.MkdirAll(dir, 0700); err != nil {
		return nil, "", err
	}
	key, err := deviceToken(filepath.Join(dir, "relay.key"))
	if err != nil {
		return nil, "", err
	}
	room := sha256.Sum256(key)
	return key, hex.EncodeToString(room[:]), nil
}

var relayHTTP = &http.Client{
	Transport:     relayTransport(),
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func relayTransport() *http.Transport {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	dial := transport.DialContext
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		conn, err := dial(ctx, network, address)
		if err != nil {
			return nil, err
		}
		if tcp, ok := conn.(*net.TCPConn); ok {
			return prioritizeRelay(tcp), nil
		}
		return conn, nil
	}
	return transport
}

func dialRelay(ctx context.Context, origin, path string, headers http.Header) (*websocket.Conn, error) {
	u, err := relayOrigin(origin)
	if err != nil {
		return nil, err
	}
	u.Scheme = "wss"
	u.Path = path
	conn, response, err := websocket.Dial(ctx, u.String(), &websocket.DialOptions{
		HTTPClient: relayHTTP, HTTPHeader: headers, CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		if response != nil && response.StatusCode == http.StatusConflict {
			return nil, relaySlotBusy{}
		}
		return nil, errors.New(tr("연결 서버에 닿지 않았어요. 인터넷 연결을 확인하고, 보내는 맥이 보내기 중인지 살펴보세요.", "Couldn't reach the connection server. Check your internet and make sure the host Mac is sharing."))
	}
	conn.SetReadLimit(65536)
	return conn, nil
}

func relayControl(ctx context.Context, origin, method, path, authorization string, body []byte) (int, error) {
	u, err := relayOrigin(origin)
	if err != nil {
		return 0, err
	}
	u.Path = path
	request, err := http.NewRequestWithContext(ctx, method, u.String(), bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	request.Header.Set("Authorization", authorization)
	response, err := relayHTTP.Do(request)
	if err != nil {
		return 0, err
	}
	_ = response.Body.Close()
	return response.StatusCode, nil
}

func privateHostSocket(path string) bool {
	if !filepath.IsAbs(path) || filepath.Clean(path) != path {
		return false
	}
	dir, err := os.Lstat(filepath.Dir(path))
	if err != nil || !dir.IsDir() || dir.Mode().Perm() != 0700 {
		return false
	}
	entry, err := os.Lstat(path)
	return err == nil && entry.Mode().Type() == os.ModeSocket && entry.Mode().Perm() == 0600
}

func serveHost(origin, dir, localSocket string) error {
	if !privateHostSocket(localSocket) {
		return errors.New(tr("화면 보내기 연결을 열 수 없어요.", "Couldn't open the screen sharing connection."))
	}
	parsed, err := relayOrigin(origin)
	if err != nil {
		return err
	}
	key, room, err := relayIdentity(dir)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, "host-state.json")
	state, err := loadHostState(path)
	if err != nil {
		return err
	}
	input := bufio.NewScanner(os.Stdin)
	if !input.Scan() || !validHex(input.Text(), 16) {
		return errors.New("invalid local startup")
	}
	code, _ := hex.DecodeString(input.Text())
	g := &gateway{state: state, path: path, hostCode: code, out: os.Stdout, sink: localSocket}
	pin := sha256.Sum256(state.Cert)
	macPin := sha256.Sum256(state.MacCert)
	receiver := struct {
		profile
		MacPin        string `json:"macPin"`
		InteractionV1 bool   `json:"interactionV1"`
	}{profile{parsed.String(), room, hex.EncodeToString(pin[:]), state.Invitation}, hex.EncodeToString(macPin[:]), true}
	tlsConfig, err := hostTLS(state)
	if err != nil {
		return err
	}
	if enabled, err := os.ReadFile(filepath.Join(dir, "direct.txt")); err == nil && strings.TrimSpace(string(enabled)) == "on" {
		g.directTLS = tlsConfig
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		defer cancel()
		for input.Scan() {
			var decision struct {
				ID    string `json:"id"`
				Allow bool   `json:"allow"`
				Code  string `json:"code"`
			}
			if json.Unmarshal(input.Bytes(), &decision) == nil {
				g.decide(decision.ID, decision.Allow, decision.Code)
			}
		}
	}()
	auth := "Bearer " + hex.EncodeToString(key)
	header := http.Header{"Authorization": {auth}}
	g.publish = func(keys []string) error {
		record, _ := json.Marshal(map[string]any{
			"enrollment": strings.TrimPrefix(enrollmentAuthorization(state.Invitation), "Bearer "),
			"devices":    keys,
		})
		control, cancel := context.WithTimeout(ctx, 6*time.Second)
		defer cancel()
		status, err := relayControl(control, origin, http.MethodPost, "/v2/authorize", auth, record)
		if err != nil {
			return err
		}
		if status != http.StatusNoContent {
			return errors.New("relay authorization settings were not accepted")
		}
		return nil
	}
	for ctx.Err() == nil {
		if err := g.publish(g.enrolledKeys()); err == nil {
			break
		}
		g.emit(map[string]string{"event": "relayRetry", "message": tr("연결 서버를 새 보안 버전으로 업데이트해 주세요.", "Update the relay to the new security protocol.")})
		if !relayPause(ctx, 5*time.Second) {
			return nil
		}
	}
	enrollmentDone := make(chan struct{})
	go func() {
		defer close(enrollmentDone)
		for ctx.Err() == nil {
			dial, cancelDial := context.WithTimeout(ctx, 8*time.Second)
			socket, err := dialRelay(dial, origin, "/v2/enrollment-sender", header)
			cancelDial()
			if err == nil {
				withRelayViewer(ctx, socket, func(_ context.Context, pipe net.Conn) {
					g.handle(tls.Server(pipe, tlsConfig), true)
				})
			}
			if !relayPause(ctx, time.Second) {
				return
			}
		}
	}()
	defer func() { cancel(); <-enrollmentDone }()
	wait := time.Second
	for ctx.Err() == nil {
		dial, cancelDial := context.WithTimeout(ctx, 8*time.Second)
		socket, err := dialRelay(dial, origin, "/v2/sender", header)
		cancelDial()
		if err != nil {
			g.emit(map[string]string{"event": "relayRetry", "message": err.Error()})
			if !relayPause(ctx, wait) {
				break
			}
			wait = min(25*time.Second, 2*wait)
			continue
		}
		g.emit(struct {
			Event   string `json:"event"`
			Profile any    `json:"profile"`
		}{"ready", receiver})
		wait = time.Second
		withRelayViewer(ctx, socket, func(_ context.Context, pipe net.Conn) {
			g.handle(tls.Server(pipe, tlsConfig), false)
		})
		if !relayPause(ctx, time.Second) {
			break
		}
	}
	return nil
}

func withRelayViewer(ctx context.Context, socket *websocket.Conn, handle func(context.Context, net.Conn)) {
	// Let the relay see a Close frame before cancelling its reads and writes.
	// The login helper and the desktop sender use the same relay slot.
	closeSocket := sync.OnceFunc(func() { _ = socket.Close(websocket.StatusNormalClosure, "") })
	stop := context.AfterFunc(ctx, closeSocket)
	defer stop()
	defer closeSocket()
	stream := context.WithoutCancel(ctx)
	kind, data, err := socket.Read(stream)
	if err == nil && kind == websocket.MessageText && string(data) == "paired" && ctx.Err() == nil {
		handle(stream, websocket.NetConn(stream, socket, websocket.MessageBinary))
	}
}

func hostTLS(state hostState) (*tls.Config, error) {
	macKey, err := x509.ParseECPrivateKey(state.MacKey)
	if err != nil || len(state.MacCert) == 0 {
		return nil, errors.New(tr("보내는 맥의 보안 설정을 읽을 수 없어요.", "Couldn't read the host Mac's security settings."))
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13,
		NextProtos: []string{"studio-direct-2", "studio-direct-1"},
		// Go selects the first certificate the client can verify. macOS uses P-256.
		Certificates: []tls.Certificate{
			{Certificate: [][]byte{state.Cert}, PrivateKey: ed25519.PrivateKey(state.Key)},
			{Certificate: [][]byte{state.MacCert}, PrivateKey: macKey},
		},
	}, nil
}

func relayPause(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func connectTLS(ctx context.Context, p profile, key *ecdsa.PrivateKey) (*tls.Conn, error) {
	if !p.valid() {
		return nil, errors.New(tr("연결 설정을 읽을 수 없어요.", "Couldn't read the connection settings."))
	}
	ctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	room := strings.ToLower(p.Room)
	path := "/v2/receiver/" + room
	probe, err := receiverAuthorization(room, http.MethodHead, key)
	if err != nil {
		return nil, err
	}
	status, err := relayControl(ctx, p.Relay, http.MethodHead, path, probe, nil)
	if err != nil {
		return nil, err
	}
	var proof string
	switch status {
	case http.StatusNoContent:
		proof, err = receiverAuthorization(room, http.MethodGet, key)
		if err != nil {
			return nil, err
		}
	case http.StatusForbidden:
		path = "/v2/enroll/" + room
		proof = enrollmentAuthorization(p.Invitation)
	default:
		return nil, errors.New("relay does not support secure pairing")
	}
	socket, err := dialRelay(ctx, p.Relay, path, http.Header{"Authorization": {proof}})
	if err != nil {
		return nil, err
	}
	pipe := websocket.NetConn(context.Background(), socket, websocket.MessageBinary)
	conn := tls.Client(pipe, clientTLS(p))
	if err := conn.HandshakeContext(ctx); err != nil {
		_ = socket.CloseNow()
		return nil, err
	}
	return conn, nil
}
