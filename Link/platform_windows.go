package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"unsafe"
)

func launchBrowser(url string) error {
	for _, base := range []string{os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles"), os.Getenv("LOCALAPPDATA")} {
		if base == "" {
			continue
		}
		for _, parts := range [][]string{{"Microsoft", "Edge", "Application", "msedge.exe"}, {"Google", "Chrome", "Application", "chrome.exe"}} {
			path := filepath.Join(append([]string{base}, parts...)...)
			if _, err := os.Stat(path); err == nil {
				process := exec.Command(path, "--app="+url)
				if err := process.Start(); err == nil {
					return process.Process.Release()
				}
			}
		}
	}
	return errors.New(tr("Microsoft Edge 또는 Google Chrome을 설치한 뒤 다시 열어 주세요.", "Install Microsoft Edge or Google Chrome, then open this again."))
}

func showStartupError(message string) {
	caption, _ := syscall.UTF16PtrFromString(tr("파이널 퓨전", "Final Fusion"))
	content, _ := syscall.UTF16PtrFromString(message)
	_, _, _ = syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(
		0, uintptr(unsafe.Pointer(content)), uintptr(unsafe.Pointer(caption)), 0x10)
}

// systemKorean reports whether the Windows display language is Korean (LANG_KOREAN = 0x12).
func systemKorean() bool {
	language, _, _ := syscall.NewLazyDLL("kernel32.dll").NewProc("GetUserDefaultUILanguage").Call()
	return language&0x3ff == 0x12
}

// detectKeyboardLayout reads the firmware manufacturer that Windows records for the machine.
func detectKeyboardLayout() string {
	path, _ := syscall.UTF16PtrFromString(`HARDWARE\DESCRIPTION\System\BIOS`)
	var key syscall.Handle
	if syscall.RegOpenKeyEx(syscall.HKEY_LOCAL_MACHINE, path, 0, syscall.KEY_READ, &key) != nil {
		return "pc"
	}
	defer syscall.RegCloseKey(key)
	for _, name := range []string{"SystemManufacturer", "BaseBoardManufacturer"} {
		if appleManufacturer(registryString(key, name)) {
			return "mac"
		}
	}
	return "pc"
}

func registryString(key syscall.Handle, name string) string {
	value, _ := syscall.UTF16PtrFromString(name)
	var kind, size uint32
	if syscall.RegQueryValueEx(key, value, nil, &kind, nil, &size) != nil || kind != syscall.REG_SZ || size < 2 || size > 1024 {
		return ""
	}
	buffer := make([]uint16, size/2+1)
	if syscall.RegQueryValueEx(key, value, nil, &kind, (*byte)(unsafe.Pointer(&buffer[0])), &size) != nil {
		return ""
	}
	return syscall.UTF16ToString(buffer)
}
