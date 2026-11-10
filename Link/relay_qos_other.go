//go:build !darwin && !windows

package main

import "net"

func prioritizeRelay(conn *net.TCPConn) net.Conn { return conn }
