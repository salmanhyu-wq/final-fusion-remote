# Final Fusion 1.0

**I built this for myself.**

The picture quality in Chrome Remote Desktop hurt my eyes, my old MacBook was no longer supported and couldn’t use Apple’s Screen Sharing, and my teenage daughter took the good laptop. So I built a remote desktop app for myself. My first priority was to send the screen from a Mac mini or Mac Studio running without a monitor straight to my old laptop, at the best resolution for its display. I also made sure it supported Mac keyboard shortcuts and trackpad gestures.

I wish you all the best in whatever you do.

**[Download the Mac installer](https://github.com/salmanhyu-wq/final-fusion-remote/releases/download/v1.0.0/Final-Fusion-1.0.0-macOS.dmg)** · macOS 14 or later

**Use a headless Mac mini or Mac Studio from an older laptop, like it was your Mac.** Work with a sharp remote display and familiar Mac shortcuts. If setup or troubleshooting gets stuck, copy the app’s guide into your own AI assistant.

[한국어](README.md) · [Build and test](DEVELOPMENT.md) · [Source terms](LICENSE)

1. On the Mac you want to control, open the downloaded `.dmg` and drag Final Fusion into **Applications**. This installer has not been notarized by Apple, so macOS may show a warning the first time you open it. See [Apple’s guidance](https://support.apple.com/en-us/102445).
2. Open the host and choose **Copy step ①**. The guide helps set up a relay in your own Cloudflare account and enable Screen Recording and Accessibility.
3. Choose your viewer device in step ②. Create its viewer on the host and share it privately with that device. Viewer packages contain connection details.
4. Click **Connect** on the viewer and approve its six-digit code on the host. Enable shortcut permissions on a Mac viewer to use system shortcuts remotely.

A direct connection can match the Mac viewer’s pixel dimensions when available. Otherwise it falls back to High quality. Your own relay is available when direct connection cannot be used.

The host targets macOS 14 or later. The universal Mac viewer targets macOS 11 or later. An earlier version was tested on an Intel MacBook at 2560×1600. The 1.0 checks are local simulations and builds; Apple Silicon Mac viewers and Windows laptops have not been tested on physical receiver hardware. The Windows build targets 64-bit Windows 10 or later with Edge or Chrome; full-screen system keys still need physical testing. Windows and Mac clipboard sharing is unavailable.

This release includes a Mac installer. If you prefer to build from source, see [Build and test](DEVELOPMENT.md). Personal local use and modification are allowed; redistribution rights are reserved. See [LICENSE](LICENSE). When filing issues, share reproducible steps and use the redacted diagnostics. Do not attach a personalized viewer, relay address, pairing code, or a screenshot showing private material.
