import AppKit
import ApplicationServices

/// The device that will run the viewer app. It decides which file is sent and the first-run steps.
enum ViewerTarget: String, CaseIterable {
    case appleSilicon = "apple-silicon", intelMac = "intel-mac", windowsMac = "windows-mac", windowsPC = "windows-pc"

    var title: String {
        switch self {
        case .appleSilicon: return L("애플 실리콘 맥 (M1 이후)", "Apple silicon Mac (M1 or later)")
        case .intelMac: return L("인텔 맥 (오래된 맥)", "Intel Mac (older Mac)")
        case .windowsMac: return L("Windows가 깔린 맥 (Boot Camp)", "Mac running Windows (Boot Camp)")
        case .windowsPC: return L("Windows 노트북·PC", "Windows laptop or PC")
        }
    }

    var isMac: Bool { self == .appleSilicon || self == .intelMac }
    var file: String { isMac ? ProductName.receiverImage : ProductName.receiver + ".exe" }

    /// Steps the person on the viewing computer follows after opening the email.
    var firstRun: String {
        if isMac {
            let requirement = self == .intelMac
                ? L("macOS 11 Big Sur 이상이 필요해요(대략 2013년 이후 맥). ‘이 Mac에 관하여’에서 버전을 확인하세요.",
                    "Requires macOS 11 Big Sur or later (roughly 2013 or newer). Check in About This Mac.")
                : L("macOS 11 이상이면 돼요.", "Requires macOS 11 or later.")
            return L("""
            1. \(requirement)
            2. 링크에서 「\(file)」 파일을 내려받아 여세요. 안의 「Studio Receiver」를 응용 프로그램 폴더로 끌어다 놓으세요.
            3. 응용 프로그램 폴더에서 앱을 여세요. "확인할 수 없는 개발자" 창이 뜨면 시스템 설정 → 개인정보 보호 및 보안 → 아래쪽 「그래도 열기」를 누르세요. (macOS 14 이하는 앱을 Control-클릭 → 「열기」도 돼요.)
            4. 「연결하기」를 누르면 6자리 번호가 나와요. 보내는 맥의 파이널 퓨전 「③ 첫 연결」 칸에 이 번호를 입력하고 「허용」을 누르세요.
            5. 「단축키 켜기」를 눌러 손쉬운 사용과 입력 모니터링을 켜면 ⌘+Space·⌘+Tab도 보내는 맥으로 가요.
            6. 원격 화면에서 설정으로 돌아오기: \(ReceiverMode.exitKeys)
            """, """
            1. \(requirement)
            2. Download “\(file)” from the link and open it. Drag “Studio Receiver” into the Applications folder.
            3. Open it from Applications. If macOS says it can't verify the developer, go to System Settings → Privacy & Security and click “Open Anyway” near the bottom. (On macOS 14 or earlier you can also Control-click the app → Open.)
            4. Click “Connect”. A 6-digit code appears. Enter it under “③ First connection” in Final Fusion on the host Mac and click “Allow”.
            5. Click “Turn on shortcuts” and turn on Accessibility and Input Monitoring so ⌘+Space and ⌘+Tab reach the host Mac.
            6. To return to settings from the remote screen: \(ReceiverMode.exitKeys)
            """)
        }
        let keyboard = self == .windowsMac
            ? L("키보드는 맥 배열(⌘ = Windows 키 자리)로 자동 설정돼요.", "The keyboard is set to the Mac layout automatically (⌘ in the Windows key spot).")
            : L("키보드는 놓인 순서대로 Ctrl·Win·Alt가 맥의 Control·Option·Command예요. 설정의 「키보드」에서 바꿀 수 있어요.",
                "Ctrl·Win·Alt act as the Mac's Control·Option·Command in the same order. Change it under “Keyboard”.")
        return L("""
        1. Windows 10·11 64비트와 Microsoft Edge 또는 Google Chrome이 필요해요.
        2. 링크에서 「\(file)」 파일을 내려받아 여세요. "Windows의 PC 보호" 창이 뜨면 「추가 정보」 → 「실행」을 누르세요.
        3. 「연결하기」를 누르면 6자리 번호가 나와요. 보내는 맥의 파이널 퓨전 「③ 첫 연결」 칸에 이 번호를 입력하고 「허용」을 누르세요.
        4. \(keyboard)
        5. 화면의 「전체 화면」을 누르면 Windows 키·Alt+Tab도 맥으로 가요. 나갈 때는 Esc를 길게 누르세요.
        """, """
        1. Requires 64-bit Windows 10 or 11 with Microsoft Edge or Google Chrome.
        2. Download “\(file)” from the link and open it. If “Windows protected your PC” appears, click “More info” → “Run anyway”.
        3. Click “Connect”. A 6-digit code appears. Enter it under “③ First connection” in Final Fusion on the host Mac and click “Allow”.
        4. \(keyboard)
        5. Click “Full screen” to send the Windows key and Alt+Tab to the Mac as well. Hold Esc to leave full screen.
        """)
    }
}

/// Prompts copied by the step buttons. Each one is complete on its own, so any AI agent
/// with terminal access (Claude Code, Codex and similar) can follow it.
enum AgentGuide {
    static let sourceURL = (Bundle.main.object(forInfoDictionaryKey: "FinalFusionSource") as? String)
        ?? "https://github.com/salmanhyu-wq/final-fusion-remote"

    static var executable: String { portablePath(Bundle.main.executableURL?.path ?? "") }
    static var application: String { portablePath(Bundle.main.bundleURL.path) }
    static var relayFolder: String { portablePath(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Relay").path) }

    private static func portablePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/") else { return quoted(path) }
        return #""$HOME"/"# + quoted(String(path.dropFirst(home.count + 1)))
    }
    static var version: String { ReceiverUpdateVersion.current?.label ?? "?" }

    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func setup() -> String {
        L("""
        [파이널 퓨전 · ① 시작 준비]
        너는 이 맥에서 터미널을 쓸 수 있는 AI 에이전트야. 이 맥의 화면을 다른 컴퓨터에서 쓰도록 파이널 퓨전 보내는 앱을 준비해 줘. 사용자는 꼭 필요한 일(계정 가입·로그인, 약관·결제 동의, macOS 권한 허용)만 하고 나머지는 네가 해.

        정보
        - 앱 실행 파일: \(executable)  (버전 \(version))
        - 중계 서버 코드 폴더: \(relayFolder)  (SETUP.md, worker.js, wrangler.toml)
        - 전체 진단: \(executable) --support-report   (JSON)

        할 일
        1. --support-report를 실행해. relayConfigured와 sharing이 모두 true면 이미 준비된 거야. 사용자에게 알리고 ② 단계로 넘어가라고 해.
        2. 중계 서버가 없으면 중계 폴더를 쓰기 가능한 임시 폴더로 복사하고 SETUP.md대로 해. Cloudflare Workers 무료 플랜을 써. 사용자에게는 Cloudflare 가입·로그인(브라우저)과 약관 동의만 부탁해. 배포 전에 어떤 계정에 무엇을 올리는지 보여 주고 확인받아.
        3. \(executable) --relay-id 로 공개 연결 번호를 얻어 배포 변수 STUDIO_ROOM에 넣어 배포해. 배포 주소의 /health가 200인지 확인해.
        4. \(executable) --set-relay <https 주소> 로 저장하고 \(executable) --start-sharing 으로 보내기를 시작해.
        5. --support-report에서 screenRecording이나 accessibility가 false면, 사용자에게 파이널 퓨전 창의 「설정 열기」로 허용하라고 안내해. 스위치가 이미 켜져 있으면 예전 버전용이라 －로 지우고 ＋로 다시 추가해야 해. 화면 녹화는 허용 뒤 「앱 다시 열기」가 필요해.
        6. sharing이 true가 되면 끝이야. 사용자에게 「② 받는 앱 보내기」로 넘어가라고 알려 줘.

        지킬 것: 중계 비밀, Cloudflare 토큰, 설정 폴더의 키 파일을 출력하거나 다른 곳에 복사하지 마. 가입·약관·결제는 사용자가 직접 해.
        """, """
        [Final Fusion · ① Get ready]
        You are an AI agent with terminal access on this Mac. Prepare the Final Fusion host app so this Mac's screen can be used from another computer. The user only does what must be done by a person (sign-up and sign-in, accepting terms or payment, allowing macOS permissions); you do the rest.

        Info
        - App executable: \(executable)  (version \(version))
        - Relay server code: \(relayFolder)  (SETUP.md, worker.js, wrangler.toml)
        - Full diagnostics: \(executable) --support-report   (JSON)

        Steps
        1. Run --support-report. If relayConfigured and sharing are both true, everything is ready: tell the user and move on to step ②.
        2. If there is no relay, copy the relay folder to a writable temporary folder and follow SETUP.md with the Cloudflare Workers free plan. Ask the user only to sign up or sign in to Cloudflare in the browser and accept the terms. Before deploying, show which account and what will be deployed and get approval.
        3. Get the public room ID with \(executable) --relay-id, deploy with it as STUDIO_ROOM, and check that /health on the deployed address returns 200.
        4. Save the address with \(executable) --set-relay <https address> and start sharing with \(executable) --start-sharing.
        5. If --support-report shows screenRecording or accessibility as false, tell the user to allow them with “Open settings” in the Final Fusion window. A switch that is already on belongs to an older version: remove it with − and add the app again with +. Screen Recording needs “Reopen app” afterwards.
        6. When sharing is true you're done. Tell the user to continue with “② Send the viewer app”.

        Rules: never print or copy the relay secret, Cloudflare tokens or the key files in the settings folder. The user handles sign-up, terms and payment personally.
        """)
    }

    static func viewer(_ target: ViewerTarget) -> String {
        L("""
        [파이널 퓨전 · ② 받는 앱 보내기 · \(target.title)]
        너는 이 맥에서 터미널을 쓸 수 있는 AI 에이전트야. 받는 컴퓨터(\(target.title))가 이 맥에 연결할 수 있게 받는 앱을 만들어 이메일로 보내 줘.

        1. \(executable) --support-report 로 sharing이 true인지 확인해. false면 「① 시작 준비」부터 하라고 안내하고 멈춰.
        2. 사용자에게 받는 앱을 보낼 이메일 주소를 물어봐.
        3. 임시 폴더를 만들고 \(executable) --export-receivers <폴더> \(target.rawValue) 를 실행해. 출력된 폴더에 「\(target.file)」 파일과 「\(L("처음 읽기.txt", "Read Me First.txt"))」 파일이 생겨.
        4. Gmail·Outlook 등은 .dmg·.exe 첨부를 막아. 이 맥에 있는 클라우드(iCloud Drive, Google Drive, OneDrive, Dropbox 등)에 파일을 올리고 공유 링크를 만들어. 가능하면 받는 사람만 열 수 있게 해.
        5. 제목 "파이널 퓨전 받는 앱 (\(target.title))"으로, 본문에 공유 링크와 아래 「처음 연결 방법」을 넣어. 보내기 전에 받는 사람·제목·본문을 보여 주고 확인받아. 이 맥의 메일 앱(osascript)이나 네가 쓸 수 있는 메일 도구로 보내.
        6. 보낸 뒤 사용자에게 알려 줘: 받는 컴퓨터에서 메일을 열고 설치해 「연결하기」를 누르면 6자리 번호가 나오고, 그 번호를 이 맥의 파이널 퓨전 「③ 첫 연결」 칸에 입력해 허용하면 된다고.
        7. 연결되면 --support-report의 receiver 항목에 받는 앱 버전과 최근 시각이 보여. 그걸 확인하고 알려 줘.

        주의: 받는 앱 파일에는 이 맥의 연결 정보가 들어 있어. 공개된 곳에 올리거나 다른 사람에게 보내지 마. (6자리 번호를 허용하기 전에는 연결되지 않아.)

        처음 연결 방법 (메일 본문에 넣을 내용)
        \(target.firstRun)
        """, """
        [Final Fusion · ② Send the viewer app · \(target.title)]
        You are an AI agent with terminal access on this Mac. Create the viewer app so the viewing computer (\(target.title)) can connect to this Mac, and send it by email.

        1. Check with \(executable) --support-report that sharing is true. If not, tell the user to do “① Get ready” first and stop.
        2. Ask the user which email address should receive the viewer app.
        3. Make a temporary folder and run \(executable) --export-receivers <folder> \(target.rawValue). The printed folder contains “\(target.file)” and “Read Me First.txt”.
        4. Gmail, Outlook and others block .dmg and .exe attachments. Upload the file to a cloud drive available on this Mac (iCloud Drive, Google Drive, OneDrive, Dropbox…) and create a share link, restricted to the recipient if possible.
        5. Use the subject “Final Fusion viewer (\(target.title))” and put the share link and the “First connection” steps below in the body. Show the recipient, subject and body to the user and get approval before sending. Send it with this Mac's Mail app (osascript) or any mail tool you have.
        6. Afterwards tell the user: on the viewing computer, open the email, install, and click “Connect”; a 6-digit code appears, which they enter under “③ First connection” in Final Fusion on this Mac and allow.
        7. Once connected, --support-report shows the viewer version and time under receiver. Confirm it and report back.

        Note: the viewer file contains this Mac's connection details. Don't post it publicly or send it to anyone else. (It can't connect until its 6-digit code is allowed.)

        First connection (put this in the email)
        \(target.firstRun)
        """)
    }

    static func fix(report: String) -> String {
        L("""
        [파이널 퓨전 · ④ 바로 고치기]
        너는 이 맥에서 터미널과 파일을 다룰 수 있는 AI 에이전트야. 사용자가 파이널 퓨전(이 맥의 화면을 다른 컴퓨터에서 쓰는 원격 앱)을 쓰다가 불편한 점을 바로 고치고 싶어 해.
        먼저 "무엇이 불편하신가요? 어느 기기에서, 언제 그런지 알려 주세요."라고 물어봐. 답을 듣기 전에는 아무것도 바꾸지 마.

        정보
        - 보내는 앱: \(application)  (실행 파일 \(executable), 버전 \(version))
        - 소스: \(sourceURL)  (README.md, AGENTS.md, DEVELOPMENT.md에 구조·빌드·시험 방법이 있어)
        - 확인 명령: --support-report(전체 진단), --host-status, --receiver-report(받는 쪽이 보낸 최신 진단), --stream-mode, --set-stream-mode auto|smooth|sharp, --set-receiver-resolution low|medium|high|native, --start-sharing, --send-receiver-update, --export-receivers <폴더> <기기>
        - 복사한 순간의 진단:
        \(report)

        고치는 순서
        1. 사용자 설명과 진단을 맞춰 원인을 찾아. 설정으로 풀리면(화질, 전송 모드, 바로 연결 등) 명령으로 먼저 바꾸고 사용자에게 확인받아.
        2. 코드를 고쳐야 하면 소스를 받아(git clone 또는 git pull) AGENTS.md·DEVELOPMENT.md를 먼저 읽어. 고친 뒤 Info.plist의 CFBundleShortVersionString(세 자리)과 CFBundleVersion을 올리고, build.sh로 임시 폴더에 빌드해서 --self-test, --test-session <png>, --test-export <폴더>, Link 폴더의 go test를 통과시켜.
        3. 설치 전에 무엇을 바꿨는지 보여 주고 확인받아. 지금 앱을 복구용으로 복사해 두고, osascript -e 'quit app id "app.finalfusion.remote"' 로 정상 종료한 뒤 새 앱으로 바꿔 열어.
        4. 키체인에 「Final Fusion Signing」 코드 서명 인증서가 있으면 build.sh가 그걸로 서명해서 macOS 권한이 그대로 유지돼(--support-report의 screenRecording·accessibility가 true인지 확인). 인증서가 없는 개발용 서명이면 화면 녹화·손쉬운 사용을 다시 허용해야 해. 사용자에게 파이널 퓨전 창의 「설정 열기」에서 －로 지우고 ＋로 다시 추가하라고 안내하고, --support-report의 sharing이 true가 될 때까지 기다려.
        5. 받는 맥에는 \(executable) --send-receiver-update 로 DIY 업데이트를 요청해. 구버전 받는 앱에서는 첫 설치 확인이 필요할 수 있고, 새 받는 앱은 파일을 확인한 뒤 자동 설치해. Windows 받는 쪽은 --export-receivers로 새 .exe를 만들어 ② 단계처럼 링크로 보내.
        6. --receiver-report의 receiverAppVersion이 새 버전이면 끝이야. 바꾼 내용과 확인 결과를 짧게 알려 줘.

        지킬 것: 번들 ID(app.finalfusion.remote, app.finalfusion.remote.receiver), 설정 폴더, 업데이트 디스크 안의 「Studio Receiver.app」 이름은 바꾸지 마. 중계 비밀과 기기 키를 출력하거나 올리지 마. 지우거나 덮어쓰기 전에 복구본을 만들어.
        """, """
        [Final Fusion · ④ Fix it now]
        You are an AI agent that can use the terminal and files on this Mac. The user is using Final Fusion (a remote app for using this Mac's screen from another computer) and wants something fixed right away.
        First ask: "What's bothering you? Which device, and when does it happen?" Don't change anything before you have the answer.

        Info
        - Host app: \(application)  (executable \(executable), version \(version))
        - Source: \(sourceURL)  (README.md, AGENTS.md and DEVELOPMENT.md explain the structure, build and tests)
        - Commands: --support-report (full diagnostics), --host-status, --receiver-report (latest viewer diagnostics), --stream-mode, --set-stream-mode auto|smooth|sharp, --set-receiver-resolution low|medium|high|native, --start-sharing, --send-receiver-update, --export-receivers <folder> <device>
        - Diagnostics at the moment this was copied:
        \(report)

        How to fix
        1. Match the user's description with the diagnostics. If a setting solves it (quality, stream mode, direct connection…), change it with a command first and confirm with the user.
        2. If code must change, get the source (git clone or git pull) and read AGENTS.md and DEVELOPMENT.md first. After the change, raise CFBundleShortVersionString (three numbers) and CFBundleVersion in Info.plist, build with build.sh into a temporary folder, and pass --self-test, --test-session <png>, --test-export <folder> and go test in the Link folder.
        3. Before installing, show what changed and get approval. Copy the current app as a backup, quit it cleanly with osascript -e 'quit app id "app.finalfusion.remote"', replace it with the new app and open it.
        4. If the keychain has the “Final Fusion Signing” code signing certificate, build.sh signs with it and macOS permissions stay (check that screenRecording and accessibility are true in --support-report). With plain development signing, Screen Recording and Accessibility must be allowed again. Tell the user to use “Open settings” in the Final Fusion window, remove the entry with − and add it again with +, and wait until --support-report shows sharing as true.
        5. Use \(executable) --send-receiver-update to request a DIY update for Mac viewers. Older viewers may show an install prompt once. Newer viewers verify and install the update automatically. For Windows viewers, make a new .exe with --export-receivers and send a link as in step ②.
        6. You're done when receiverAppVersion in --receiver-report shows the new version. Briefly report what changed and how you checked it.

        Rules: keep the bundle IDs (app.finalfusion.remote, app.finalfusion.remote.receiver), the settings folder and the “Studio Receiver.app” name inside update disks. Never print or upload the relay secret or device keys. Make a backup before deleting or overwriting anything.
        """)
    }

    /// Copied on the viewer side: the viewer's own state plus what to do next.
    static func viewerFix(report: String) -> String {
        L("""
        [파이널 퓨전 받기 · 바로 고치기]
        너는 AI 에이전트야. 이 내용은 파이널 퓨전 받는 앱(\(application), 버전 \(version))에서 복사됐어.
        먼저 사용자에게 무엇이 불편한지 물어봐. 프로그램을 고치는 일은 보내는 맥에서 해야 해: 사용자에게 원격 화면에서 보내는 맥의 파이널 퓨전을 열고 「④ 바로 고치기」의 「④ 안내 복사」를 눌러 그쪽 AI 도우미에 붙여넣으라고 안내해. 이 기기에서 할 수 있는 일(권한 허용, 앱 위치, 키보드·화질 설정 확인)은 여기서 도와줘.
        이 기기 진단:
        \(report)
        """, """
        [Final Fusion Viewer · Fix it now]
        You are an AI agent. This was copied from the Final Fusion viewer (\(application), version \(version)).
        First ask the user what's bothering them. Program changes happen on the host Mac: tell the user to open Final Fusion on the host Mac through the remote screen, click “Copy step ④” under “④ Fix it now”, and paste it into the AI assistant there. Help here with what this device can do itself (permissions, app location, keyboard and quality settings).
        This device's diagnostics:
        \(report)
        """)
    }
}

/// `--support-report`: everything an agent needs to diagnose the host, without secrets.
enum SupportReport {
    static func host() -> [String: Any] {
        var report: [String: Any] = [
            "app": "Final Fusion", "version": AgentGuide.version,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "appPath": Bundle.main.bundleURL.path, "settingsFolder": LocalSetup.home.path,
            "source": AgentGuide.sourceURL, "language": AppLanguage.code,
            "relayConfigured": LocalSetup.load() != nil, "relay": LocalSetup.load()?.relay ?? "",
            "directConnection": LocalSetup.directEnabled(), "streamMode": LocalSetup.streamMode().rawValue,
            "loginItem": ReceiverLogin.isRegistered
        ]
        if let data = try? Data(contentsOf: StudioApp.hostStatusURL), data.count <= 16384,
           let status = try? JSONSerialization.jsonObject(with: data) {
            report["host"] = status
        } else {
            report["host"] = ["status": L("보내는 앱이 실행 중이 아니에요.", "The host app isn't running.")]
        }
        if let data = try? Data(contentsOf: LocalSetup.reportURL), data.count <= 16384,
           let receiver = try? JSONSerialization.jsonObject(with: data) {
            report["receiver"] = receiver
        }
        return report
    }

    static func viewer(status: String) -> [String: Any] {
        [
            "app": "Final Fusion Viewer", "version": AgentGuide.version,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "appPath": Bundle.main.bundleURL.path, "language": AppLanguage.code,
            "runsFromApplications": ViewerLocation.isInstalled,
            "accessibility": AXIsProcessTrusted(), "inputMonitoring": CGPreflightListenEventAccess(),
            "status": status,
            "quality": (UserDefaults.standard.object(forKey: "ReceiverResolution") as? Int)
                .flatMap(ReceiverResolution.init(rawValue:))?.title ?? "",
            "shareDiagnostics": !UserDefaults.standard.bool(forKey: "DisableReceiverDiagnostics"),
            "matchKeyboardLanguage": !UserDefaults.standard.bool(forKey: "KeepSenderInputSource")
        ]
    }

    /// Only known diagnostic fields leave the machine in the copied guide.
    /// Local CLI reports keep the full details for debugging on the user's own Mac.
    static func shareable(_ raw: [String: Any]) -> [String: Any] {
        func pick(_ from: [String: Any], _ keys: [String]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: keys.compactMap { key in from[key].map { (key, $0) } })
        }
        func numbers(_ from: [String: Any], _ keys: [String]) -> [String: Any] {
            pick(from, keys).filter { $0.value is NSNumber }
        }
        func list(_ from: [String: Any], _ key: String, _ keys: [String]) -> [[String: Any]]? {
            (from[key] as? [[String: Any]])?.prefix(8).map { numbers($0, keys) }
        }

        var clean = pick(raw, ["app", "version", "build", "macOS", "language", "relayConfigured",
                               "directConnection", "streamMode", "loginItem", "runsFromApplications",
                               "accessibility", "inputMonitoring", "quality", "shareDiagnostics", "matchKeyboardLanguage"])
        if let host = raw["host"] as? [String: Any] {
            clean["host"] = numbers(host, ["sharing", "updateRequested", "screenRecording", "accessibility"])
        }
        if let snapshot = raw["receiver"] as? [String: Any] {
            var details = numbers(snapshot, ["screenshotCopied", "acceptedInputCount"])
            if let version = snapshot["receiverAppVersion"] as? String, ReceiverUpdateVersion(version) != nil {
                details["receiverAppVersion"] = version
            }
            details["senderDisplays"] = list(snapshot, "senderDisplays", ["width", "height", "logicalWidth",
                "logicalHeight", "nativePixels", "clipboardScreenshots", "macInputMatching", "receiverUpdates"])
            details["senderStreams"] = list(snapshot, "senderStreams", ["targetFPS", "targetKbps", "reduced",
                "pendingVideoBytes", "baseVideoRoundTripMS", "videoQueueDelayMS", "encodeMS"])
            if let receiver = snapshot["receiver"] as? [String: Any] {
                var stats = numbers(receiver, ["seconds", "roundTripMS", "systemShortcuts", "sentInputCount"])
                if let route = receiver["connectionPath"] as? String, ConnectionPath(rawValue: route) != nil {
                    stats["connectionPath"] = route
                }
                stats["displays"] = list(receiver, "displays", ["localWidth", "localHeight", "visibleWidth", "visibleHeight",
                    "fillsScreen", "receivedFrames", "submittedFrames", "localCursorHidden", "scrollEvents",
                    "pinchEvents", "multiTouchEvents", "gestureShortcuts", "nativeGestureEvents"])
                details["receiver"] = stats
            }
            clean["receiver"] = details
        }
        return clean
    }

    static func text(_ report: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Viewer apps opened from the disk image or a quarantine (translocated) copy can't update themselves.
enum ViewerLocation {
    static var isInstalled: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let applications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return (path.hasPrefix("/Applications/") || path.hasPrefix(applications + "/")) && !path.contains("/AppTranslocation/")
    }

    static var needsMove: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") || path.contains("/Downloads/")
    }

    /// Copies the running viewer into /Applications (keeping its file name) and returns the new location.
    static func moveToApplications() throws -> URL {
        let fm = FileManager.default
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: destination.path) {
            let backup = fm.temporaryDirectory.appendingPathComponent("Studio Receiver backup " + UUID().uuidString.prefix(8) + ".app")
            try fm.moveItem(at: destination, to: backup)
        }
        try fm.copyItem(at: source, to: destination)
        return destination
    }
}
