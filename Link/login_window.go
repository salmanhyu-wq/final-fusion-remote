package main

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"
)

// Version 2 carries several Screen Sharing connections over one approved link.
// The built-in Screen Sharing app closes its first connection when the account
// password is submitted and signs in on a new one.
const loginWindowProtocol = "studio-mac-login-2"

const (
	loginStreamOpen  byte = 1
	loginStreamData  byte = 2
	loginStreamClose byte = 3
	loginKeepAlive   byte = 4

	loginFrameLimit  = 32768
	loginStreamLimit = 8
	loginIdleLimit   = 45 * time.Second
)

func runLoginWindowHost(dir string) error {
	if os.Geteuid() == 0 {
		return errors.New("the login window relay must run as the host account")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	for ctx.Err() == nil {
		if loginWindowActive() {
			trace := &loginWindowTrace{}
			trace.file, _ = os.OpenFile(filepath.Join(dir, "login-window.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
			trace.write("detected the macOS login window")
			loginCtx, cancel := context.WithCancel(ctx)
			go func() {
				defer cancel()
				for loginWindowActive() && relayPause(loginCtx, time.Second) {
				}
			}()
			if err := serveLoginWindow(loginCtx, dir, trace); err != nil {
				trace.write(err.Error())
			}
			trace.write("leaving the macOS login window")
			if trace.file != nil {
				_ = trace.file.Close()
			}
			cancel()
		}
		relayPause(ctx, 2*time.Second)
	}
	return nil
}

type loginWindowTrace struct {
	file *os.File
	last string
}

func (trace *loginWindowTrace) write(message string) {
	if trace.last == message {
		return
	}
	trace.last = message
	if trace.file != nil {
		log.New(trace.file, "", log.LstdFlags|log.Lmicroseconds).Print(message)
	}
}

func serveLoginWindow(ctx context.Context, dir string, trace *loginWindowTrace) error {
	var setup struct{ Relay string }
	settings, err := os.ReadFile(filepath.Join(dir, "relay.json"))
	if err != nil || json.Unmarshal(settings, &setup) != nil {
		return errors.New("missing host settings")
	}
	if _, err := relayOrigin(setup.Relay); err != nil {
		return err
	}
	key, err := os.ReadFile(filepath.Join(dir, "relay.key"))
	if err != nil || len(key) != 32 {
		return errors.New("missing relay identity")
	}
	state, err := readHostState(filepath.Join(dir, "host-state.json"))
	if err != nil {
		return errors.New("could not read approved device settings")
	}
	config, err := hostTLS(state)
	if err != nil {
		return err
	}
	config.NextProtos = []string{loginWindowProtocol}
	invitation, _ := hex.DecodeString(state.Invitation)
	account := hostAccountName(ctx)
	header := http.Header{"Authorization": {"Bearer " + hex.EncodeToString(key)}}
	room := sha256.Sum256(key)
	checkedSlot := false
	report := trace.write
	for ctx.Err() == nil {
		dial, cancelDial := context.WithTimeout(ctx, 8*time.Second)
		socket, err := dialRelay(dial, setup.Relay, "/v1/sender", header)
		cancelDial()
		if err == nil {
			report("ready on the relay")
			withRelayViewer(ctx, socket, func(stream context.Context, pipe net.Conn) {
				report("viewer reached the relay")
				conn := tls.Server(pipe, config)
				_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
				if conn.HandshakeContext(ctx) == nil && conn.ConnectionState().NegotiatedProtocol == loginWindowProtocol {
					report("viewer negotiated login window transport")
					bridgeLoginWindow(stream, conn, invitation, state.Trusted, loginBackend{
						account: account,
						ready:   systemScreenSharingReady,
						dial:    dialSystemScreenSharing,
					}, report)
				} else {
					report("viewer did not negotiate login window transport")
				}
			})
		} else if errors.As(err, new(relaySlotBusy)) {
			report("relay sender slot is busy")
			if !checkedSlot && loginWindowActive() {
				checkedSlot = true
				if releaseIdleRelaySender(ctx, setup.Relay, hex.EncodeToString(room[:])) {
					report("relay released the previous idle sender")
				}
			}
		} else {
			report("could not reach the relay")
		}
		relayPause(ctx, 2*time.Second)
	}
	return nil
}

func releaseIdleRelaySender(ctx context.Context, origin, room string) bool {
	// V1 refuses this receiver connection if a viewer already owns the session.
	// An accepted pairing means a previous sender is holding an idle slot.
	check, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	socket, err := dialRelay(check, origin, "/v1/receiver/"+room, nil)
	if err != nil {
		return false
	}
	defer socket.CloseNow()
	if !loginWindowActive() {
		_ = socket.Close(websocket.StatusNormalClosure, "")
		return false
	}
	// The V1 worker acknowledges a text message by closing both sockets.
	if socket.Write(check, websocket.MessageText, []byte("release idle sender")) == nil {
		_, _, err = socket.Read(check)
		return websocket.CloseStatus(err) == websocket.StatusPolicyViolation
	}
	return false
}

func systemScreenSharingReady(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	// Require the system's launchd socket before sending a connection to localhost.
	job, err := exec.CommandContext(ctx, "/bin/launchctl", "print", "system/com.apple.screensharing").Output()
	return err == nil && strings.Contains(string(job), "service name = vnc-server") && loginWindowActive()
}

func dialSystemScreenSharing(ctx context.Context) (net.Conn, error) {
	if !systemScreenSharingReady(ctx) {
		return nil, errors.New("macOS Screen Sharing is unavailable at the login window")
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	return (&net.Dialer{}).DialContext(ctx, "tcp", "127.0.0.1:5900")
}

type loginBackend struct {
	// account fills in the user name of the Screen Sharing prompt on an approved viewer.
	account string
	ready   func(context.Context) bool
	dial    func(context.Context) (net.Conn, error)
}

func hostAccountName(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	// The helper is built without cgo, so ask the system for this account's short name.
	name, err := exec.CommandContext(ctx, "/usr/bin/id", "-un").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(name))
}

func bridgeLoginWindow(ctx context.Context, conn net.Conn, invitation []byte, trusted map[string]bool,
	backend loginBackend, report func(string),
) {
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { conn.Close() })
	defer stop()
	_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
	body, err := readHello(conn)
	if err != nil || len(body) != 49 || body[48] != 0 || subtle.ConstantTimeCompare(invitation, body[:16]) != 1 {
		return
	}
	if !trusted[deviceTokenID(body[16:48])] {
		_, _ = conn.Write([]byte{0})
		return
	}
	if !backend.ready(ctx) {
		report("macOS Screen Sharing is unavailable at the login window")
		_, _ = conn.Write([]byte{2})
		return
	}
	account := backend.account
	if len(account) > 255 {
		account = ""
	}
	if _, err := conn.Write(append([]byte{1, byte(len(account))}, account...)); err != nil {
		return
	}
	_ = conn.SetDeadline(time.Time{})
	report("approved viewer opened the login window link")
	link := &loginLink{conn: conn, dial: backend.dial, report: report, streams: map[uint16]*loginStream{}}
	report("login window link ended: " + link.serve(ctx))
}

// loginLink logs times, sizes and directions only. It never records payloads.
type loginLink struct {
	conn    net.Conn
	dial    func(context.Context) (net.Conn, error)
	report  func(string)
	sending sync.Mutex
	lock    sync.Mutex
	streams map[uint16]*loginStream
	opened  int
}

type loginStream struct {
	number   int
	backend  net.Conn
	toMac    atomic.Int64
	toViewer atomic.Int64
}

func (link *loginLink) send(kind byte, id uint16, payload []byte) error {
	frame := make([]byte, 5+len(payload))
	frame[0] = kind
	binary.BigEndian.PutUint16(frame[1:], id)
	binary.BigEndian.PutUint16(frame[3:], uint16(len(payload)))
	copy(frame[5:], payload)
	link.sending.Lock()
	defer link.sending.Unlock()
	_ = link.conn.SetWriteDeadline(time.Now().Add(20 * time.Second))
	_, err := link.conn.Write(frame)
	_ = link.conn.SetWriteDeadline(time.Time{})
	return err
}

func (link *loginLink) serve(ctx context.Context) string {
	defer link.closeAll()
	var header [5]byte
	for {
		_ = link.conn.SetReadDeadline(time.Now().Add(loginIdleLimit))
		if _, err := io.ReadFull(link.conn, header[:]); err != nil {
			if errors.Is(err, io.EOF) {
				return "viewer closed the link"
			}
			if ctx.Err() != nil || !loginWindowActive() {
				return "the Mac left the login window"
			}
			return "viewer link stopped responding"
		}
		id := binary.BigEndian.Uint16(header[1:])
		length := int(binary.BigEndian.Uint16(header[3:]))
		if length > loginFrameLimit {
			return "viewer sent an oversized frame"
		}
		payload := make([]byte, length)
		if _, err := io.ReadFull(link.conn, payload); err != nil {
			return "viewer link broke inside a frame"
		}
		switch header[0] {
		case loginStreamOpen:
			link.open(ctx, id)
		case loginStreamData:
			link.forward(id, payload)
		case loginStreamClose:
			if stream := link.stream(id); stream != nil {
				link.finish(id, stream, "viewer", false)
			}
		case loginKeepAlive:
			if link.send(loginKeepAlive, 0, nil) != nil {
				return "could not answer the viewer"
			}
		default:
			return "viewer sent an unknown frame"
		}
	}
}

func (link *loginLink) stream(id uint16) *loginStream {
	link.lock.Lock()
	defer link.lock.Unlock()
	return link.streams[id]
}

func (link *loginLink) open(ctx context.Context, id uint16) {
	if previous := link.stream(id); previous != nil {
		link.finish(id, previous, "viewer", false)
	}
	link.lock.Lock()
	busy := len(link.streams) >= loginStreamLimit
	link.opened++
	stream := &loginStream{number: link.opened}
	link.lock.Unlock()
	if busy {
		link.report(fmt.Sprintf("screen sharing connection %d refused: too many at once", stream.number))
		_ = link.send(loginStreamClose, id, nil)
		return
	}
	backend, err := link.dial(ctx)
	if err != nil {
		link.report(fmt.Sprintf("screen sharing connection %d: macOS Screen Sharing did not accept it", stream.number))
		_ = link.send(loginStreamClose, id, nil)
		return
	}
	stream.backend = backend
	link.lock.Lock()
	link.streams[id] = stream
	link.lock.Unlock()
	link.report(fmt.Sprintf("screen sharing connection %d opened", stream.number))
	go func() {
		buffer := make([]byte, 16384)
		for {
			count, err := backend.Read(buffer)
			if count > 0 {
				stream.toViewer.Add(int64(count))
				if link.send(loginStreamData, id, buffer[:count]) != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		link.finish(id, stream, "macOS Screen Sharing", true)
	}()
}

func (link *loginLink) forward(id uint16, payload []byte) {
	stream := link.stream(id)
	if stream == nil || len(payload) == 0 {
		return
	}
	stream.toMac.Add(int64(len(payload)))
	_ = stream.backend.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if _, err := stream.backend.Write(payload); err != nil {
		link.finish(id, stream, "macOS Screen Sharing", true)
	}
}

func (link *loginLink) finish(id uint16, stream *loginStream, closedBy string, notify bool) {
	link.lock.Lock()
	current := link.streams[id] == stream
	if current {
		delete(link.streams, id)
	}
	link.lock.Unlock()
	if !current {
		return
	}
	_ = stream.backend.Close()
	if notify {
		_ = link.send(loginStreamClose, id, nil)
	}
	link.report(fmt.Sprintf("screen sharing connection %d closed first by %s: viewer to Mac %d bytes, Mac to viewer %d bytes",
		stream.number, closedBy, stream.toMac.Load(), stream.toViewer.Load()))
}

func (link *loginLink) closeAll() {
	link.lock.Lock()
	streams := link.streams
	link.streams = map[uint16]*loginStream{}
	link.lock.Unlock()
	for _, stream := range streams {
		_ = stream.backend.Close()
		link.report(fmt.Sprintf("screen sharing connection %d closed with the link: viewer to Mac %d bytes, Mac to viewer %d bytes",
			stream.number, stream.toMac.Load(), stream.toViewer.Load()))
	}
}
