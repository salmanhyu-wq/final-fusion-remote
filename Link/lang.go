package main

import (
	"os"
	"strings"
)

// korean follows the operating system language. The Mac app passes its choice in
// FINAL_FUSION_LANGUAGE; the Windows viewer asks Windows for the UI language.
var korean = detectKorean()

func detectKorean() bool {
	if value := strings.ToLower(os.Getenv("FINAL_FUSION_LANGUAGE")); value != "" {
		return strings.HasPrefix(value, "ko")
	}
	return systemKorean()
}

// tr returns the Korean or English text for the current language.
func tr(ko, en string) string {
	if korean {
		return ko
	}
	return en
}

// keyboardLayout is "mac" when Windows runs on Apple hardware (Boot Camp), where the Apple
// keyboard's Command key arrives as the Windows key; otherwise "pc".
var keyboardLayout = detectKeyboardLayout()

func appleManufacturer(name string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(name)), "apple")
}
