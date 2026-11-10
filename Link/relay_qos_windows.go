package main

import (
	"net"
	"path/filepath"
	"sync"
	"syscall"
	"unsafe"
)

const (
	qosExcellentEffort = 2 // QOSTrafficTypeExcellentEffort
	qosNonAdaptiveFlow = 2 // QOS_NON_ADAPTIVE_FLOW
)

type qosProcedures struct {
	create, add, close *syscall.LazyProc
}

var loadQoS = sync.OnceValue(func() *qosProcedures {
	getSystemDirectory := syscall.NewLazyDLL("kernel32.dll").NewProc("GetSystemDirectoryW")
	var directory [syscall.MAX_PATH]uint16
	size, _, _ := getSystemDirectory.Call(uintptr(unsafe.Pointer(&directory[0])), uintptr(len(directory)))
	if size == 0 || size >= uintptr(len(directory)) {
		return nil
	}
	library := syscall.NewLazyDLL(filepath.Join(syscall.UTF16ToString(directory[:size]), "qwave.dll"))
	api := &qosProcedures{
		create: library.NewProc("QOSCreateHandle"),
		add:    library.NewProc("QOSAddSocketToFlow"),
		close:  library.NewProc("QOSCloseHandle"),
	}
	if api.create.Find() != nil || api.add.Find() != nil || api.close.Find() != nil {
		return nil
	}
	return api
})

type relayQoSConn struct {
	*net.TCPConn
	release func()
}

func (conn *relayQoSConn) Close() error {
	conn.release()
	return conn.TCPConn.Close()
}

func prioritizeRelay(conn *net.TCPConn) net.Conn {
	api := loadQoS()
	if api == nil {
		return conn
	}
	socket, err := conn.SyscallConn()
	if err != nil {
		return conn
	}
	version := struct{ major, minor uint16 }{major: 1}
	var handle syscall.Handle
	ok, _, _ := api.create.Call(uintptr(unsafe.Pointer(&version)), uintptr(unsafe.Pointer(&handle)))
	if ok == 0 {
		return conn
	}
	release := sync.OnceFunc(func() { api.close.Call(uintptr(handle)) })
	var added uintptr
	var flowID uint32
	err = socket.Control(func(fd uintptr) {
		added, _, _ = api.add.Call(uintptr(handle), fd, 0, qosExcellentEffort, qosNonAdaptiveFlow, uintptr(unsafe.Pointer(&flowID)))
	})
	if err != nil || added == 0 {
		release()
		return conn
	}
	return &relayQoSConn{TCPConn: conn, release: release}
}
