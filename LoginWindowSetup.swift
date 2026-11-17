import AppKit
import CryptoKit

enum LoginWindowSetup {
    static let title = L("재시동 후 로그인 화면에서도 연결", "Connect to the login screen after restart")

    enum State: String { case off, current, reinstall }

    static var state: State? {
        runInstaller(["--status", Bundle.main.bundlePath]).flatMap(State.init(rawValue:))
    }

    static var fileVaultEnabled: Bool {
        run("/usr/bin/fdesetup", ["isactive"]) == "true"
    }

    static func missingRequirements(opensAtLogin: Bool) -> [String] {
        guard let result = runInstaller(["--check", Bundle.main.bundlePath]) else {
            return [L("설치 파일을 읽지 못했어요. 보내는 앱을 다시 설치해 주세요.",
                      "Couldn't read the setup files. Reinstall the host app.")]
        }
        var messages = result.split(separator: "\n").map { issue in
            switch issue {
            case "console":
                return L("이 맥에서 보내는 계정으로 로그인하고 앱을 열어 주세요.",
                         "Sign in to the host account on this Mac and open the app.")
            case "screen-sharing":
                return L("시스템 설정 → 일반 → 공유에서 ‘화면 공유’를 켜 주세요.",
                         "Turn on Screen Sharing in System Settings → General → Sharing.")
            case "screen-account":
                return L("시스템 설정 → 일반 → 공유 → 화면 공유에서 이 맥에 로그인할 계정을 허용해 주세요.",
                         "In System Settings → General → Sharing → Screen Sharing, allow the account you’ll sign in to on this Mac.")
            case "start-sharing":
                return L("이 앱에서 ‘보내기 시작’을 눌러 먼저 화면 보내기를 준비해 주세요.",
                         "Click “Start sharing” to set up sharing in this app first.")
            case "pair-viewer":
                return L("받는 앱으로 한 번 연결하고 이 앱에서 6자리 번호로 기기를 허용해 주세요.",
                         "Connect from a viewer once and allow it in this app with its six-digit code.")
            default:
                return L("설치 준비 상태를 확인하지 못했어요.", "Couldn't check whether setup is ready.")
            }
        }
        if !opensAtLogin {
            messages.append(L("이 앱에서 ‘로그인하면 자동으로 보내기 준비’를 켜 주세요. macOS가 묻는 경우 시스템 설정 → 일반 → 로그인 항목에서도 허용해 주세요.",
                              "Turn on “Get ready to share when I log in” in this app. If macOS asks, also allow it in System Settings → General → Login Items."))
        }
        return messages
    }

    enum Result: String { case done, cancelled, failed }

    static func change(install: Bool) -> Result {
        guard let script = installer else { return .failed }
        var args = ["-c", script, "install-login-window.sh"]
        if install {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StudioLink")
            guard let data = try? Data(contentsOf: helper, options: .mappedIfSafe) else { return .failed }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            args += [Bundle.main.bundlePath, digest, NSUserName()]
        } else {
            args += ["--remove", Bundle.main.bundlePath]
        }
        // Run the built-in script text, so a file can't be swapped during the password prompt.
        let authorize = """
        on run argv
            set commandText to "/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash"
            repeat with argument in argv
                set commandText to commandText & " " & quoted form of (contents of argument)
            end repeat
            try
                do shell script commandText with administrator privileges
                return "done"
            on error number errorNumber
                if errorNumber is -128 then return "cancelled"
                return "failed"
            end try
        end run
        """
        return run("/usr/bin/osascript", ["-e", authorize, "--"] + args).flatMap(Result.init(rawValue:)) ?? .failed
    }

    private static var installer: String? {
        Data(base64Encoded: loginWindowInstallerBase64).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func runInstaller(_ args: [String]) -> String? {
        guard let script = installer else { return nil }
        return run("/bin/bash", ["-c", script, "install-login-window.sh"] + args)
    }

    private static func run(_ executable: String, _ args: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
