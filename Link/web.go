package main

import (
	"context"
	"embed"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"html"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed ui/*
var ui embed.FS

var releaseVersion = "dev"

type browserSession struct {
	conn      net.Conn
	streaming bool
	write     sync.Mutex
}
type browserViewer struct {
	profile        profile
	token          []byte
	prefix, origin string
	mux            *http.ServeMux
	lock           sync.Mutex
	peer           *browserSession
	connecting     bool
	last           time.Time
	stop           func()
}

func runWindows() error {
	path, err := os.Executable()
	if err != nil {
		return err
	}
	profile, err := attachedProfile(path)
	if err != nil {
		return err
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return err
	}
	dir := filepath.Join(base, "Final Fusion")
	if err = os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	token, err := deviceToken(filepath.Join(dir, "device.key"))
	if err != nil {
		return err
	}
	socket, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return err
	}
	defer socket.Close()
	viewer := &browserViewer{profile: profile, token: token, origin: "http://" + socket.Addr().String(),
		prefix: "/" + hex.EncodeToString(randomBytes(24)), last: time.Now()}
	server := &http.Server{Handler: viewer.handler(), ReadHeaderTimeout: 5 * time.Second, MaxHeaderBytes: 8192}
	viewer.stop = func() { _ = server.Close() }
	if err = launchBrowser(viewer.origin + viewer.prefix + "/"); err != nil {
		return err
	}
	go viewer.watch()
	err = server.Serve(socket)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func deviceToken(path string) ([]byte, error) {
	if data, err := os.ReadFile(path); err == nil {
		if len(data) != 32 {
			return nil, errors.New(tr("저장된 기기 정보를 읽을 수 없어요.", "Couldn't read the saved device info."))
		}
		return data, nil
	} else if !os.IsNotExist(err) {
		return nil, err
	}
	data := randomBytes(32)
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if os.IsExist(err) {
		return deviceToken(path)
	}
	if err != nil {
		return nil, err
	}
	if _, err = file.Write(data); err != nil {
		_ = file.Close()
		_ = os.Remove(path)
		return nil, err
	}
	return data, file.Close()
}

func (v *browserViewer) handler() http.Handler {
	v.mux = http.NewServeMux()
	for url, asset := range map[string]string{"/": "index.html", "/style.css": "style.css", "/viewer.js": "viewer.js", "/icon.svg": "icon.svg", "/patch.png": "patch.png", "/agent": "receive-agent.txt", "/agent-en": "receive-agent-en.txt"} {
		v.mux.HandleFunc("GET "+v.prefix+url, func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != v.prefix+url {
				http.NotFound(w, r)
				return
			}
			data, err := ui.ReadFile("ui/" + asset)
			if err != nil {
				http.NotFound(w, r)
				return
			}
			mime := map[string]string{"index.html": "text/html; charset=utf-8", "style.css": "text/css", "viewer.js": "text/javascript", "icon.svg": "image/svg+xml", "patch.png": "image/png", "receive-agent.txt": "text/plain; charset=utf-8", "receive-agent-en.txt": "text/plain; charset=utf-8"}
			w.Header().Set("Content-Type", mime[asset])
			if asset == "index.html" {
				page := strings.ReplaceAll(string(data), "__STUDIO_VERSION__", html.EscapeString(releaseVersion))
				data = []byte(strings.ReplaceAll(page, "__STUDIO_KEYBOARD__", keyboardLayout))
			}
			_, _ = w.Write(data)
		})
	}
	v.mux.HandleFunc("POST "+v.prefix+"/connect", v.connect)
	v.mux.HandleFunc("GET "+v.prefix+"/stream", v.stream)
	v.mux.HandleFunc("POST "+v.prefix+"/input", v.input)
	v.mux.HandleFunc("POST "+v.prefix+"/pulse", func(w http.ResponseWriter, r *http.Request) {
		var data []byte
		if stamp, err := strconv.ParseUint(r.URL.Query().Get("stamp"), 10, 64); err == nil {
			data = binary.BigEndian.AppendUint64(nil, stamp)
		}
		v.forwardFrame(w, 6, data)
	})
	v.mux.HandleFunc("POST "+v.prefix+"/diagnostics", func(w http.ResponseWriter, r *http.Request) {
		data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 8192))
		if err != nil || !json.Valid(data) {
			http.Error(w, tr("잘못된 연결 상태 정보예요.", "Invalid connection info."), http.StatusBadRequest)
			return
		}
		v.forwardFrame(w, 9, data)
	})
	v.mux.HandleFunc("POST "+v.prefix+"/disconnect", func(w http.ResponseWriter, r *http.Request) {
		v.lock.Lock()
		peer := v.peer
		v.lock.Unlock()
		if peer != nil {
			v.drop(peer)
		}
		w.WriteHeader(http.StatusNoContent)
	})
	v.mux.HandleFunc("POST "+v.prefix+"/exit", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
		if v.stop != nil {
			time.AfterFunc(150*time.Millisecond, v.stop)
		}
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != strings.TrimPrefix(v.origin, "http://") || !strings.HasPrefix(r.URL.Path, v.prefix+"/") {
			http.NotFound(w, r)
			return
		}
		if r.Method == "POST" && r.Header.Get("Origin") != v.origin {
			http.Error(w, tr("허용되지 않은 요청이에요.", "Request not allowed."), 403)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; frame-ancestors 'none'; base-uri 'none'")
		v.lock.Lock()
		v.last = time.Now()
		v.lock.Unlock()
		v.mux.ServeHTTP(w, r)
	})
}

func (v *browserViewer) forwardFrame(w http.ResponseWriter, kind byte, data []byte) {
	v.lock.Lock()
	peer := v.peer
	v.lock.Unlock()
	if peer != nil {
		peer.write.Lock()
		_ = peer.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
		err := writeFrame(peer.conn, kind, data)
		peer.write.Unlock()
		if err != nil {
			v.drop(peer)
			http.Error(w, tr("연결이 끊겼어요.", "The connection dropped."), http.StatusBadGateway)
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}

func (v *browserViewer) watch() {
	timer := time.NewTicker(30 * time.Second)
	defer timer.Stop()
	for range timer.C {
		v.lock.Lock()
		idle := time.Since(v.last) > 3*time.Minute
		peer := v.peer
		v.lock.Unlock()
		if idle {
			if peer != nil {
				v.drop(peer)
			}
			v.stop()
			return
		}
	}
}

func (v *browserViewer) connect(w http.ResponseWriter, r *http.Request) {
	v.lock.Lock()
	if v.connecting || v.peer != nil {
		v.lock.Unlock()
		http.Error(w, tr("이미 연결을 준비하고 있어요.", "Already preparing a connection."), 409)
		return
	}
	v.connecting = true
	v.lock.Unlock()
	defer func() { v.lock.Lock(); v.connecting = false; v.lock.Unlock() }()
	query := r.URL.Query()
	options, large, err := displayRequest(query.Get("width"), query.Get("height"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	conn, err := connectTLS(v.profile)
	if err != nil {
		http.Error(w, tr("연결할 수 없어요. 인터넷 연결을 확인하고, 보내는 맥이 보내기 중인지 살펴보세요.", "Couldn't connect. Check your internet and make sure the host Mac is sharing."), 502)
		return
	}
	_ = conn.SetWriteDeadline(time.Now().Add(4 * time.Second))
	id, _ := hex.DecodeString(v.profile.Invitation)
	quality := byte(0)
	if large || query.Get("quality") == "retina" {
		quality = 1
	}
	hello := append(append(append(id, v.token...), quality), options...)
	if err = writeFrame(conn, 1, hello); err != nil {
		_ = conn.Close()
		http.Error(w, tr("연결 요청을 보낼 수 없어요.", "Couldn't send the connection request."), 502)
		return
	}
	if r.Context().Err() != nil {
		_ = conn.Close()
		return
	}
	v.lock.Lock()
	v.peer = &browserSession{conn: conn}
	v.lock.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func displayRequest(width, height string) ([]byte, bool, error) {
	if width == "" && height == "" {
		return nil, false, nil
	}
	w, wErr := strconv.Atoi(width)
	h, hErr := strconv.Atoi(height)
	if wErr != nil || hErr != nil || w < 640 || w > 8192 || h < 480 || h > 8192 {
		return nil, false, errors.New(tr("화면 크기를 읽지 못했어요.", "Couldn't read the screen size."))
	}
	data := []byte{2, 0, 0, 0, 0} // Fit to the receiver's aspect ratio, with the sender's cursor.
	binary.BigEndian.PutUint16(data[1:3], uint16(w))
	binary.BigEndian.PutUint16(data[3:5], uint16(h))
	return data, w > 1920 || h > 1200, nil
}

func (v *browserViewer) drop(peer *browserSession) {
	v.lock.Lock()
	if v.peer == peer {
		v.peer = nil
	}
	v.lock.Unlock()
	_ = peer.conn.Close()
}

func (v *browserViewer) stream(w http.ResponseWriter, r *http.Request) {
	v.lock.Lock()
	peer := v.peer
	if peer == nil || peer.streaming {
		v.lock.Unlock()
		http.Error(w, tr("연결이 없어요.", "Not connected."), 409)
		return
	}
	peer.streaming = true
	v.lock.Unlock()
	defer v.drop(peer)
	controller := http.NewResponseController(w)
	w.Header().Set("Content-Type", "application/octet-stream")
	_ = controller.Flush()
	go func(ctx context.Context) {
		<-ctx.Done()
		_ = peer.conn.Close()
	}(r.Context())
	buffer := make([]byte, 64*1024)
	for {
		_ = peer.conn.SetReadDeadline(time.Now().Add(90 * time.Second))
		n, err := peer.conn.Read(buffer)
		if n > 0 {
			_ = controller.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := w.Write(buffer[:n]); err != nil {
				return
			}
			if controller.Flush() != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func (v *browserViewer) input(w http.ResponseWriter, r *http.Request) {
	var batch []json.RawMessage
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, 20000)).Decode(&batch) != nil || len(batch) > 40 {
		http.Error(w, tr("잘못된 입력이에요.", "Invalid input."), 400)
		return
	}
	v.lock.Lock()
	peer := v.peer
	v.lock.Unlock()
	if peer == nil {
		http.Error(w, tr("연결이 없어요.", "Not connected."), 409)
		return
	}
	peer.write.Lock()
	defer peer.write.Unlock()
	_ = peer.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	for _, event := range batch {
		if len(event) > 512 || writeFrame(peer.conn, 5, event) != nil {
			v.drop(peer)
			return
		}
	}
	w.WriteHeader(http.StatusNoContent)
}
