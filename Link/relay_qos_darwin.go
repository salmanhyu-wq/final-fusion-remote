package main

import (
	"net"
	"syscall"
)

// Network service type constants from the macOS SDK's sys/socket.h.
const (
	soNetServiceType     = 0x1116
	netServiceResponsive = 8
)

func prioritizeRelay(conn *net.TCPConn) net.Conn {
	socket, err := conn.SyscallConn()
	if err == nil {
		_ = socket.Control(func(fd uintptr) {
			_ = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, soNetServiceType, netServiceResponsive)
		})
	}
	return conn
}
