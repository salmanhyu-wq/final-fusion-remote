import AppKit
import ApplicationServices

final class StudioApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var hosting: AnyObject?
    private var link: HostLink?
    private var viewing: StudioViewer?
    private let receiverMode = ReceiverMode()
    private var receiverRetry: DispatchWorkItem?
    private var receiverDelay = 2.0
    private var receiverMayQuit = false
    private var hostRetry: DispatchWorkItem?
    private var hostDelay = 2.0
    private var wantsHosting = false
    private let relayAddress = NSTextField(string: "")
    private let pairNumber = NSTextField(string: "")
    private let login = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private var awake: NSObjectProtocol?
    private var published: ReceiverProfile?
    private let receiver = ReceiverProfile.bundled()
    private let receiverOnly = Bundle.main.object(forInfoDictionaryKey: "StudioReceiverOnly") as? Bool == true
    private var appName: String { receiverOnly ? ProductName.receiver : ProductName.sender }
    private var pending: String?
    private var pendingCode: String?
    private let quality = NSPopUpButton()
    private var selectedResolution: ReceiverResolution {
        ReceiverResolution(rawValue: quality.indexOfSelectedItem) ?? .medium
    }
    private let screenEdge = NSPopUpButton()
    private let inputLanguage = NSButton(checkboxWithTitle: L("이 맥의 입력 언어(한/영) 따라가기",
                                                              "Match this Mac's keyboard language"),
                                         target: nil, action: nil)
    private let diagnostics = NSButton(checkboxWithTitle: L("연결 상태를 보내는 맥에 알려 주기",
                                                            "Share connection stats with the host Mac"),
                                       target: nil, action: nil)
    private let remoteTuning = NSButton(checkboxWithTitle: L("보내는 맥이 화질을 바꿀 수 있게 허용",
                                                             "Let the host Mac change the quality"),
                                        target: nil, action: nil)
    private var temporaryResolution: ReceiverResolution?
    private let directEnabled = NSButton(checkboxWithTitle: L("가능하면 바로 연결하기 (더 빨라요)",
                                                              "Connect directly when possible (faster)"),
                                         target: nil, action: nil)
    private let hostStatus = NSTextField(wrappingLabelWithString: L("처음 한 번, 이 맥의 연결 서버 주소를 설정하세요.",
                                                                    "First, set up this Mac's connection server address (one time only)."))
    private let viewerStatus = NSTextField(wrappingLabelWithString: L("연결을 기다리고 있어요.", "Ready to connect."))
    private let approvalText = NSTextField(wrappingLabelWithString: StudioApp.approvalIdle)
    private lazy var sharingLine = StatusLine(hostStatus)
    private lazy var viewingLine = StatusLine(viewerStatus)
    private let exportLines = (0..<2).map { _ in StatusLine(NSTextField(wrappingLabelWithString: "")) }
    private let updateLines = (0..<2).map { _ in StatusLine(NSTextField(wrappingLabelWithString: "")) }
    private var exporting = false
    private var exportJobs = 0
    private weak var manualApprovalCard: CardView?
    private weak var agentSetupCard: CardView?
    private weak var agentViewerCard: CardView?
    private weak var agentApprovalCard: CardView?
    private let startHost = ActionButton(.primary)
    private let endHost = ActionButton()
    private let exportApps = ActionButton()
    private let sendUpdates = [ActionButton(), ActionButton()]
    private var updateStatusMessage = ""
    private let installUpdate = ActionButton()
    private let checkUpdate = ActionButton()
    private var receivedUpdate: (URL, ReceiverUpdateOffer)?
    private var installingReceiverUpdate = false
    private let allow = ActionButton(.primary)
    private let deny = ActionButton(.danger)
    private let connect = ActionButton(.primary)
    private let disconnect = ActionButton()
    private let pageSwitch = NSSegmentedControl()
    private var pages: [NSView] = []
    private let root = NSStackView()
    private var updateRequestedByUser = FileManager.default.fileExists(atPath: StudioApp.updateRequestURL.path)
    private lazy var lastViewerVersion = UserDefaults.standard.string(forKey: "LastDIYViewerVersion")
        .flatMap(ReceiverUpdateVersion.init) ?? LocalSetup.readReport()?.receiverAppVersion.flatMap(ReceiverUpdateVersion.init)
    private let screenPermission = NSTextField(labelWithString: "")
    private let accessPermission = NSTextField(labelWithString: "")
    private let openScreenSettings = ActionButton()
    private let openAccessSettings = ActionButton()
    private let reopenApp = ActionButton()
    private let permissionBox = NSStackView()
    private let updateNotes = (0..<2).map { _ in NSTextField(wrappingLabelWithString: "") }
    private var permissionsGranted: (screen: Bool, access: Bool)?
    private enum SettingsMode: Int { case agent = 0, manual = 1 }
    private let modeSwitch = NSSegmentedControl()
    private let manualPage = NSStackView()
    private var agentPage: NSView?
    private var settingsMode = SettingsMode(rawValue: UserDefaults.standard.integer(forKey: "SettingsMode")) ?? .agent
    // Controls that move between the agent steps and the manual cards when the mode changes.
    private let sharingControls = NSStackView()
    private let approvalControls = NSStackView()
    private let viewerControls = NSStackView()
    private let manualSharingSlot = NSStackView()
    private let agentSharingSlot = NSStackView()
    private let manualApprovalSlot = NSStackView()
    private let agentApprovalSlot = NSStackView()
    private let manualViewerSlot = NSStackView()
    private let agentViewerSlot = NSStackView()
    private let targetPopup = NSPopUpButton()
    private let prepareGuide = ActionButton(.primary)
    private let sendGuide = ActionButton()
    private let connectionSummary = NSTextField(wrappingLabelWithString: "")
    private let viewerPermission = NSTextField(labelWithString: "")
    private var lastExport: [String: String]?
    private var previewing = false
    static let startRequest = Notification.Name("app.finalfusion.remote.start-sharing")
    static let exportRequest = Notification.Name("app.finalfusion.remote.export-receivers")
    private var statusTimer: Timer?
    private var writtenHostStatus: Data?
    /// Posted by `--send-receiver-update`; the running sender then acts as if ‘Send DIY update’ was clicked.
    static let updateRequest = Notification.Name("app.finalfusion.remote.send-receiver-update")
    static let hostStatusURL = LocalSetup.home.appendingPathComponent("host-status.json")
    /// Keeps an explicit send request across relaunches until a viewer reports the new version.
    static let updateRequestURL = LocalSetup.home.appendingPathComponent("send-update-requested")

    private static let approvalIdle = L("새 기기가 연결하면, 그 기기에 나온 6자리 번호를 여기에 입력해요.",
                                        "When a new device connects, type the 6-digit code it shows.")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !receiverOnly { SessionKeyboardLayout.recover() }
        let menu = NSMenu()
        let menuItem = NSMenuItem()
        menu.addItem(menuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("\(appName) 종료", "Quit \(appName)"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menuItem.submenu = appMenu
        NSApp.mainMenu = menu
        buildWindow()
        if !receiverOnly {
            let center = DistributedNotificationCenter.default()
            center.addObserver(self, selector: #selector(requestReceiverUpdateFromCommand), name: Self.updateRequest, object: nil)
            center.addObserver(self, selector: #selector(startSharingFromCommand), name: Self.startRequest, object: nil)
            center.addObserver(self, selector: #selector(exportFromCommand(_:)), name: Self.exportRequest, object: nil)
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshSenderState()
                self?.writeHostStatus()
            }
            refreshSenderState()
        } else {
            statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshViewerState() }
            refreshViewerState()
        }
        NSApp.activate(ignoringOtherApps: true)
        receiverMode.onExit = { [weak self] in self?.leaveReceiver() }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.receiverOnly && ViewerLocation.needsMove && self.offerMoveToApplications() { return }
            if self.receiverOnly && self.receiver != nil &&
                UserDefaults.standard.bool(forKey: "ReceiverPreviouslyConnected") &&
                UserDefaults.standard.object(forKey: "ReceiverResolution") != nil &&
                !NSEvent.modifierFlags.contains(.shift) {
                self.window.orderOut(nil)
                self.receiverMode.enter()
                self.beginViewing()
            } else if !self.receiverOnly && LocalSetup.load() != nil {
                self.wantsHosting = true
                self.startSending(requestPermissions: false)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if receiverMode.isActive { receiverMode.bringForward() }
        else { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        installingReceiverUpdate || (receiverMode.isActive && !receiverMayQuit) ? .terminateCancel : .terminateNow
    }

    private func leaveReceiver() {
        guard receiverMode.isActive else { return }
        receiverRetry?.cancel()
        receiverRetry = nil
        receiverMode.leave()
        temporaryResolution = nil
        viewing?.stop(L("화질을 고른 뒤 다시 연결할 수 있어요.", "Choose a quality, then connect again."))
        UserDefaults.standard.set(false, forKey: "ReceiverPreviouslyConnected")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changeLoginItem() {
        do {
            setLoginStatus(try ReceiverLogin.setRegistered(login.state == .on, sender: !receiverOnly))
        } catch {
            login.state = !previewing && ReceiverLogin.isRegistered ? .on : .off
            setLoginStatus(L("자동 실행을 바꾸지 못했어요. 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 시도하세요.",
                             "Couldn't change the login setting. Move the app to the Applications folder and try again."))
        }
    }

    private func setLoginStatus(_ text: String) {
        loginStatus.stringValue = text
        loginStatus.isHidden = text.isEmpty
        if window != nil { fitWindow() }
    }

    @objc private func enableReceiverInput() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            viewerStatus.stringValue = L("손쉬운 사용에서 「\(appName)」 앱을 켠 뒤 이 버튼을 다시 누르세요.",
                                         "Turn on “\(appName)” in Accessibility, then click this button again.")
            openInputPrivacyPane("Privacy_Accessibility")
        } else if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
            viewerStatus.stringValue = L("입력 모니터링에서 「\(appName)」 앱을 켜고 앱을 다시 여세요.",
                                         "Turn on “\(appName)” in Input Monitoring, then reopen the app.")
            openInputPrivacyPane("Privacy_ListenEvent")
        } else {
            viewerStatus.stringValue = L("준비됐어요. 원격 화면에서 스크린샷 키 ⌘+Shift+3·4를 쓸 수 있어요.",
                                         "All set. Screenshot keys ⌘+Shift+3 and 4 work on the remote screen.")
        }
    }

    private func openInputPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewing?.stop()
        stopHosting()
    }

    @objc private func saveReceiverOptions() {
        UserDefaults.standard.set(selectedResolution.rawValue, forKey: "ReceiverResolution")
        UserDefaults.standard.set(screenEdge.indexOfSelectedItem == 1, forKey: "InsetReceiverScreen")
        UserDefaults.standard.set(diagnostics.state == .off, forKey: "DisableReceiverDiagnostics")
        UserDefaults.standard.set(remoteTuning.state == .on, forKey: "AllowRemoteReceiverTuning")
        UserDefaults.standard.set(inputLanguage.state == .off, forKey: "KeepSenderInputSource")
    }

    @objc private func showReceiverDiagnostics() {
        let alert = NSAlert()
        alert.messageText = L("받는 기기 연결 상태", "Viewer connection info")
        alert.addButton(withTitle: L("닫기", "Close"))
        if let report = LocalSetup.readReport() {
            let time = DateFormatter.localizedString(from: report.receivedAt, dateStyle: .short, timeStyle: .medium)
            var lines = [L("마지막 수신 \(time)", "Last received \(time)"),
                         L("화면 방식 \(report.mode.title)", "Screen mode \(report.mode.title)")]
            if let version = report.receiverAppVersion { lines.append(L("받는 앱 버전 \(version)", "Viewer version \(version)")) }
            if let tuning = report.receiver.tuning {
                let permission = tuning.allowed ? L("허용", "allowed") : L("꺼짐", "off")
                lines.append(L("받는 화질 \(tuning.resolution.title) · 원격 화질 조정 \(permission)",
                               "Quality \(tuning.resolution.title) · Remote adjustment \(permission)"))
            }
            if let path = report.receiver.connectionPath {
                lines.append(path == .direct ? L("연결 경로 · 바로 연결", "Route · Direct")
                                             : L("연결 경로 · 연결 서버", "Route · Connection server"))
            }
            if let delay = report.receiver.roundTripMS { lines.append(L("연결 왕복 \(delay)ms", "Round trip \(delay) ms")) }
            if let sent = report.receiver.sentInputCount, let accepted = report.acceptedInputCount {
                lines.append(L("클릭·키 입력 \(sent)건 보냄 · 보내는 맥 \(accepted)건 받음",
                               "Clicks and keys: \(sent) sent · \(accepted) received by the host"))
            }
            if report.receiver.systemShortcuts == false {
                lines.append(L("받는 맥에서 ‘단축키 켜기’를 눌러 주세요.", "On the viewer Mac, click “Turn on shortcuts”."))
            }
            if let copied = report.screenshotCopied {
                lines.append(copied ? L("최근 스크린샷을 보내는 맥의 클립보드에 복사했어요.",
                                        "The last screenshot was copied to the host Mac's clipboard.")
                                    : L("최근 스크린샷을 클립보드에 복사하지 못했어요.",
                                        "The last screenshot couldn't be copied to the clipboard."))
            }
            if let layout = report.keyboardLayout {
                lines.append(layout == .matched ? L("입력 언어를 받는 맥에 맞췄어요.", "Keyboard language matched the viewer Mac.")
                                                : L("보내는 맥의 입력 언어를 그대로 썼어요.", "Kept the host Mac's keyboard language."))
            }
            for sample in report.receiver.displays {
                guard let screen = report.senderDisplays.first(where: { $0.id == sample.id }) else { continue }
                let fps = Double(sample.submittedFrames) / Double(report.receiver.seconds)
                let fit = screen.followsReceiver == true ? L("받는 화면 비율에 맞춤", "Fitted to the viewer screen")
                                                         : L("보내는 화면 비율 유지", "Kept the host screen ratio")
                let rate = report.reducedDisplays.contains(sample.id) ? L(" · 화면 부담 낮춤", " · reduced load") : ""
                lines.append("\(screen.name) · \(screen.width)×\(screen.height) → \(sample.localWidth)×\(sample.localHeight) · \(fit)")
                if screen.nativePixels == true { lines.append(L("원본 화질(바로 연결)을 쓰는 중이에요.", "Using full quality (direct).")) }
                if let w = screen.logicalWidth, let h = screen.logicalHeight {
                    lines.append(L("보내는 맥 작업 공간 \(w)×\(h)", "Host workspace \(w)×\(h)"))
                }
                lines.append(String(format: L("받는 화면 처리 %.1f장/초%@", "Viewer frame rate %.1f fps%@"), fps, rate))
                if let stream = report.senderStreams?.first(where: { $0.id == sample.id }) {
                    lines.append(String(format: L("전송 목표 %d장/초 · %.1fMbps", "Target %d fps · %.1f Mbps"), stream.targetFPS,
                                        Double(stream.targetKbps) / 1_000))
                    if let encode = stream.encodeMS {
                        lines.append(String(format: L("최근 영상 압축 %.1fms", "Last video encode %.1f ms"), encode))
                    }
                    if let queueDelay = stream.videoQueueDelayMS {
                        lines.append(L("영상 대기 지연 \(queueDelay)ms", "Video queue delay \(queueDelay) ms"))
                    }
                }
                lines.append(L("확대·축소 \(sample.pinchEvents)회 · 여러 손가락 \(sample.multiTouchEvents)회 · 제스처 단축키 \(sample.gestureShortcuts)회",
                               "Pinch \(sample.pinchEvents) · Multi-touch \(sample.multiTouchEvents) · Gesture shortcuts \(sample.gestureShortcuts)"))
                if let count = sample.scrollEvents, count > 0, let natural = sample.naturalScrolling {
                    let direction = natural ? L("켬", "on") : L("끔", "off")
                    lines.append(L("스크롤 \(count)회 · 받는 맥의 자연스러운 스크롤 \(direction)",
                                   "Scroll \(count) · Natural scrolling on the viewer \(direction)"))
                }
            }
            alert.informativeText = lines.joined(separator: "\n")
        } else {
            alert.informativeText = L("아직 받은 연결 정보가 없어요. 받는 앱에서 ‘연결 상태를 보내는 맥에 알려 주기’를 켜고 연결한 뒤 잠시 기다려 주세요.",
                                      "No connection info yet. In the viewer app, turn on “Share connection stats with the host Mac”, connect, and wait a moment.")
        }
        alert.beginSheetModal(for: window)
    }

    // MARK: - Window

    /// Builds the settings window for `--preview-ui` without starting any connection.
    func makePreviewWindow() -> NSWindow {
        previewing = true
        buildWindow()
        if ProcessInfo.processInfo.environment["FINAL_FUSION_PREVIEW_MODE"] == "manual" { setMode(.manual) }
        if ProcessInfo.processInfo.environment["FINAL_FUSION_PREVIEW_MODE"] == "agent" { setMode(.agent) }
        refreshSenderState()
        refreshViewerState()
        switch ProcessInfo.processInfo.environment["FINAL_FUSION_PREVIEW_STATE"] {
        case "connecting":
            if receiverOnly {
                viewerStatus.stringValue = L("보내는 맥에 안전하게 연결하고 있어요…", "Connecting securely to the host Mac…")
                viewingLine.show(.busy)
                connect.isEnabled = false
                disconnect.isEnabled = true
            } else {
                hostStatus.stringValue = L("보내기를 켜는 중…", "Starting…")
                sharingLine.show(.busy)
                startHost.isEnabled = false
                endHost.isEnabled = true
            }
        case "exporting":
            setExportStatus(L("받는 앱 두 종류를 만들고 있어요…", "Creating the viewer apps…"), activity: .busy)
        case "updating":
            agentSetupCard?.tone = .panel
            agentViewerCard?.tone = .featured
            prepareGuide.setStyle(.secondary)
            sendGuide.setStyle(.primary)
            setUpdateStatus(L("받는 기기에 새 앱을 보내고 있어요…", "Sending the new app to the viewer…"))
            updateLines.forEach { $0.show(.progress(0.58)) }
        default: break
        }
        fitWindow()
        window.contentView?.wantsLayer = true
        return window
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = ReceiverUpdateVersion.current.map { appName + " " + $0.label } ?? appName
        window.isReleasedWhenClosed = false
        login.target = self
        login.action = #selector(changeLoginItem)
        login.title = receiverOnly ? L("로그인하면 받는 앱 열기", "Open the viewer when I log in")
                                   : L("로그인하면 자동으로 보내기 준비", "Get ready to share when I log in")
        login.state = ReceiverLogin.isRegistered ? .on : .off
        loginStatus.font = .systemFont(ofSize: 13)
        loginStatus.textColor = .secondaryLabelColor
        for status in [hostStatus, viewerStatus, approvalText] {
            status.font = .systemFont(ofSize: 14, weight: .medium)
        }
        for line in exportLines + updateLines {
            line.label.font = .systemFont(ofSize: 13, weight: .medium)
            line.isHidden = true
        }
        relayAddress.placeholderString = "https://…workers.dev"
        relayAddress.stringValue = previewing ? "" : LocalSetup.load()?.relay ?? ""
        relayAddress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        relayAddress.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        pairNumber.placeholderString = L("6자리 번호", "6-digit code")
        pairNumber.font = .monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        pairNumber.alignment = .center
        pairNumber.widthAnchor.constraint(equalToConstant: 140).isActive = true
        quality.addItems(withTitles: ReceiverResolution.allCases.map(\.title))
        let saved = UserDefaults.standard.object(forKey: "ReceiverResolution") as? Int
        quality.selectItem(at: (saved.flatMap(ReceiverResolution.init(rawValue:)) ?? .medium).rawValue)
        quality.target = self
        quality.action = #selector(saveReceiverOptions)
        quality.setAccessibilityLabel(L("화면 화질", "Screen quality"))
        screenEdge.addItems(withTitles: [L("화면 꽉 채우기", "Fill the screen"), L("테두리 조금 남기기", "Leave a small border")])
        screenEdge.selectItem(at: UserDefaults.standard.bool(forKey: "InsetReceiverScreen") ? 1 : 0)
        screenEdge.target = self
        screenEdge.action = #selector(saveReceiverOptions)
        screenEdge.setAccessibilityLabel(L("화면 크기", "Screen size"))
        diagnostics.state = UserDefaults.standard.bool(forKey: "DisableReceiverDiagnostics") ? .off : .on
        diagnostics.target = self
        diagnostics.action = #selector(saveReceiverOptions)
        remoteTuning.state = UserDefaults.standard.bool(forKey: "AllowRemoteReceiverTuning") ? .on : .off
        remoteTuning.target = self
        remoteTuning.action = #selector(saveReceiverOptions)
        remoteTuning.toolTip = L("연결 상태를 보내는 동안, 허용된 보내는 맥이 이 연결의 화질을 바꿀 수 있어요.",
                                 "While stats are shared, the approved host Mac can change this connection's quality.")
        inputLanguage.state = UserDefaults.standard.bool(forKey: "KeepSenderInputSource") ? .off : .on
        inputLanguage.target = self
        inputLanguage.action = #selector(saveReceiverOptions)
        for box in [login, inputLanguage, diagnostics, remoteTuning, directEnabled] {
            box.font = .systemFont(ofSize: 14)
        }

        if !receiverOnly {
            directEnabled.state = LocalSetup.directEnabled() ? .on : .off
            directEnabled.target = self
            directEnabled.action = #selector(saveDirectOption)
            directEnabled.toolTip = L("보내기를 멈춘 상태에서 바꿀 수 있어요. 바로 연결이 안 되면 연결 서버로 이어져요.",
                                      "Change this while sharing is stopped. If a direct connection fails, the connection server is used.")
            pages.append(senderPage())
        }
        pages.append(receiverPage())

        connect.isEnabled = receiver != nil
        checkUpdate.isEnabled = receiver != nil
        disconnect.isEnabled = false
        endHost.isEnabled = false
        exportApps.isEnabled = false
        sendUpdates.forEach { $0.isEnabled = false }
        installUpdate.isHidden = true
        allow.isEnabled = false
        deny.isEnabled = false
        pairNumber.isEnabled = false
        if !receiverOnly, #unavailable(macOS 14) {
            startHost.isEnabled = false
            hostStatus.stringValue = L("화면 보내기는 macOS 14 이상에서 쓸 수 있어요.", "Sharing requires macOS 14 or later.")
        }

        agentPage = receiverOnly ? (receiver != nil ? receiverAgentPage() : nil) : senderAgentPage()
        var manualViews: [NSView] = []
        if pages.count > 1 {
            pageSwitch.segmentCount = 2
            pageSwitch.setLabel(L("이 맥 화면 보내기", "Share this Mac"), forSegment: 0)
            pageSwitch.setLabel(L("다른 맥 화면 보기", "View another Mac"), forSegment: 1)
            pageSwitch.trackingMode = .selectOne
            pageSwitch.segmentStyle = .rounded
            pageSwitch.selectedSegmentBezelColor = Palette.actionFill
            pageSwitch.controlSize = .large
            pageSwitch.target = self
            pageSwitch.action = #selector(switchPage)
            manualViews.append(pageSwitch)
        }
        manualViews += pages
        manualPage.setViews(manualViews, in: .top)
        manualPage.orientation = .vertical
        manualPage.alignment = .leading
        manualPage.spacing = 14
        for page in pages { page.widthAnchor.constraint(equalToConstant: 596).isActive = true }
        if pages.count > 1 { pageSwitch.widthAnchor.constraint(equalToConstant: 400).isActive = true }
        var sections: [NSView] = [header()]
        if let agentPage = agentPage {
            modeSwitch.segmentCount = 2
            modeSwitch.setLabel(L("🤖 AI 도움", "🤖 AI help"), forSegment: 0)
            modeSwitch.setLabel(L("직접 설정", "Manual setup"), forSegment: 1)
            modeSwitch.trackingMode = .selectOne
            modeSwitch.segmentStyle = .rounded
            modeSwitch.selectedSegmentBezelColor = Palette.actionFill
            modeSwitch.controlSize = .large
            modeSwitch.target = self
            modeSwitch.action = #selector(switchMode)
            modeSwitch.setAccessibilityLabel(L("설정 방식", "Setup mode"))
            sections += [modeSwitch, agentPage]
        }
        sections += [manualPage, PromoBanner()]
        root.setViews(sections, in: .top)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 17
        root.setCustomSpacing(18, after: sections[0])
        root.translatesAutoresizingMaskIntoConstraints = false
        // Constant widths survive NSStackView detaching hidden pages.
        for view in sections where view !== modeSwitch {
            view.widthAnchor.constraint(equalToConstant: 596).isActive = true
        }
        if agentPage != nil { modeSwitch.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        for label in [sharingLine, approvalText, viewingLine, connectionSummary] {
            label.widthAnchor.constraint(equalToConstant: 564).isActive = true
        }
        loginStatus.widthAnchor.constraint(equalToConstant: 564).isActive = true
        loginStatus.isHidden = loginStatus.stringValue.isEmpty
        for note in updateNotes {
            note.font = .systemFont(ofSize: 13, weight: .medium)
            note.textColor = Palette.brand
            note.isHidden = true
        }

        // The settings scroll when the window would be taller than the screen (first run on a small display).
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(root)
        scroll.documentView = document
        window.contentView = scroll
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalToConstant: 640),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.widthAnchor.constraint(equalToConstant: 596),
            root.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            root.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22),
            root.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)
        ])
        showPage(0)
        setMode(agentPage == nil ? .manual : settingsMode)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func header() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 46).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 46).isActive = true
        let name = NSTextField(labelWithString: appName)
        name.font = .systemFont(ofSize: 23, weight: .bold)
        let subtitle = NSTextField(labelWithString: receiverOnly
            ? L("멀리 있는 맥을 이 컴퓨터에서 그대로 써요", "Use your Mac from this computer")
            : L("이 맥을 다른 맥이나 Windows PC에서 그대로 써요", "Use this Mac from another Mac or Windows PC"))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let words = NSStackView(views: [name, subtitle])
        words.orientation = .vertical
        words.alignment = .leading
        words.spacing = 4
        let row = NSStackView()
        row.spacing = 12
        row.alignment = .centerY
        row.addView(icon, in: .leading)
        row.addView(words, in: .leading)
        if let version = ReceiverUpdateVersion.current {
            let label = NSTextField(labelWithString: "v" + version.label)
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .tertiaryLabelColor
            row.addView(label, in: .trailing)
        }
        return row
    }

    private func senderPage() -> NSView {
        column(sharingControls, [
            sharingLine,
            row([startHost.set(L("보내기 시작", "Start sharing"), symbol: "play.fill", target: self, action: #selector(beginHosting)),
                 endHost.set(L("송신 중지", "Stop sharing"), symbol: "stop.fill", target: self, action: #selector(confirmStopHosting))]),
            permissionPanel()
        ])
        column(approvalControls, [
            approvalText,
            row([pairNumber,
                 allow.set(L("허용", "Allow"), symbol: "checkmark", target: self, action: #selector(allowPair)),
                 deny.set(L("거절", "Deny"), symbol: "xmark", target: self, action: #selector(denyPair))])
        ])
        let status = card(L("화면 보내기", "Sharing"), "dot.radiowaves.left.and.right", [column(manualSharingSlot, [])], tone: .featured)
        let approval = card(L("새 기기 허용", "Allow a new device"), "checkmark.shield", [column(manualApprovalSlot, [])], tone: .section)
        manualApprovalCard = approval
        let viewers = card(L("받는 기기", "Viewer devices"), "laptopcomputer", [
            hint(L("받는 앱을 만들어 다른 맥이나 Windows PC에서 여세요. 먼저 ‘보내기 시작’을 눌러야 만들 수 있어요.",
                   "Create the viewer app and open it on another Mac or Windows PC. Start sharing first.")),
            row([exportApps.set(L("받는 앱 만들기", "Create viewer apps"), symbol: "square.and.arrow.down",
                                target: self, action: #selector(exportReceivers)),
                 ActionButton(.quiet).set(L("연결 상태", "Connection info"), symbol: "waveform.path.ecg",
                                          target: self, action: #selector(showReceiverDiagnostics))]),
            row([diySendButton(at: 0)]), updateNotes[0], exportLines[0], updateLines[0]
        ])
        let relayLabel = NSTextField(labelWithString: L("연결 서버", "Connection server"))
        relayLabel.font = .systemFont(ofSize: 14, weight: .medium)
        let relayRow = row([relayLabel, relayAddress,
                            ActionButton().set(L("설정 안내 복사", "Copy setup guide"), symbol: "doc.on.doc",
                                               target: self, action: #selector(copySetupGuide))])
        relayRow.alignment = .centerY
        let settings = card(L("설정", "Settings"), "gearshape", [
            relayRow,
            hint(L("처음 한 번만: ‘설정 안내 복사’를 누르고 AI 도우미에 붙여넣으면 연결 서버를 만들어 줘요.",
                   "One-time setup: click “Copy setup guide” and paste it into an AI assistant on this Mac to set up the connection server.")),
            login, loginStatus, directEnabled,
            hint(L("권장 인터넷 속도 · 올리기 25 Mbps, 내려받기 2 Mbps", "Recommended internet speed · 25 Mbps up, 2 Mbps down"))
        ])
        relayRow.widthAnchor.constraint(equalTo: settings.stack.widthAnchor).isActive = true
        return page([status, approval, viewers, settings])
    }

    private func receiverPage() -> NSView {
        var controls: [NSView] = [
            viewingLine,
            row([connect.set(L("연결하기", "Connect"), symbol: "play.fill", target: self, action: #selector(beginViewing)),
                 disconnect.set(L("취소", "Cancel"), symbol: "xmark", target: self, action: #selector(stopViewing))])
        ]
        if receiver != nil {
            controls.append(row([
                checkUpdate.set(L("DIY 업데이트 확인", "Check for DIY update"), symbol: "arrow.clockwise",
                                target: self, action: #selector(checkReceiverUpdate)),
                installUpdate.set(L("DIY 업데이트 다시 설치", "Retry DIY update"), symbol: "arrow.down.circle",
                                  target: self, action: #selector(installReceivedUpdate))
            ]))
        }
        column(viewerControls, controls)
        var first: [NSView] = [column(manualViewerSlot, [])]
        first.append(hint(receiver != nil
            ? L("보내는 맥에서 ‘보내기 시작’을 누른 뒤 연결하세요. 첫 연결 때는 6자리 번호가 나와요.",
                "Click “Start sharing” on the host Mac, then connect. A 6-digit code appears the first time.")
            : L("보내는 맥에서 ‘받는 앱 만들기’로 만든 앱으로 연결할 수 있어요.",
                "To connect, use the viewer app made with “Create viewer apps” on the host Mac.")))
        var cards: [NSView] = [card(L("연결", "Connection"), "display", first, tone: .featured)]
        guard receiver != nil else { return page(cards) }

        let qualityLabel = NSTextField(labelWithString: L("화질", "Quality"))
        let sizeLabel = NSTextField(labelWithString: L("크기", "Size"))
        for label in [qualityLabel, sizeLabel] { label.font = .systemFont(ofSize: 14, weight: .medium) }
        let displayRow = row([qualityLabel, quality, sizeLabel, screenEdge])
        displayRow.alignment = .centerY
        displayRow.setCustomSpacing(18, after: quality)
        cards.append(card(L("화면", "Display"), "rectangle.on.rectangle", [displayRow]))
        cards.append(card(L("옵션", "Options"), "slider.horizontal.3",
                          [inputLanguage, diagnostics, remoteTuning, login, loginStatus], tone: .section))
        cards.append(row([
            ActionButton().set(L("단축키 켜기", "Turn on shortcuts"), symbol: "keyboard",
                               target: self, action: #selector(enableReceiverInput)),
            ActionButton().set(L("도움말 복사", "Copy help"), symbol: "doc.on.doc",
                               target: self, action: #selector(copyViewerFix))
        ]))
        cards.append(hint(L("원격 화면에서 설정으로 돌아오기: ", "Return to settings from the remote screen: ")
                          + ReceiverMode.exitKeys + "\n"
                          + L("권장 인터넷 속도 · 내려받기 25 Mbps, 올리기 2 Mbps", "Recommended internet speed · 25 Mbps down, 2 Mbps up")))
        return page(cards)
    }

    private func page(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views where view is CardView || view is NSTextField {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func card(_ title: String, _ symbol: String, _ views: [NSView], tone: CardView.Tone = .panel) -> CardView {
        CardView(title: title, symbol: symbol, tone: tone, views)
    }

    private func refreshStepEmphasis() {
        manualApprovalCard?.tone = pending == nil ? .section : .featured
        agentSetupCard?.tone = published == nil && pending == nil ? .featured : .panel
        agentViewerCard?.tone = published != nil && pending == nil ? .featured : .section
        agentApprovalCard?.tone = pending == nil ? .section : .featured
        startHost.setStyle(settingsMode == .agent && published == nil ? .secondary : .primary)
        prepareGuide.setStyle(published == nil && pending == nil ? .primary : .secondary)
        sendGuide.setStyle(published != nil && pending == nil ? .primary : .secondary)
    }

    private func showPage(_ index: Int) {
        guard pages.indices.contains(index) else { return }
        if pages.count > 1 { pageSwitch.selectedSegment = index }
        for (offset, page) in pages.enumerated() { page.isHidden = offset != index }
        fitWindow()
    }

    @objc private func switchPage() { showPage(pageSwitch.selectedSegment) }

    // MARK: - Agent help mode

    @discardableResult
    private func column(_ stack: NSStackView, _ views: [NSView]) -> NSStackView {
        stack.setViews(views, in: .top)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        return stack
    }

    private func primary(_ title: String, _ symbol: String, _ action: Selector,
                         style: ActionButton.Style = .primary) -> ActionButton {
        ActionButton(style).set(title, symbol: symbol, target: self, action: action)
    }

    private func diySendButton(at index: Int) -> ActionButton {
        sendUpdates[index].set(L("DIY 업데이트 보내기", "Send DIY update"), symbol: "arrow.triangle.2.circlepath",
                               target: self, action: #selector(sendReceiverUpdate))
    }

    private func senderAgentPage() -> NSView {
        targetPopup.addItems(withTitles: ViewerTarget.allCases.map(\.title))
        targetPopup.setAccessibilityLabel(L("받는 컴퓨터 종류", "Viewing computer"))
        connectionSummary.font = .systemFont(ofSize: 13, weight: .medium)
        let intro = hint(L("단계 버튼을 누르면 안내가 복사돼요. AI 도우미(Claude Code, Codex 등)에 붙여넣으면 나머지는 알아서 해요.",
                           "Each step button copies a guide. Paste it into your AI assistant (Claude Code, Codex…) and it does the rest."))
        let setup = card(L("① 시작 준비", "① Get ready"), "bolt.horizontal.circle", [
            hint(L("AI 도우미가 연결 서버를 만들고 보내기를 시작해요. 로그인과 macOS 허용만 해 주세요.",
                   "The AI assistant sets up the connection server and starts sharing. You only sign in and allow macOS settings.")),
            row([prepareGuide.set(L("① 안내 복사", "Copy step ①"), symbol: "doc.on.doc", target: self, action: #selector(copySetupGuide))]),
            column(agentSharingSlot, [])
        ], tone: .featured)
        agentSetupCard = setup
        let targetRow = row([targetPopup, sendGuide.set(L("② 안내 복사", "Copy step ②"), symbol: "paperplane", target: self, action: #selector(copyViewerGuide))])
        targetRow.alignment = .centerY
        let viewers = card(L("② 받는 앱 보내기", "② Send the viewer app"), "paperplane", [
            hint(L("받는 컴퓨터를 고르세요. AI 도우미가 이메일 주소를 묻고 맞는 앱과 연결 방법을 보내요.",
                   "Pick the viewing computer. The AI assistant asks for an email address and sends the right app.")),
            targetRow, row([diySendButton(at: 1)]), updateNotes[1], exportLines[1], updateLines[1]
        ], tone: .section)
        agentViewerCard = viewers
        let first = card(L("③ 첫 연결", "③ First connection"), "checkmark.shield", [
            hint(L("받는 기기에서 ‘연결하기’를 누르면 6자리 번호가 나와요. 여기에 입력하고 ‘허용’을 누르세요.",
                   "When the viewer clicks “Connect”, a 6-digit code appears. Enter it here and click “Allow”.")),
            column(agentApprovalSlot, []),
            connectionSummary
        ], tone: .section)
        agentApprovalCard = first
        let fix = card(L("④ 바로 고치기", "④ Fix it now"), "wrench.and.screwdriver", [
            hint(L("쓰다가 불편하면 누르세요. AI 도우미가 원인을 찾아 고치고 받는 앱까지 새로 보내요.",
                   "Something bothering you? The AI assistant finds the cause, fixes it, and updates the viewer too.")),
            row([primary(L("④ 안내 복사", "Copy step ④"), "wand.and.stars", #selector(copyFixGuide), style: .quiet)])
        ], tone: .section)
        return page([intro, setup, viewers, first, fix])
    }

    private func receiverAgentPage() -> NSView {
        viewerPermission.font = .systemFont(ofSize: 14, weight: .medium)
        let intro = hint(L("처음이라면 아래 순서대로 하면 돼요. 막히면 ④로 AI 도우미에게 도움을 받으세요.",
                           "If this is your first time, follow the steps below. If you get stuck, use ④ to get help from an AI assistant."))
        let connect = card(L("① 연결", "① Connect"), "display", [
            hint(L("보내는 맥에서 파이널 퓨전이 ‘보내기’ 중이어야 해요.", "Final Fusion must be sharing on the host Mac.")),
            column(agentViewerSlot, [])
        ], tone: .featured)
        let allow = card(L("② 첫 연결 허용", "② Allow the first connection"), "checkmark.shield", [
            hint(L("처음 연결하면 화면에 6자리 번호가 나와요. 보내는 맥의 「③ 첫 연결」 칸에 입력하고 「허용」을 누르세요.",
                   "The first time, a 6-digit code appears. Enter it under “③ First connection” on the host Mac and click “Allow”."))
        ])
        let keys = card(L("③ 단축키 설정", "③ Shortcut keys"), "keyboard", [
            hint(L("⌘+Space·⌘+Tab도 보내는 맥으로 보내려면 손쉬운 사용과 입력 모니터링을 켜세요. 스위치가 이미 켜져 있으면 －로 지우고 ＋로 다시 추가하세요.",
                   "To send ⌘+Space and ⌘+Tab to the host Mac, turn on Accessibility and Input Monitoring. If a switch is already on, remove it with − and add it again with +.")),
            viewerPermission,
            row([ActionButton().set(L("단축키 켜기", "Turn on shortcuts"), symbol: "keyboard",
                                    target: self, action: #selector(enableReceiverInput))])
        ])
        let fix = card(L("④ 바로 고치기", "④ Fix it now"), "wrench.and.screwdriver", [
            hint(L("불편하면 원격 화면에서 보내는 맥의 파이널 퓨전을 열고 「④ 바로 고치기」의 「④ 안내 복사」를 누르세요. 이 기기 정보가 필요하면 아래 버튼을 누르세요.",
                   "If something bothers you, open Final Fusion on the host Mac through the remote screen and click “Copy step ④” under “④ Fix it now”. Click below if this device's info is needed.")),
            row([primary(L("이 기기 정보 복사", "Copy device info"), "doc.on.doc", #selector(copyViewerFix), style: .quiet)])
        ], tone: .section)
        return page([intro, connect, allow, keys, fix])
    }

    @objc private func switchMode() { setMode(SettingsMode(rawValue: modeSwitch.selectedSegment) ?? .agent) }

    private func setMode(_ mode: SettingsMode) {
        settingsMode = mode
        if agentPage != nil && !previewing { UserDefaults.standard.set(mode.rawValue, forKey: "SettingsMode") }
        modeSwitch.selectedSegment = mode.rawValue
        let agent = mode == .agent && agentPage != nil
        if receiverOnly {
            (agent ? agentViewerSlot : manualViewerSlot).addArrangedSubview(viewerControls)
        } else {
            (agent ? agentSharingSlot : manualSharingSlot).addArrangedSubview(sharingControls)
            (agent ? agentApprovalSlot : manualApprovalSlot).addArrangedSubview(approvalControls)
            if viewerControls.superview == nil { manualViewerSlot.addArrangedSubview(viewerControls) }
        }
        agentPage?.isHidden = !agent
        manualPage.isHidden = agent
        refreshStepEmphasis()
        fitWindow()
    }

    private func refreshViewerState() {
        guard receiverOnly else { return }
        let access = !previewing && AXIsProcessTrusted(), monitoring = !previewing && CGPreflightListenEventAccess()
        let text = "● " + L("손쉬운 사용", "Accessibility") + (access ? L(" · 허용됨", " · allowed") : L(" · 허용 필요", " · needed"))
            + "     ● " + L("입력 모니터링", "Input Monitoring") + (monitoring ? L(" · 허용됨", " · allowed") : L(" · 허용 필요", " · needed"))
        if viewerPermission.stringValue != text {
            viewerPermission.stringValue = text
            viewerPermission.textColor = access && monitoring ? .systemGreen : .systemOrange
        }
    }

    /// A viewer opened from the disk image or Downloads can't update itself, so offer to move it first.
    private func offerMoveToApplications() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("응용 프로그램 폴더로 옮길까요?", "Move to the Applications folder?")
        alert.informativeText = L("설치 파일이나 다운로드 폴더에서 바로 연 앱은 업데이트를 받을 수 없어요. 응용 프로그램 폴더로 옮긴 뒤 다시 열게요.",
                                  "An app opened from the installer or Downloads can't receive updates. It will be moved to Applications and reopened.")
        alert.addButton(withTitle: L("옮기고 다시 열기", "Move and reopen"))
        alert.addButton(withTitle: L("나중에", "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let moved = try ViewerLocation.moveToApplications()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: moved, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    if error == nil { NSApp.terminate(nil) }
                    else { self.viewerStatus.stringValue = error?.localizedDescription ?? "" }
                }
            }
            return true
        } catch {
            viewerStatus.stringValue = L("옮기지 못했어요. Finder에서 「Studio Receiver」를 응용 프로그램 폴더로 직접 끌어다 놓아 주세요.",
                                         "Couldn't move it. Drag “Studio Receiver” into the Applications folder in Finder.")
            return false
        }
    }

    @objc private func startSharingFromCommand() {
        guard hosting == nil else { return }
        if let setup = LocalSetup.load() { relayAddress.stringValue = setup.relay }
        beginHosting()
    }

    /// `--export-receivers`: builds the viewer for one device into a folder and reports the result in host-status.json.
    @objc private func exportFromCommand(_ notification: Notification) {
        guard let info = notification.userInfo, let id = info["id"] as? String, id.count <= 64,
              let folder = info["folder"] as? String, folder.hasPrefix("/") else { return }
        let target = (info["target"] as? String).flatMap(ViewerTarget.init(rawValue:))
        func finish(path: String?, error: String?) {
            lastExport = ["id": id, "path": path ?? "", "error": error ?? ""]
            writeHostStatus()
        }
        guard let profile = published else {
            finish(path: nil, error: L("보내기가 준비되지 않았어요. 먼저 --start-sharing으로 보내기를 시작하세요.",
                                       "Sharing isn't ready. Start it first with --start-sharing."))
            return
        }
        exportJobs += 1
        setExportStatus(L("받는 앱을 만들고 있어요…", "Creating the viewer app…"), activity: .busy)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ReceiverExport.make(profile, in: URL(fileURLWithPath: folder, isDirectory: true), target: target) }
            DispatchQueue.main.async {
                self.exportJobs -= 1
                let activity: OperationActivity = self.exportJobs == 0 ? .idle : .busy
                switch result {
                case let .success(output):
                    self.setExportStatus(L("받는 앱을 만들었어요.", "Created the viewer app."), activity: activity)
                    finish(path: output.path, error: nil)
                case let .failure(error):
                    self.setExportStatus(error.localizedDescription, activity: activity)
                    finish(path: nil, error: error.localizedDescription)
                }
            }
        }
    }

    private func fitWindow() {
        guard let window = window else { return }
        root.layoutSubtreeIfNeeded()
        var height = ceil(root.fittingSize.height) + 42
        if !previewing, let screen = window.screen ?? NSScreen.main {
            height = min(height, window.contentRect(forFrameRect: screen.visibleFrame).height)
        }
        let size = NSSize(width: 640, height: height)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard abs(frame.height - window.frame.height) >= 1 else { return }
        window.setFrame(frame, display: true,
                        animate: window.isVisible && !previewing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func hint(_ value: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: value)
        field.textColor = .secondaryLabelColor
        field.font = .systemFont(ofSize: 13)
        return field
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        return stack
    }

    // MARK: - Actions

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func copySetupGuide() {
        copyGuide(AgentGuide.setup(), step: L("① 시작 준비", "① Get ready"))
    }

    @objc private func copyViewerGuide() {
        let target = ViewerTarget.allCases[max(0, targetPopup.indexOfSelectedItem)]
        copyGuide(AgentGuide.viewer(target), step: L("② 받는 앱 보내기", "② Send the viewer app"))
    }

    @objc private func copyFixGuide() {
        writeHostStatus()
        copyGuide(AgentGuide.fix(report: SupportReport.text(SupportReport.shareable(SupportReport.host()))), step: L("④ 바로 고치기", "④ Fix it now"))
    }

    @objc private func copyViewerFix() {
        let report = SupportReport.text(SupportReport.shareable(SupportReport.viewer(status: viewerStatus.stringValue)))
        copyGuide(AgentGuide.viewerFix(report: report), step: L("바로 고치기", "Fix it now"))
    }

    /// Copies a step's guide and says where to paste it.
    private func copyGuide(_ text: String, step: String) {
        copy(text)
        let alert = NSAlert()
        alert.messageText = L("「\(step)」 안내를 복사했어요", "Copied the “\(step)” guide")
        alert.informativeText = L("쓰시는 AI 도우미(Claude Code, Codex 등) 대화창에 붙여넣고(⌘V) 보내세요. 꼭 필요한 것만 묻고 나머지는 알아서 해 줘요.",
                                  "Paste it (⌘V) into your AI assistant (Claude Code, Codex and others) and send it. It asks only what it needs and does the rest.")
        alert.addButton(withTitle: L("확인", "OK"))
        alert.beginSheetModal(for: window)
    }

    @objc private func saveDirectOption() {
        do { try LocalSetup.saveDirect(enabled: directEnabled.state == .on) }
        catch {
            directEnabled.state = LocalSetup.directEnabled() ? .on : .off
            hostStatus.stringValue = error.localizedDescription
        }
    }

    @objc private func beginHosting() {
        wantsHosting = true
        hostRetry?.cancel()
        hostRetry = nil
        hostDelay = 2
        startSending(requestPermissions: true)
    }

    private func startSending(requestPermissions: Bool) {
        guard #available(macOS 14, *), wantsHosting, hosting == nil, !receiverOnly else { return }
        sharingLine.show(.idle)
        let entered = relayAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let setup = entered.isEmpty ? LocalSetup.load() : RelaySetup(relay: entered)
        guard let setup = setup, setup.valid else {
            hostStatus.stringValue = L("먼저 ‘① 안내 복사’나 ‘설정 안내 복사’로 연결 서버를 준비하세요.",
                                       "First set up the connection server with “Copy step ①” or “Copy setup guide”.")
            return
        }
        relayAddress.stringValue = setup.relay
        do { if requestPermissions { try LocalSetup.save(setup) } }
        catch { hostStatus.stringValue = error.localizedDescription; return }
        guard CGPreflightScreenCaptureAccess() else {
            if requestPermissions { _ = CGRequestScreenCaptureAccess() }
            hostStatus.stringValue = L("화면 녹화를 켜야 해요. 아래 ‘설정 열기’에서 파이널 퓨전을 켠 뒤 ‘앱 다시 열기’를 누르세요.",
                                       "Screen Recording is needed. Turn on Final Fusion with “Open settings” below, then click “Reopen app”.")
                + checkedAt()
            refreshSenderState()
            return
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: requestPermissions] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            hostStatus.stringValue = L("손쉬운 사용을 켜야 해요. 아래 ‘설정 열기’에서 파이널 퓨전을 켜면 바로 시작해요.",
                                       "Accessibility is needed. Turn on Final Fusion with “Open settings” below and sharing starts.")
                + checkedAt()
            refreshSenderState()
            return
        }
        let link = HostLink()
        do {
            let host = try StudioHost { [weak self] message in
                guard let self = self, self.published != nil else { return }
                self.hostStatus.stringValue = message
            }
            hosting = host
            self.link = link
            host.onUpdateStatus = { [weak self] in self?.setUpdateStatus($0) }
            host.onReceiverVersion = { [weak self] in self?.recordReceiverVersion($0) }
            host.onUpdateActivity = { [weak self] activity in
                self?.updateLines.forEach { $0.show(activity) }
            }
            link.onEvent = { [weak self, weak link] event in
                guard let self = self, let link = link, self.link === link else { return }
                self.handle(event)
            }
            link.onEnd = { [weak self, weak link] in
                guard let self = self, let link = link, self.link === link else { return }
                self.retrySending(L("연결이 끊겼어요.", "The connection dropped."))
            }
            host.onFailure = { [weak self, weak host] reason in
                guard let self = self, let host = host, self.hosting === host else { return }
                self.retrySending(reason)
            }
            host.onReady = { [weak self, weak host, weak link] localPort in
                guard let self = self, let host = host, let link = link, self.hosting === host else { return }
                do { try link.start(setup: setup, code: host.code, localPort: localPort) }
                catch { self.retrySending(error.localizedDescription) }
            }
            try host.start()
            awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Studio Remote")
            hostStatus.stringValue = L("보내기를 켜는 중…", "Starting…")
            sharingLine.show(.busy)
            startHost.isEnabled = false
            endHost.isEnabled = true
            relayAddress.isEnabled = false
            directEnabled.isEnabled = false
        } catch { retrySending(error.localizedDescription) }
    }

    private func retrySending(_ reason: String) {
        closeSending()
        guard wantsHosting else { return }
        hostStatus.stringValue = reason + L(" 자동으로 다시 시도해요.", " Retrying automatically.")
        sharingLine.show(.busy)
        endHost.isEnabled = true
        let next = DispatchWorkItem { [weak self] in
            guard let self = self, self.wantsHosting else { return }
            self.hostRetry = nil
            self.startSending(requestPermissions: false)
        }
        hostRetry?.cancel()
        hostRetry = next
        DispatchQueue.main.asyncAfter(deadline: .now() + hostDelay, execute: next)
        hostDelay = min(30, hostDelay * 2)
    }

    private func handle(_ event: HostLink.Event) {
        switch event.event {
        case "relayRetry":
            hostStatus.stringValue = (event.message ?? L("연결 서버에 연결하는 중이에요.", "Connecting to the connection server."))
                + L(" 자동으로 다시 시도해요.", " Retrying automatically.")
        case "ready":
            guard let profile = event.profile, profile.valid else { return }
            published = profile
            sharingLine.show(.idle)
            refreshStepEmphasis()
            if #available(macOS 14, *) { (hosting as? StudioHost)?.receiverProfile = profile }
            hostDelay = 2
            exportApps.isEnabled = !exporting
            sendUpdates.forEach { $0.isEnabled = true }
            if updateRequestedByUser, #available(macOS 14, *) { (hosting as? StudioHost)?.sendReceiverUpdate() }
            if #available(macOS 14, *), (hosting as? StudioHost)?.activeDisplayCount == 0 {
                hostStatus.stringValue = L("보낼 준비가 됐어요. 받는 기기가 연결하면 화면을 보내요.",
                                           "Ready. Your screen is shared when a viewer connects.")
            }
        case "pair":
            guard let id = event.id, let code = event.code else { return }
            pending = id
            pendingCode = code
            pairNumber.stringValue = ""
            pairNumber.isEnabled = true
            approvalText.stringValue = L("받는 기기에 나온 6자리 번호를 입력하고 ‘허용’을 누르세요.",
                                         "Enter the 6-digit code shown on the viewer, then click “Allow”.")
            allow.isEnabled = true
            deny.isEnabled = true
            refreshStepEmphasis()
            showPage(0)
            window.contentView?.layoutSubtreeIfNeeded()
            pairNumber.scrollToVisible(pairNumber.bounds)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(pairNumber)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 75) { [weak self] in
                guard let self = self, self.pending == id else { return }
                self.clearPair(L("허용 시간이 지났어요. 받는 기기에서 다시 연결하세요.", "Time ran out. Connect again from the viewer."))
            }
        case "error":
            retrySending(event.message ?? L("보내기를 시작하지 못했어요.", "Couldn't start sharing."))
        default: break
        }
    }

    @objc private func allowPair() { answer(true) }
    @objc private func denyPair() { answer(false) }

    private func answer(_ approved: Bool) {
        guard let pending = pending, let link = link else { return }
        let code = pairNumber.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if approved && code != pendingCode {
            approvalText.stringValue = L("번호가 달라요. 받는 기기의 번호를 확인하고 다시 입력하세요.",
                                         "That code doesn't match. Check the viewer and try again.")
            return
        }
        do {
            try link.respond(pending, allow: approved, code: approved ? code : nil)
            clearPair(approved ? L("이 기기를 허용했어요.", "Device allowed.") : L("이 기기의 연결을 거절했어요.", "Device denied."))
        } catch { clearPair(L("응답하지 못했어요. 받는 기기에서 다시 연결하세요.", "Couldn't respond. Connect again from the viewer.")) }
    }

    private func clearPair(_ message: String = StudioApp.approvalIdle) {
        pending = nil
        pendingCode = nil
        pairNumber.stringValue = ""
        pairNumber.isEnabled = false
        approvalText.stringValue = message
        allow.isEnabled = false
        deny.isEnabled = false
        refreshStepEmphasis()
    }

    @objc private func confirmStopHosting() {
        guard endHost.isEnabled, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("이 맥의 송신을 중지할까요?", "Stop sharing from this Mac?")
        alert.informativeText = L("""
            송신을 중지하면 지금 연결도 끊겨요. 다시 켜려면 비상용 원격 앱으로 접속하거나, 이 맥에 모니터·키보드·마우스를 연결해 ‘보내기 시작’을 눌러야 해요.

            받는 쪽 연결만 끊으려면:
            • 맥: 받는 맥에서 \(ReceiverMode.exitKeys)
            • Windows: Esc를 길게 눌러 전체 화면에서 나온 뒤 ‘연결 끊기’
            """, """
            Stopping sharing also ends your current connection. To start sharing again, use a backup remote app or connect a monitor, keyboard, and mouse to this Mac, then click “Start sharing”.

            To disconnect just the viewer:
            • Mac: press \(ReceiverMode.exitKeys) on the viewer Mac
            • Windows: hold Esc to leave full screen, then click “Disconnect”
            """)
        let keep = alert.addButton(withTitle: L("계속 보내기", "Keep sharing"))
        keep.keyEquivalent = "\r"
        alert.addButton(withTitle: L("진짜 끄기", "Stop sharing now")).keyEquivalent = ""
        alert.beginSheetModal(for: window) { [weak self] result in
            if result == .alertSecondButtonReturn { self?.stopHosting() }
        }
    }

    private func stopHosting() {
        wantsHosting = false
        hostRetry?.cancel()
        hostRetry = nil
        closeSending()
        hostStatus.stringValue = L("보내기가 꺼져 있어요.", "Sharing is off.")
    }

    private func closeSending() {
        link?.stop()
        link = nil
        if #available(macOS 14, *) { (hosting as? StudioHost)?.stop() }
        hosting = nil
        published = nil
        sharingLine.show(.idle)
        updateLines.forEach { $0.show(.idle) }
        if let activity = awake { ProcessInfo.processInfo.endActivity(activity); awake = nil }
        startHost.isEnabled = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14
        endHost.isEnabled = false
        exportApps.isEnabled = false
        sendUpdates.forEach { $0.isEnabled = false }
        relayAddress.isEnabled = true
        directEnabled.isEnabled = true
        clearPair()
    }

    @objc private func sendReceiverUpdate() {
        updateRequestedByUser = true
        try? Data().write(to: Self.updateRequestURL, options: .atomic)
        if published != nil, #available(macOS 14, *) { (hosting as? StudioHost)?.sendReceiverUpdate() }
        refreshSenderState()
        writeHostStatus()
    }

    @objc private func requestReceiverUpdateFromCommand() { sendReceiverUpdate() }

    private var receiverUpdateRequested: Bool {
        guard !previewing, let current = ReceiverUpdateVersion.current else { return false }
        return updateRequestedByUser || lastViewerVersion.map { $0 < current } == true
    }

    private func recordReceiverVersion(_ version: ReceiverUpdateVersion) {
        if lastViewerVersion != version {
            lastViewerVersion = version
            UserDefaults.standard.set(version.label, forKey: "LastDIYViewerVersion")
        }
        if let current = ReceiverUpdateVersion.current, version >= current {
            if updateRequestedByUser {
                updateRequestedByUser = false
                try? FileManager.default.removeItem(at: Self.updateRequestURL)
            }
            if !updateStatusMessage.isEmpty {
                setUpdateStatus(L("받는 맥이 최신 버전으로 연결됐어요.", "The viewer connected with the latest version."))
            }
        }
        refreshSenderState()
        writeHostStatus()
    }

    private func checkedAt() -> String {
        " · " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium) + L(" 확인", " checked")
    }

    private func permissionPanel() -> NSView {
        openScreenSettings.set(L("설정 열기", "Open settings"), symbol: "gearshape", target: self, action: #selector(openScreenRecordingSettings))
        openAccessSettings.set(L("설정 열기", "Open settings"), symbol: "gearshape", target: self, action: #selector(openAccessibilitySettings))
        reopenApp.set(L("앱 다시 열기", "Reopen app"), symbol: "arrow.clockwise", target: self, action: #selector(reopenSender))
        for label in [screenPermission, accessPermission] { label.font = .systemFont(ofSize: 14, weight: .medium) }
        let note = NSTextField(wrappingLabelWithString: L(
            "스위치가 이미 켜져 있다면 예전 버전에 준 허용이에요. 목록에서 파이널 퓨전을 골라 －로 지우고 ＋로 다시 추가하세요. 화면 녹화는 허용한 뒤 앱을 다시 열어야 적용돼요.",
            "If the switch is already on, it belongs to an older version. Select Final Fusion, remove it with −, then add it again with +. Screen Recording applies after the app reopens."))
        note.font = .systemFont(ofSize: 13)
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 564).isActive = true
        let screenRow = row([screenPermission, openScreenSettings, reopenApp])
        let accessRow = row([accessPermission, openAccessSettings])
        for line in [screenRow, accessRow] { line.alignment = .centerY }
        permissionBox.setViews([screenRow, accessRow, note], in: .top)
        permissionBox.orientation = .vertical
        permissionBox.alignment = .leading
        permissionBox.spacing = 8
        permissionBox.isHidden = true
        return permissionBox
    }

    /// Shows which macOS permission is missing and starts sharing as soon as both are granted.
    private func refreshSenderState() {
        guard !receiverOnly else { return }
        let granted = (screen: !previewing && CGPreflightScreenCaptureAccess(), access: !previewing && AXIsProcessTrusted())
        func show(_ label: NSTextField, _ name: String, _ ok: Bool) {
            label.stringValue = "● " + name + (ok ? L(" · 허용됨", " · allowed") : L(" · 허용 필요", " · needed"))
            label.textColor = ok ? .systemGreen : .systemOrange
        }
        show(screenPermission, L("화면 녹화", "Screen Recording"), granted.screen)
        show(accessPermission, L("손쉬운 사용", "Accessibility"), granted.access)
        openScreenSettings.isHidden = granted.screen
        openAccessSettings.isHidden = granted.access
        reopenApp.isHidden = granted.screen
        let missing = !(granted.screen && granted.access)
        var layoutChanged = permissionBox.isHidden == missing
        permissionBox.isHidden = !missing
        let previous = permissionsGranted
        permissionsGranted = granted
        if let previous = previous, !(previous.screen && previous.access), !missing, wantsHosting, hosting == nil {
            startSending(requestPermissions: false)
        }
        let note = !receiverUpdateRequested ? "" : published == nil
            ? L("화면 보내기를 시작하면 DIY 업데이트를 보낼 수 있어요.", "Start sharing to send the DIY update.")
            : L("받는 맥이 새 버전으로 연결될 때까지 자동 발송이 켜져 있어요.", "Auto-send stays on until the viewer connects with the new version.")
        for label in updateNotes where label.stringValue != note {
            if label.isHidden != note.isEmpty { layoutChanged = true }
            label.stringValue = note
            label.isHidden = note.isEmpty
        }
        let summary: String
        if !previewing, let report = LocalSetup.readReport() {
            let seconds = Date().timeIntervalSince(report.receivedAt)
            let version = report.receiverAppVersion.map { L("받는 앱 \($0)", "viewer \($0)") } ?? L("받는 기기", "viewer")
            summary = seconds < 20
                ? "● " + L("\(version) 연결 중", "Connected: \(version)")
                : "● " + L("최근 연결: \(version) · ", "Last connection: \(version) · ")
                    + RelativeDateTimeFormatter().localizedString(for: report.receivedAt, relativeTo: Date())
            connectionSummary.textColor = seconds < 20 ? .systemGreen : .secondaryLabelColor
        } else {
            summary = L("아직 연결된 받는 기기가 없어요.", "No viewer has connected yet.")
            connectionSummary.textColor = .secondaryLabelColor
        }
        if connectionSummary.stringValue != summary { connectionSummary.stringValue = summary }
        if layoutChanged { fitWindow() }
    }

    @objc private func openScreenRecordingSettings() { openInputPrivacyPane("Privacy_ScreenCapture") }
    @objc private func openAccessibilitySettings() { openInputPrivacyPane("Privacy_Accessibility") }

    @objc private func reopenSender() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            DispatchQueue.main.async { if error == nil { NSApp.terminate(nil) } }
        }
    }

    /// Mirrors the sender status for `--host-status`, so the state can be checked without the window.
    private func writeHostStatus() {
        let snapshot: [String: Any] = ["status": hostStatus.stringValue, "sharing": published != nil,
                                       "updateRequested": receiverUpdateRequested, "version": ReceiverUpdateVersion.current?.label ?? "",
                                       "updateStatus": updateStatusMessage, "lastViewerVersion": lastViewerVersion?.label ?? "",
                                       "screenRecording": permissionsGranted?.screen ?? false,
                                       "accessibility": permissionsGranted?.access ?? false,
                                       "lastExport": lastExport ?? [:]]
        guard let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              data != writtenHostStatus else { return }
        var stamped = snapshot
        stamped["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        guard let output = try? JSONSerialization.data(withJSONObject: stamped, options: [.sortedKeys, .prettyPrinted]),
              (try? output.write(to: Self.hostStatusURL, options: .atomic)) != nil else { return }
        writtenHostStatus = data
    }

    private func setExportStatus(_ text: String, activity: OperationActivity) {
        for line in exportLines {
            line.label.stringValue = text
            line.show(activity)
            line.isHidden = false
        }
        fitWindow()
    }

    private func setUpdateStatus(_ text: String) {
        updateStatusMessage = text
        for line in updateLines {
            line.label.stringValue = text
            line.isHidden = false
        }
        fitWindow()
    }

    @objc private func exportReceivers() {
        guard !exporting, let profile = published else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("여기에 만들기", "Create here")
        panel.message = L("맥용과 Windows용 받는 앱을 저장할 폴더를 고르세요.", "Choose a folder for the Mac and Windows viewer apps.")
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self = self, result == .OK, let folder = panel.url else { return }
            self.exportApps.isEnabled = false
            self.exporting = true
            self.exportJobs += 1
            self.setExportStatus(L("받는 앱 두 종류를 만들고 있어요…", "Creating the viewer apps…"), activity: .busy)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try ReceiverExport.make(profile, in: folder) }
                DispatchQueue.main.async {
                    self.exporting = false
                    self.exportJobs -= 1
                    self.exportApps.isEnabled = self.published != nil
                    switch result {
                    case let .success(output):
                        self.setExportStatus(L("맥용과 Windows용 받는 앱을 만들었어요.", "Created the Mac and Windows viewer apps."), activity: self.exportJobs == 0 ? .idle : .busy)
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    case let .failure(error):
                        self.setExportStatus(error.localizedDescription, activity: self.exportJobs == 0 ? .idle : .busy)
                    }
                }
            }
        }
    }

    @objc private func beginViewing() {
        guard viewing == nil, !installingReceiverUpdate, let receiver = receiver else { return }
        do {
            let viewer = StudioViewer(receiverMode: receiverOnly ? receiverMode : nil) { [weak self] message in
                self?.viewerStatus.stringValue = message
                self?.receiverMode.status(message)
            }
            viewer.resolution = temporaryResolution ?? selectedResolution
            viewer.screenMargin = screenEdge.indexOfSelectedItem == 1 ? 0.025 : 0
            viewer.diagnosticsEnabled = diagnostics.state == .on
            viewer.matchInputSource = inputLanguage.state == .on
            viewer.onConnected = { [weak self] in
                guard let self = self else { return }
                self.viewingLine.show(.idle)
                self.receiverMode.setActivity(.idle)
                guard self.receiverOnly else { return }
                self.receiverDelay = 2
                UserDefaults.standard.set(true, forKey: "ReceiverPreviouslyConnected")
                self.window.orderOut(nil)
                self.receiverMode.enter()
            }
            viewer.onStopped = { [weak self] in self?.viewerStopped() }
            if receiverOnly {
                viewer.remoteTuningAllowed = remoteTuning.state == .on
                viewer.onResolutionRequested = { [weak self, weak viewer] resolution in
                    guard let self = self, let viewer = viewer, self.viewing === viewer,
                          self.receiverMode.isActive, self.remoteTuning.state == .on else { return }
                    self.temporaryResolution = resolution
                    viewer.stop(L("화질을 바꾸고 다시 연결해요.", "Changing quality and reconnecting."))
                }
                viewer.onUpdateReady = { [weak self, weak viewer] file, offer in
                    guard let self, let viewer, self.viewing === viewer else { return }
                    self.receiveUpdate(file, offer: offer)
                }
            }
            viewingLine.show(.busy)
            receiverMode.setActivity(.busy)
            try viewer.start(profile: receiver)
            saveReceiverOptions()
            viewing = viewer
            quality.isEnabled = false
            connect.isEnabled = false
            checkUpdate.isEnabled = false
            disconnect.isEnabled = true
        } catch {
            viewerStatus.stringValue = error.localizedDescription
            receiverMode.status(error.localizedDescription)
            viewerStopped()
        }
    }

    @objc private func checkReceiverUpdate() {
        guard viewing == nil, !installingReceiverUpdate, let profile = receiver else { return }
        let viewer = StudioViewer { [weak self] message in self?.viewerStatus.stringValue = message }
        viewer.onUpdateVersion = { [weak self, weak viewer] available in
            guard let self = self, let viewer = viewer else { return }
            self.downloadReceiverUpdate(available, on: viewer)
        }
        viewer.onUpdateReady = { [weak self, weak viewer] file, offer in
            guard let self, let viewer, self.viewing === viewer else { return }
            self.receiveUpdate(file, offer: offer)
        }
        viewer.onStopped = { [weak self] in self?.viewerStopped() }
        do {
            viewingLine.show(.busy)
            try viewer.start(profile: profile)
            viewing = viewer
            connect.isEnabled = false
            checkUpdate.isEnabled = false
            disconnect.isEnabled = true
        } catch {
            viewerStatus.stringValue = error.localizedDescription
            viewingLine.show(.idle)
        }
    }

    private func downloadReceiverUpdate(_ available: ReceiverUpdateVersion, on viewer: StudioViewer) {
        guard let current = ReceiverUpdateVersion.current else {
            viewer.stop(L("설치된 버전을 읽지 못했어요.", "Couldn't read the installed version."))
            return
        }
        guard available > current else {
            viewer.stop(L("받는 앱 \(current.label) · 최신 버전이에요.", "Viewer \(current.label) is up to date."))
            return
        }
        if viewer.requestCheckedUpdate() {
            viewerStatus.stringValue = L("DIY 업데이트를 준비하고 있어요…", "Preparing the DIY update…")
        } else {
            viewer.stop(L("DIY 업데이트를 요청하지 못했어요.", "Couldn't request the DIY update."))
        }
    }

    private func receiveUpdate(_ file: URL, offer: ReceiverUpdateOffer) {
        guard !installingReceiverUpdate else { return }
        receiverRetry?.cancel()
        receiverRetry = nil
        receiverMode.leave()
        viewing?.stop()
        receivedUpdate = (file, offer)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installReceivedUpdate()
    }

    @objc private func installReceivedUpdate() {
        guard let (file, offer) = receivedUpdate, !installingReceiverUpdate, viewing == nil else { return }
        installingReceiverUpdate = true
        viewingLine.show(.busy)
        connect.isEnabled = false
        checkUpdate.isEnabled = false
        installUpdate.isHidden = true
        viewerStatus.stringValue = L("DIY 업데이트를 확인하고 설치하고 있어요…", "Checking and installing the DIY update…")
        fitWindow()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ReceiverUpdateInstall.prepare(file, offer: offer) }
            DispatchQueue.main.async { self.finishReceiverUpdate(result, file: file) }
        }
    }

    private func finishReceiverUpdate(_ result: Result<ReceiverUpdateInstall, Error>, file: URL) {
        switch result {
        case let .success(install):
            install.refreshLaunchRegistration()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.promptsUserIfNeeded = false
            NSWorkspace.shared.openApplication(at: install.application, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    guard error == nil, let app = app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                        self.restoreReceiverAfterLaunchFailure(install)
                        return
                    }
                    self.confirmReceiverLaunch(app, install: install, file: file, deadline: .now() + 15)
                }
            }
        case let .failure(error):
            if error is ReceiverUpdateInstallError, NSWorkspace.shared.open(file) {
                updateInstallFailed(L("자동으로 설치할 수 없어요. 설치 파일에서 새 앱을 응용 프로그램 폴더로 옮겨 주세요.",
                                      "Couldn't install automatically. Move the new app from the installer into Applications."))
            } else {
                updateInstallFailed(error is ReceiverUpdateInstallError
                    ? L("받은 설치 파일을 열지 못했어요.", "Couldn't open the received installer.")
                    : error.localizedDescription)
            }
        }
    }

    private func confirmReceiverLaunch(_ app: NSRunningApplication, install: ReceiverUpdateInstall,
                                       file: URL, deadline: DispatchTime) {
        if !app.isTerminated, app.isFinishedLaunching,
           app.bundleURL?.resolvingSymlinksInPath().path == install.application.path {
            install.finish()
            try? FileManager.default.removeItem(at: file)
            installingReceiverUpdate = false
            receiverMayQuit = true
            NSApp.terminate(nil)
        } else if app.isTerminated || DispatchTime.now() >= deadline {
            if !app.isTerminated { _ = app.terminate() }
            restoreReceiverAfterLaunchFailure(install)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) { [weak self] in
                self?.confirmReceiverLaunch(app, install: install, file: file, deadline: deadline)
            }
        }
    }

    private func restoreReceiverAfterLaunchFailure(_ install: ReceiverUpdateInstall) {
        let restored = install.rollBack()
        updateInstallFailed(restored
            ? L("새 앱을 열지 못했어요. 원래 앱으로 돌아왔어요.", "Couldn't open the new app. Restored the previous app.")
            : L("새 앱을 열지 못했어요. 설치 파일을 다시 확인해 주세요.", "Couldn't open the new app. Please check the installer."))
    }

    private func updateInstallFailed(_ message: String) {
        installingReceiverUpdate = false
        viewingLine.show(.idle)
        connect.isEnabled = receiver != nil
        checkUpdate.isEnabled = receiver != nil
        installUpdate.isEnabled = receivedUpdate != nil
        installUpdate.isHidden = receivedUpdate == nil
        viewerStatus.stringValue = message
        fitWindow()
    }

    private func viewerStopped() {
        viewing = nil
        quality.isEnabled = true
        connect.isEnabled = receiver != nil
        checkUpdate.isEnabled = receiver != nil
        disconnect.isEnabled = false
        viewingLine.show(.idle)
        receiverMode.setActivity(.idle)
        guard receiverMode.isActive, !receiverMayQuit else { return }
        receiverMode.setActivity(.busy)
        let next = DispatchWorkItem { [weak self] in
            guard let self = self, self.receiverMode.isActive, !self.receiverMayQuit else { return }
            self.receiverRetry = nil
            self.beginViewing()
        }
        receiverRetry?.cancel()
        receiverRetry = next
        receiverMode.status(viewerStatus.stringValue + L(" 자동으로 다시 연결해요.", " Reconnecting automatically."))
        DispatchQueue.main.asyncAfter(deadline: .now() + receiverDelay, execute: next)
        receiverDelay = min(15, receiverDelay * 2)
    }

    @objc private func stopViewing() {
        guard !receiverMode.isActive else { return }
        viewing?.stop()
    }
}

signal(SIGPIPE, SIG_IGN)
let arguments = CommandLine.arguments
let receiverOnly = Bundle.main.object(forInfoDictionaryKey: "StudioReceiverOnly") as? Bool == true
if arguments.count == 2, arguments[1] == "--verify-receiver-startup", receiverOnly {
    exit(ReceiverProfile.bundled() == nil ? 1 : 0)
} else if arguments.count == 2, arguments[1] == "--support-report-shareable" {
    let report = receiverOnly ? SupportReport.viewer(status: "") : SupportReport.host()
    print(SupportReport.text(SupportReport.shareable(report)))
    exit(0)
} else if arguments.count == 2, arguments[1] == "--receiver-report", !receiverOnly {
    do {
        guard LocalSetup.readReport() != nil else {
            throw StudioError.message(L("아직 받은 연결 상태 정보가 없어요.", "No connection info received yet."))
        }
        let report = try String(contentsOf: LocalSetup.reportURL, encoding: .utf8)
        print(report)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.count == 3, arguments[1] == "--set-receiver-resolution", !receiverOnly {
    do {
        let resolutions: [String: ReceiverResolution] = ["low": .low, "medium": .medium, "high": .high, "native": .native]
        guard let resolution = resolutions[arguments[2]] else {
            throw StudioError.message(L("받는 화질은 low, medium, high, native 중에서 고르세요.",
                                        "Choose the viewer quality: low, medium, high or native."))
        }
        let sent = try LocalSetup.requestReceiverResolution(resolution)
        print(sent ? L("받는 화질 변경 요청: ", "Requested viewer quality: ") + resolution.title
                   : L("받는 앱이 이미 이 화질을 쓰고 있어요.", "The viewer already uses this quality."))
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.count == 2, arguments[1] == "--send-receiver-update", !receiverOnly {
    DistributedNotificationCenter.default().postNotificationName(StudioApp.updateRequest, object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    print(L("실행 중인 「\(ProductName.sender)」 앱에 받는 앱 업데이트 보내기를 요청했어요. 결과는 --host-status로 확인하세요.",
            "Asked the running \(ProductName.sender) to send the viewer update. Check the result with --host-status."))
} else if arguments.count == 2, arguments[1] == "--host-status", !receiverOnly {
    guard let data = try? Data(contentsOf: StudioApp.hostStatusURL), data.count <= 16384 else {
        fputs(L("아직 기록된 보내기 상태가 없어요. 앱을 연 뒤 다시 확인하세요.", "No sharing status yet. Open the app and try again.") + "\n", stderr)
        exit(1)
    }
    print(String(decoding: data, as: UTF8.self))
} else if arguments.count == 2, arguments[1] == "--start-sharing", !receiverOnly {
    DistributedNotificationCenter.default().postNotificationName(StudioApp.startRequest, object: nil, userInfo: nil,
                                                                 deliverImmediately: true)
    print(L("실행 중인 「\(ProductName.sender)」 앱에 보내기 시작을 요청했어요. --host-status로 확인하세요.",
            "Asked the running \(ProductName.sender) to start sharing. Check with --host-status."))
} else if arguments.count == 2, arguments[1] == "--support-report", !receiverOnly {
    print(SupportReport.text(SupportReport.host()))
} else if (3...4).contains(arguments.count), arguments[1] == "--export-receivers", !receiverOnly {
    let folder = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
    let target = arguments.count == 4 ? ViewerTarget(rawValue: arguments[3]) : nil
    guard arguments.count == 3 || target != nil else {
        fputs(L("기기는 ", "Device must be one of ") + ViewerTarget.allCases.map(\.rawValue).joined(separator: ", ")
              + L(" 중에서 고르세요.\n", ".\n"), stderr)
        exit(2)
    }
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let id = UUID().uuidString
    var request: [String: String] = ["id": id, "folder": folder.path]
    if let target = target { request["target"] = target.rawValue }
    DistributedNotificationCenter.default().postNotificationName(StudioApp.exportRequest, object: nil, userInfo: request,
                                                                 deliverImmediately: true)
    let deadline = Date().addingTimeInterval(120)
    while Date() < deadline {
        if let data = try? Data(contentsOf: StudioApp.hostStatusURL),
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let export = status["lastExport"] as? [String: String], export["id"] == id {
            if let error = export["error"], !error.isEmpty { fputs(error + "\n", stderr); exit(1) }
            print(export["path"] ?? "")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    fputs(L("보내는 앱이 응답하지 않아요. 앱이 실행 중이고 보내기가 켜져 있는지 확인하세요.\n",
            "The host app didn't answer. Make sure it's running and sharing.\n"), stderr)
    exit(1)
} else if arguments.count == 2, arguments[1] == "--stream-mode", !receiverOnly {
    print(LocalSetup.streamMode().rawValue)
} else if arguments.count == 3, arguments[1] == "--set-stream-mode", !receiverOnly {
    do {
        guard let mode = StreamMode(rawValue: arguments[2]) else {
            throw StudioError.message(L("화면 방식은 auto, smooth, sharp 중에서 고르세요.",
                                        "Choose a screen mode: auto, smooth or sharp."))
        }
        try LocalSetup.saveStreamMode(mode)
        print(L("화면 방식 \(mode.title)", "Screen mode \(mode.title)"))
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.count == 3, arguments[1] == "--set-relay", !receiverOnly {
    do {
        try LocalSetup.save(RelaySetup(relay: arguments[2]))
        print(L("연결 서버 주소를 저장했어요. 「\(ProductName.sender)」 앱에서 ‘보내기 시작’을 누르세요.",
                "Connection server address saved. Click “Start sharing” in \(ProductName.sender)."))
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.count == 2, arguments[1] == "--relay-id", !receiverOnly {
    do {
        try LocalSetup.prepare()
        let helper = Process()
        helper.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StudioLink")
        helper.arguments = ["relay-id", LocalSetup.home.path]
        helper.environment = ProcessInfo.processInfo.environment.merging([AppLanguage.environmentKey: AppLanguage.code]) { $1 }
        try helper.run()
        helper.waitUntilExit()
        exit(helper.terminationStatus)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if (3...4).contains(arguments.count), arguments[1] == "--test-export" {
    do {
        let profile = ReceiverProfile(relay: "https://relay.example.com", room: String(repeating: "a3", count: 32),
                                      pin: String(repeating: "d1", count: 32), invitation: String(repeating: "e2", count: 16), macPin: nil)
        let folder = URL(fileURLWithPath: arguments[2], isDirectory: true)
        print(try ReceiverExport.make(profile, in: folder, target: arguments.count == 4 ? ViewerTarget(rawValue: arguments[3]) : nil).path)
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else if arguments.count == 3, arguments[1] == "--preview-ui" {
    runUIPreview(output: URL(fileURLWithPath: arguments[2], isDirectory: true))
} else if arguments.contains("--self-test") {
    runSelfTests()
} else if arguments.contains("--test-loopback") {
    runLoopbackTest()
} else if arguments.contains("--test-native-video") {
    runVideoTest(width: 2880, height: 1800)
} else if arguments.contains("--test-video") {
    runVideoTest()
} else if arguments == [arguments[0], "--test-separated-transport"] {
    guard #available(macOS 14, *) else { exit(1) }
    runSeparatedTransportTest()
} else if arguments.count == 3, arguments[1] == "--test-session" {
    guard #available(macOS 14, *) else { exit(1) }
    runSessionTest(output: URL(fileURLWithPath: arguments[2]))
} else {
    let app = NSApplication.shared
    let delegate = StudioApp()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}

/// Top-to-bottom document view for the settings scroll view.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
