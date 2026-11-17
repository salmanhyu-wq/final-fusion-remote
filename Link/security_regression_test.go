package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func TestReceiverKeysAreIndependentOfOtherHostsAndLegacyToken(t *testing.T) {
	dir := t.TempDir()
	p := profile{Relay: "https://first.example.com", Room: strings.Repeat("a", 64), Pin: strings.Repeat("b", 64)}
	a, err := receiverKey(dir, p)
	if err != nil {
		t.Fatal(err)
	}
	same, err := receiverKey(dir, p)
	if err != nil {
		t.Fatal(err)
	}
	p.Relay = "https://second.example.com"
	b, err := receiverKey(dir, p)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(devicePublic(a), devicePublic(same)) || bytes.Equal(devicePublic(a), devicePublic(b)) {
		t.Fatal("receiver key must be stable and scoped to one relay origin")
	}
	hello := sha256.Sum256(devicePublic(a))
	reply, err := signDevice(a, hello[:])
	if err != nil {
		t.Fatal(err)
	}
	if !verifyDevice(devicePublic(a), reply, hello[:]) || verifyDevice(devicePublic(b), reply, hello[:]) ||
		verifyDevice(devicePublic(a), reply, append(hello[:], 0)) {
		t.Fatal("another key or a modified transcript was accepted")
	}
}

func TestLoginLogAndStoppedSharingStayBounded(t *testing.T) {
	dir := t.TempDir()
	if !sharingEnabled(dir) {
		t.Fatal("existing setups should retain their initial sharing preference")
	}
	state := filepath.Join(dir, "sharing-state.txt")
	for value, enabled := range map[string]bool{"on": true, "off": false, "bad": false, "on\n": false} {
		if err := os.WriteFile(state, []byte(value), 0600); err != nil {
			t.Fatal(err)
		}
		if sharingEnabled(dir) != enabled {
			t.Fatalf("unexpected sharing state %q", value)
		}
	}
	file, err := os.Create(filepath.Join(dir, "trace.log"))
	if err != nil {
		t.Fatal(err)
	}
	trace := loginWindowTrace{file: file}
	var writers sync.WaitGroup
	for id := 0; id < 4; id++ {
		writers.Go(func() {
			for i := 0; i < 8_000; i++ {
				trace.write(fmt.Sprintf("request %d/%d", id, i))
			}
		})
	}
	writers.Wait()
	trace.close()
	info, err := os.Stat(file.Name())
	if err != nil || info.Size() < 1000 || info.Size() > loginLogLimit {
		t.Fatalf("unexpected log budget: %v, %v", info, err)
	}
}
