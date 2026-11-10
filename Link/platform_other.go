//go:build !windows

package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

func launchBrowser(string) error      { return errors.New("Windows receiver only") }
func showStartupError(message string) { fmt.Fprintln(os.Stderr, message) }

// systemKorean reads the POSIX locale; the Mac app normally sets FINAL_FUSION_LANGUAGE instead.
func systemKorean() bool {
	for _, name := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		if value := os.Getenv(name); value != "" {
			return strings.HasPrefix(strings.ToLower(value), "ko")
		}
	}
	return false
}

// detectKeyboardLayout: the browser viewer only runs on Windows; other systems use the PC layout.
func detectKeyboardLayout() string { return "pc" }
