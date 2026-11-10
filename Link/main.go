package main

import (
	"bytes"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

const (
	trailer = "SR04CONF"
)

type profile struct {
	Relay      string `json:"relay"`
	Room       string `json:"room"`
	Pin        string `json:"pin"`
	Invitation string `json:"invitation"`
}

func validHex(s string, size int) bool {
	b, err := hex.DecodeString(s)
	return err == nil && len(b) == size
}

func (p profile) valid() bool {
	_, err := relayOrigin(p.Relay)
	return err == nil && validHex(p.Room, 32) && validHex(p.Pin, 32) && validHex(p.Invitation, 16)
}

func randomBytes(size int) []byte {
	data := make([]byte, size)
	rand.Read(data)
	return data
}

type hostState struct {
	Cert       []byte          `json:"cert"`
	Key        []byte          `json:"key"`
	MacCert    []byte          `json:"macCert,omitempty"`
	MacKey     []byte          `json:"macKey,omitempty"`
	Invitation string          `json:"invitation"`
	Trusted    map[string]bool `json:"trusted"`
}

func saveJSON(path string, value any) error {
	file, err := os.CreateTemp(filepath.Dir(path), ".studio-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	err = json.NewEncoder(file).Encode(value)
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}

func loadHostState(path string) (hostState, error) {
	var state hostState
	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		if err := json.Unmarshal(raw, &state); err != nil {
			return state, err
		}
		if !validHex(state.Invitation, 16) || len(state.Cert) == 0 || len(state.Key) != ed25519.PrivateKeySize || state.Trusted == nil {
			return state, errors.New(tr("기존 보내기 설정을 읽을 수 없어요.", "Couldn't read the existing sharing settings."))
		}
		if len(state.MacCert) > 0 || len(state.MacKey) > 0 {
			return state, nil
		}
	case os.IsNotExist(err):
		pub, key, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return state, err
		}
		cert, err := newHostCertificate(pub, key)
		if err != nil {
			return state, err
		}
		state = hostState{
			Cert: cert, Key: key, Invitation: hex.EncodeToString(randomBytes(16)),
			Trusted: make(map[string]bool),
		}
	default:
		return state, err
	}

	// Keep the original certificate for already issued Windows receivers.
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return state, err
	}
	state.MacKey, err = x509.MarshalECPrivateKey(key)
	if err != nil {
		return state, err
	}
	state.MacCert, err = newHostCertificate(&key.PublicKey, key)
	if err != nil {
		return state, err
	}
	return state, saveJSON(path, state)
}

func newHostCertificate(publicKey crypto.PublicKey, key crypto.Signer) ([]byte, error) {
	now := time.Now()
	cert := &x509.Certificate{
		SerialNumber: new(big.Int).SetBytes(randomBytes(16)), Subject: pkix.Name{CommonName: "Studio Remote"},
		NotBefore: now.Add(-10 * time.Minute), NotAfter: now.AddDate(5, 0, 0),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	return x509.CreateCertificate(rand.Reader, cert, cert, publicKey, key)
}

type approval struct {
	id     string
	code   string
	result chan bool
}
type gateway struct {
	state     hostState
	path      string
	hostCode  []byte
	out       io.Writer
	lock      sync.Mutex
	pending   *approval
	sink      string
	directTLS *tls.Config
}

func (g *gateway) emit(v any) {
	_ = json.NewEncoder(g.out).Encode(v)
}

func (g *gateway) decide(id string, allow bool, code string) bool {
	g.lock.Lock()
	defer g.lock.Unlock()
	if g.pending == nil || g.pending.id != id {
		return false
	}
	if allow && subtle.ConstantTimeCompare([]byte(g.pending.code), []byte(code)) != 1 {
		return false
	}
	select {
	case g.pending.result <- allow:
		return true
	default:
		return false
	}
}

func (g *gateway) allowed(conn net.Conn, token []byte) bool {
	sum := sha256.Sum256(token)
	id := hex.EncodeToString(sum[:])
	g.lock.Lock()
	if g.state.Trusted[id] {
		g.lock.Unlock()
		return true
	}
	if g.pending != nil {
		g.lock.Unlock()
		_ = writeFrame(conn, 7, []byte(tr("다른 기기의 허용 요청을 처리 중이에요. 잠시 뒤 다시 연결하세요.", "Another device is waiting for approval. Connect again in a moment.")))
		return false
	}
	// The value only compares the two screens; TLS and the device secret authenticate subsequent connections.
	number, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		g.lock.Unlock()
		return false
	}
	code := fmt.Sprintf("%06d", number.Int64())
	p := &approval{hex.EncodeToString(randomBytes(12)), code, make(chan bool, 1)}
	g.pending = p
	_ = conn.SetWriteDeadline(time.Now().Add(4 * time.Second))
	if err := writeFrame(conn, 8, []byte(code)); err != nil {
		g.pending = nil
		g.lock.Unlock()
		return false
	}
	g.lock.Unlock()
	g.emit(map[string]string{"event": "pair", "id": p.id, "code": code})
	accepted := false
	select {
	case accepted = <-p.result:
	case <-time.After(75 * time.Second):
	}
	g.lock.Lock()
	defer g.lock.Unlock()
	g.pending = nil
	if accepted {
		g.state.Trusted[id] = true
		if err := saveJSON(g.path, g.state); err == nil {
			return true
		}
		delete(g.state.Trusted, id)
	}
	_ = conn.SetWriteDeadline(time.Now().Add(4 * time.Second))
	_ = writeFrame(conn, 7, []byte(tr("보내는 맥에서 이 기기를 허용하지 않았어요.", "The host Mac didn't allow this device.")))
	return false
}

func (g *gateway) handle(conn net.Conn) {
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	body, err := readHello(conn)
	id, _ := hex.DecodeString(g.state.Invitation)
	if err != nil || subtle.ConstantTimeCompare(id, body[:16]) != 1 {
		return
	}
	if !g.allowed(conn, body[16:48]) {
		return
	}
	if body[48]&directGreeting != 0 {
		body[48] &^= directGreeting
		if g.directTLS != nil {
			direct, err := chooseDirect(conn, g.directTLS, directAddresses())
			if err != nil {
				return
			}
			if direct != nil {
				defer direct.Close()
				g.forward(direct, body)
				return
			}
		}
	}
	// The first 54 bytes describe the ordinary high-resolution fallback.
	g.forward(conn, body[:min(len(body), 54)])
}

func (g *gateway) forward(conn net.Conn, body []byte) {
	_ = conn.SetDeadline(time.Time{})
	backend, err := net.DialTimeout("tcp4", g.sink, 3*time.Second)
	if err != nil {
		_ = conn.SetWriteDeadline(time.Now().Add(4 * time.Second))
		_ = writeFrame(conn, 7, []byte(tr("보내는 맥이 아직 보낼 준비가 되지 않았어요.", "The host Mac isn't ready to share yet.")))
		return
	}
	defer backend.Close()
	if err := writeFrame(backend, 1, append(bytes.Clone(g.hostCode), body[48:]...)); err != nil {
		return
	}
	done := make(chan struct{}, 2)
	go func() { _, _ = io.Copy(conn, backend); done <- struct{}{} }()
	go func() { _, _ = io.Copy(backend, conn); done <- struct{}{} }()
	<-done
}

func readHello(r io.Reader) ([]byte, error) {
	var h [9]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(h[5:])
	if h[0] != 1 || binary.BigEndian.Uint32(h[1:5]) != 0 || (length != 49 && length != 54 && length != 58) {
		return nil, errors.New("invalid greeting")
	}
	b := make([]byte, length)
	if _, err := io.ReadFull(r, b); err != nil {
		return nil, err
	}
	// A check-only connection does not negotiate a display.
	mode := b[48] &^ directGreeting
	if mode > 2 || (mode == 2 && (length != 49 || b[48] != mode)) {
		return nil, errors.New("invalid receiver mode")
	}
	if length >= 54 {
		flags := b[49]
		width := binary.BigEndian.Uint16(b[50:52])
		height := binary.BigEndian.Uint16(b[52:54])
		if flags < 1 || flags > 3 || width < 640 || width > 8192 || height < 480 || height > 8192 {
			return nil, errors.New("invalid receiver display options")
		}
	}
	if length == 58 {
		width := int(binary.BigEndian.Uint16(b[54:56]))
		height := int(binary.BigEndian.Uint16(b[56:58]))
		if b[48]&directGreeting == 0 || b[49] != 3 || width < 640 || width > 4096 ||
			height < 480 || height > 4096 || width%2 != 0 || height%2 != 0 || width*height > 4096*2160 {
			return nil, errors.New("invalid native pixel request")
		}
	}
	return b, nil
}

func writeFrame(w io.Writer, kind byte, payload []byte) error {
	var h [9]byte
	h[0] = kind
	binary.BigEndian.PutUint32(h[5:], uint32(len(payload)))
	if _, err := w.Write(h[:]); err != nil {
		return err
	}
	if len(payload) > 0 {
		_, err := w.Write(payload)
		return err
	}
	return nil
}

func attachedProfile(path string) (profile, error) {
	var p profile
	f, err := os.Open(path)
	if err != nil {
		return p, err
	}
	defer f.Close()
	tail := make([]byte, len(trailer)+4)
	if _, err = f.Seek(-int64(len(tail)), io.SeekEnd); err != nil {
		return p, err
	}
	if _, err = io.ReadFull(f, tail); err != nil || string(tail[4:]) != trailer {
		return p, errors.New(tr("이 파일에는 보내는 맥의 연결 정보가 없어요.", "This file doesn't contain the host Mac's connection details."))
	}
	n := binary.BigEndian.Uint32(tail)
	if n < 20 || n > 4096 {
		return p, errors.New(tr("연결 설정을 읽을 수 없어요.", "Couldn't read the connection settings."))
	}
	if _, err = f.Seek(-int64(len(tail))-int64(n), io.SeekEnd); err != nil {
		return p, err
	}
	data := make([]byte, n)
	if _, err = io.ReadFull(f, data); err != nil {
		return p, err
	}
	if json.Unmarshal(data, &p) != nil || !p.valid() {
		return profile{}, errors.New(tr("연결 설정이 올바르지 않아요.", "The connection settings are invalid."))
	}
	return p, nil
}

func clientTLS(p profile) *tls.Config {
	pin, _ := hex.DecodeString(p.Pin)
	return &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true, // The exported exact certificate pin replaces the system CA trust store.
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) != 1 {
				return errors.New(tr("보내는 맥을 확인할 수 없어요.", "Couldn't verify the host Mac."))
			}
			cert := state.PeerCertificates[0]
			hash := sha256.Sum256(cert.Raw)
			now := time.Now()
			if subtle.ConstantTimeCompare(pin, hash[:]) != 1 || now.Before(cert.NotBefore) || now.After(cert.NotAfter) {
				return errors.New(tr("보내는 맥의 연결 정보가 바뀌었어요. 보내는 맥에서 받는 앱을 다시 만들어 주세요.", "The host Mac's connection info changed. Create the viewer app again on the host Mac."))
			}
			return nil
		},
	}
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "relay-id" && runtime.GOOS == "darwin" {
		_, room, err := relayIdentity(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println(room)
		return
	}
	if len(os.Args) == 5 && os.Args[1] == "host" && runtime.GOOS == "darwin" {
		if err := serveHost(os.Args[2], os.Args[3], os.Args[4]); err != nil {
			_ = json.NewEncoder(os.Stdout).Encode(map[string]string{"event": "error", "message": err.Error()})
			os.Exit(1)
		}
		return
	}
	if runtime.GOOS == "windows" {
		if err := runWindows(); err != nil {
			showStartupError(err.Error())
		}
		return
	}
	fmt.Fprintln(os.Stderr, "Studio Remote helper")
}
