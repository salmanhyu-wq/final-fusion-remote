package main

import "syscall"

func loginWindowActive() bool {
	var console syscall.Stat_t
	return syscall.Stat("/dev/console", &console) == nil && console.Uid == 0
}
