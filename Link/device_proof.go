package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net"
	"path/filepath"
	"strings"
	"time"
)

const (
	deviceChallenge = 19
	deviceProof     = 20
	deviceAdmitted  = 21
	publicKeyBytes  = 65
	signatureBytes  = 64
	maxDeviceKeys   = 64
)

func receiverKey(dir string, p profile) (*ecdsa.PrivateKey, error) {
	origin, err := relayOrigin(p.Relay)
	if err != nil {
		return nil, err
	}
	scope := sha256.Sum256([]byte(strings.ToLower(origin.Host + ":" + p.Room + ":" + p.Pin)))
	seed, err := deviceToken(filepath.Join(dir, fmt.Sprintf("device-v2-%x.key", scope)))
	if err != nil {
		return nil, err
	}
	return ecdsa.ParseRawPrivateKey(elliptic.P256(), seed)
}

func devicePublic(key *ecdsa.PrivateKey) []byte {
	public, _ := key.PublicKey.Bytes()
	return public
}

func signDevice(key *ecdsa.PrivateKey, message []byte) ([]byte, error) {
	hash := sha256.Sum256(message)
	r, s, err := ecdsa.Sign(rand.Reader, key, hash[:])
	if err != nil {
		return nil, err
	}
	signature := make([]byte, signatureBytes)
	r.FillBytes(signature[:32])
	s.FillBytes(signature[32:])
	return signature, nil
}

func verifyDevice(public, signature, message []byte) bool {
	key, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), public)
	if err != nil || len(signature) != signatureBytes {
		return false
	}
	hash := sha256.Sum256(message)
	return ecdsa.Verify(key, hash[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:]))
}

func readDeviceFrame(r io.Reader, kind byte, size int) ([]byte, error) {
	var header [9]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	if header[0] != kind || binary.BigEndian.Uint32(header[1:]) != 0 || binary.BigEndian.Uint32(header[5:]) != uint32(size) {
		return nil, errors.New("invalid device proof frame")
	}
	data := make([]byte, size)
	_, err := io.ReadFull(r, data)
	return data, err
}

func peerDevice(conn net.Conn, greeting []byte) (string, bool) {
	nonce := randomBytes(32)
	if writeFrame(conn, deviceChallenge, nonce) != nil {
		return "", false
	}
	proof, err := readDeviceFrame(conn, deviceProof, publicKeyBytes+signatureBytes)
	if err != nil {
		return "", false
	}
	public := proof[:publicKeyBytes]
	id := sha256.Sum256(public)
	message := bytes.Join([][]byte{[]byte("final-fusion-device-v2"), nonce, greeting}, nil)
	if !bytes.Equal(id[:], greeting[16:48]) || !verifyDevice(public, proof[publicKeyBytes:], message) {
		return "", false
	}
	return hex.EncodeToString(public), true
}

func answerDevice(conn net.Conn, key *ecdsa.PrivateKey, greeting []byte) error {
	nonce, err := readDeviceFrame(conn, deviceChallenge, 32)
	if err != nil {
		return err
	}
	message := bytes.Join([][]byte{[]byte("final-fusion-device-v2"), nonce, greeting}, nil)
	proof, err := signDevice(key, message)
	if err != nil {
		return err
	}
	return writeFrame(conn, deviceProof, append(devicePublic(key), proof...))
}

func receiverAuthorization(room, method string, key *ecdsa.PrivateKey) (string, error) {
	stamp := fmt.Sprint(time.Now().Unix())
	nonce := hex.EncodeToString(randomBytes(16))
	message := fmt.Sprintf("final-fusion-relay-v2:%s:%s:%s:%s", method, room, stamp, nonce)
	signature, err := signDevice(key, []byte(message))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("FF2 %x %s %s %x", devicePublic(key), stamp, nonce, signature), nil
}

func enrollmentAuthorization(invitation string) string {
	raw, _ := hex.DecodeString(invitation)
	digest := sha256.Sum256(raw)
	return fmt.Sprintf("Bearer %x", digest)
}
