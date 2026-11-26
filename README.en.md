# Final Fusion 1.0.24

**I built this for myself.**

The picture quality in Chrome Remote Desktop hurt my eyes, my old MacBook was no longer supported and couldn’t use Apple’s Screen Sharing, and my teenage daughter took the good laptop. So I built a remote desktop app for myself. My first priority was to send the screen from a Mac mini or Mac Studio running without a monitor straight to my old laptop, at the best resolution for its display. I also made sure it supported Mac keyboard shortcuts and trackpad gestures.

I wish you all the best in whatever you do.

**[Download 1.0.24 for Mac](https://github.com/salmanhyu-wq/final-fusion-remote/releases/tag/v1.0.24)** · [Build from source](DEVELOPMENT.md) · The host requires macOS 14 or later.

Version 1.0.24 changes how the Mac viewer closes audio output to address a crash reported on macOS 11. The viewer still reconnects after wake or when the host stops answering connection checks. When upgrading from 1.0.19 or earlier, [update the relay](Relay/SETUP.md) and approve each viewer again. Prepare new viewers before cutting over the relay.

**Use a headless Mac mini or Mac Studio from an older laptop, like it was your Mac.** Work with a sharp remote display and familiar Mac shortcuts. If setup or troubleshooting gets stuck, copy the app’s guide into your own AI assistant.

[한국어](README.md) · [Build and test](DEVELOPMENT.md) · [Source terms](LICENSE)

1. On the Mac you want to control, [build 1.0.24](DEVELOPMENT.md) and move Final Fusion into **Applications**. Apple has not notarized local builds, so macOS may show a warning the first time you open the app. See [Apple’s guidance](https://support.apple.com/en-us/102445).
2. Open the host and choose **Copy step ①**. The guide helps set up a relay in your own Cloudflare account and enable Screen Recording and Accessibility.
3. Choose your viewer device in step ②. Create its viewer on the host and share it privately with that device. Viewer packages contain connection details. On a Mac, move **파이널 퓨전 받기** into Applications and open it.
4. Click **Connect** on the viewer and approve its six-digit code on the host. To use system shortcuts remotely on a Mac, choose **Open Accessibility settings** under **Shortcut permissions** and allow **파이널 퓨전 받기**. The Input Monitoring row turns green when macOS allows the app to listen for keyboard input.

A direct connection can match the Mac viewer’s pixel dimensions when available. Otherwise it falls back to High quality. Your own relay is available when direct connection cannot be used.

From 1.0.7 the viewer plays the host Mac's sound. While a viewer listens, the host's own speakers are muted and they come back when the connection ends. A Mac viewer can turn this off under Options. Host and viewer both need 1.0.7 or later.

Source builds from 1.0.10 onward share copied text, images and files between Macs. Each copy can contain up to 64 files totaling 200 MB. Copied folder paths are shared as text. Use **Options** on the viewer to turn sharing off.

In the Mac viewer, use **⌘⇧3** or **⌘⇧4** to copy a screenshot of the host screen. Use **Copy screenshot** in the remote window before setting up system shortcut permissions. When clipboard sharing is enabled, both Macs can paste it.

You can open Final Fusion on the host Mac and change its settings while connected. To disconnect the viewer, press **Fn + Control + Option + Command + F12** on the Mac viewer. On Windows, hold **Esc** to leave full screen, then click **Disconnect**. **Stop sharing** on the host turns off screen sharing. To turn it back on, you need a backup remote app or physical access to the host Mac.

After you update the host, it offers a **DIY update** to older Mac viewers when they connect. Viewers on 1.0.2 or later install updates automatically. On 1.0.0, click **Install** once for the first upgrade. To update a Windows viewer, create a new one on the host and copy it to that PC.

Full-quality sharing starts when the host resolution and fresh video are ready. When a virtual display becomes the main display on a Mac without a monitor, Final Fusion shares it directly. If the screen saver stays on, the viewer connects using the current display, then reconnects at full quality when the screen saver ends.

## Connect to the login screen after restart (Mac)

Use 1.0.19 or later on both Macs. [Build the app from source](DEVELOPMENT.md) to use this feature. The installer linked above is 1.0.4.

1. On the host Mac, open **System Settings → General → Sharing → Screen Sharing**. Turn it on and allow the Mac account you’ll sign in to.
2. In Final Fusion, turn on **Get ready to share when I log in**. Connect from the Mac viewer once and approve it on the host.
3. In the host app’s **Settings**, turn on **Connect to the login screen after restart** and approve the macOS administrator prompt.
4. After restarting the host, click **Connect** from the approved Mac viewer. Enter the host Mac account password in the macOS Screen Sharing window. The regular Final Fusion screen opens automatically after sign-in.

Turn off the switch and approve the macOS prompt to remove the helper. If **Reinstall startup helper** appears after you update the host, click it.

Only previously approved Mac viewers can reach macOS Screen Sharing through Final Fusion before sign-in. If FileVault is on, unlock the disk at the host Mac first after a restart. This feature uses the Mac viewer.

The host targets macOS 14 or later. The universal Mac viewer targets macOS 11 or later. An earlier version was tested on an Intel MacBook at 2560×1600. The 1.0 checks are local simulations and builds; Apple Silicon Mac viewers and Windows laptops have not been tested on physical receiver hardware. The Windows build targets 64-bit Windows 10 or later with Edge or Chrome; full-screen system keys still need physical testing. Windows and Mac clipboard sharing is unavailable.

Personal local use and modification are allowed; redistribution rights are reserved. See [LICENSE](LICENSE). When filing issues, share reproducible steps and use the redacted diagnostics. Do not attach a personalized viewer, relay address, pairing code, or a screenshot showing private material.
