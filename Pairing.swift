import AppKit
import CryptoKit
import Network
import Security

let configTrailer = Data("SR04CONF".utf8)

struct RelaySetup: Codable {
    let relay: String

    var valid: Bool {
        guard let url = URLComponents(string: relay), url.scheme == "https", let host = url.host,
              url.port == nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        let pattern = #"^[A-Za-z0-9]+(?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9]+(?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#
        return host.range(of: pattern, options: .regularExpression) != nil
    }
}

struct ReceiverProfile: Codable, Equatable {
    let relay: String
    let room: String
    let pin: String
    let invitation: String
    let macPin: String?
    var interactionV1: Bool? = nil

    var valid: Bool {
        RelaySetup(relay: relay).valid && strictHex(room, count: 32) != nil &&
        strictHex(pin, count: 32) != nil && strictHex(invitation, count: 16) != nil &&
        (macPin.map { strictHex($0, count: 32) != nil } ?? true)
    }

    static func bundled() -> ReceiverProfile? {
        guard let url = Bundle.main.url(forResource: "Receiver", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), bytes.count < 4096,
              let profile = try? JSONDecoder().decode(Self.self, from: bytes), profile.valid else { return nil }
        return profile
    }
}

func strictHex(_ input: String, count: Int) -> Data? {
    let bytes = Array(input.utf8)
    guard bytes.count == count * 2, bytes.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
    var out = Data(capacity: count)
    for index in stride(from: 0, to: bytes.count, by: 2) {
        guard let byte = UInt8(String(decoding: bytes[index...index+1], as: UTF8.self), radix: 16) else { return nil }
        out.append(byte)
    }
    return out
}

enum LocalSetup {
    static let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Final Fusion", isDirectory: true)
    private static var config: URL { home.appendingPathComponent("relay.json") }
    static let reportURL = home.appendingPathComponent("receiver-diagnostics.json")
    private static let directURL = home.appendingPathComponent("direct.txt")
    private static let streamModeURL = home.appendingPathComponent("stream-mode.txt")
    private static let receiverRequestURL = home.appendingPathComponent("receiver-resolution-request.json")

    static func receiverResolutionRequest() -> ReceiverResolutionRequest? {
        guard let data = try? Data(contentsOf: receiverRequestURL), data.count <= 1024 else { return nil }
        return try? JSONDecoder().decode(ReceiverResolutionRequest.self, from: data)
    }

    static func requestReceiverResolution(_ resolution: ReceiverResolution) throws -> Bool {
        let now = Date()
        guard let snapshot = readReport(), (0...15).contains(now.timeIntervalSince(snapshot.receivedAt)),
              let tuning = snapshot.receiver.tuning else {
            throw StudioError.message(L("지금 연결된 받는 앱의 연결 상태를 받지 못했어요.", "No connection info from the currently connected viewer."))
        }
        guard tuning.allowed else { throw StudioError.message(L("받는 앱에서 ‘보내는 맥이 화질을 바꿀 수 있게 허용’을 켜 주세요.", "Turn on “Let the host Mac change the quality” in the viewer app.")) }
        guard tuning.resolution != resolution else { return false }
        let request = ReceiverResolutionRequest(id: UUID(), session: tuning.session, resolution: resolution, issuedAt: now)
        try JSONEncoder().encode(request).write(to: receiverRequestURL, options: .atomic)
        return true
    }

    static func directEnabled() -> Bool {
        (try? String(contentsOf: directURL, encoding: .utf8)) == "on"
    }

    static func saveDirect(enabled: Bool) throws {
        try prepare()
        try Data((enabled ? "on" : "off").utf8).write(to: directURL, options: .atomic)
    }

    static func streamMode() -> StreamMode {
        guard let raw = try? String(contentsOf: streamModeURL, encoding: .utf8) else { return .auto }
        return StreamMode(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .auto
    }

    static func saveStreamMode(_ mode: StreamMode) throws {
        try prepare()
        try Data((mode.rawValue + "\n").utf8).write(to: streamModeURL, options: .atomic)
    }

    static func saveReport(_ snapshot: ReceiverDiagnosticsSnapshot) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: reportURL, options: .atomic)
    }

    static func readReport() -> ReceiverDiagnosticsSnapshot? {
        guard let data = try? Data(contentsOf: reportURL), data.count <= 16384 else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReceiverDiagnosticsSnapshot.self, from: data)
    }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    static func load() -> RelaySetup? {
        guard let data = try? Data(contentsOf: config),
              let setup = try? JSONDecoder().decode(RelaySetup.self, from: data), setup.valid else { return nil }
        return setup
    }

    static func save(_ setup: RelaySetup) throws {
        guard setup.valid else { throw StudioError.message(L("https://로 시작하는 연결 서버 주소를 확인하세요.", "Check the connection server address. It must start with https://.")) }
        try prepare()
        try JSONEncoder().encode(setup).write(to: config, options: .atomic)
    }

    static func deviceToken() throws -> Data {
        try prepare()
        let url = home.appendingPathComponent("device.key")
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else { throw StudioError.message(L("저장된 기기 정보를 읽을 수 없어요.", "Couldn't read the saved device info.")) }
            return data
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StudioError.message(L("기기 정보를 만들 수 없어요.", "Couldn't create the device info."))
        }
        let data = Data(bytes)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw StudioError.message(L("기기 정보를 저장할 수 없어요.", "Couldn't save the device info."))
        }
        return data
    }
}

func secureConnection(_ profile: ReceiverProfile, host: NWEndpoint.Host = "127.0.0.1",
                      port: NWEndpoint.Port) throws -> NWConnection {
    guard profile.valid, let pin = strictHex(profile.pin, count: 32) else {
        throw StudioError.message(L("연결 설정을 읽을 수 없어요.", "Couldn't read the connection settings."))
    }
    let macPin = profile.macPin.flatMap { strictHex($0, count: 32) }
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, nativePixelsProtocol)
    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, directProtocol)
    sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
        let ref = sec_trust_copy_ref(trust).takeRetainedValue()
        let certificate: SecCertificate?
        if #available(macOS 12.0, *) {
            certificate = (SecTrustCopyCertificateChain(ref) as? [SecCertificate])?.first
        } else {
            certificate = SecTrustGetCertificateAtIndex(ref, 0)
        }
        guard let certificate = certificate else { complete(false); return }
        let digest = Data(SHA256.hash(data: SecCertificateCopyData(certificate) as Data))
        complete(matches(pin, digest) || (macPin.map { matches($0, digest) } ?? false))
    }, DispatchQueue.global(qos: .userInitiated))
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    return NWConnection(host: host, port: port,
                        using: NWParameters(tls: tls, tcp: tcp))
}

final class HostLink {
    struct Event: Decodable {
        let event: String
        let profile: ReceiverProfile?
        let id: String?
        let code: String?
        let message: String?
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var stopped = false
    var onEvent: ((Event) -> Void)?
    var onEnd: (() -> Void)?

    func start(setup: RelaySetup, code: Data, localSocket: String) throws {
        try LocalSetup.prepare()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StudioLink")
        process.arguments = ["host", setup.relay, LocalSetup.home.path, localSocket]
        process.environment = ProcessInfo.processInfo.environment.merging([AppLanguage.environmentKey: AppLanguage.code]) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { [weak self] in self?.receive(bytes) }
        }
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data((hex(code) + "\n").utf8))
    }

    func respond(_ id: String, allow: Bool, code: String?) throws {
        struct Decision: Encodable { let id: String; let allow: Bool; let code: String? }
        var line = try JSONEncoder().encode(Decision(id: id, allow: allow, code: code))
        line.append(10)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    func stop() {
        stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty { onEnd?(); return }
        buffer.append(data)
        guard buffer.count < 64 * 1024 else { stop(); onEnd?(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let event = try? JSONDecoder().decode(Event.self, from: Data(line)) { onEvent?(event) }
        }
    }
}

enum ProductName {
    static let sender = L("파이널 퓨전", "Final Fusion")
    static let receiver = L("파이널 퓨전 받기", "Final Fusion Viewer")
    static let receiverImage = receiver + ".dmg"
    // Existing Mac receivers open this exact path inside the update disk image.
    static let receiverBundle = "Studio Receiver.app"
}

/// Writes ko.lproj and en.lproj InfoPlist.strings so Finder, the Dock and the menu bar
/// show the app name in the OS language.
enum LocalizedNames {
    static func write(in resources: URL, korean: String, english: String) throws {
        for (language, name) in [("ko", korean), ("en", english)] {
            let folder = resources.appendingPathComponent(language + ".lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let network = language == "ko" ? "허용된 기기끼리 화면을 연결해요." : "Connects the screen between allowed devices."
            let text = "\"CFBundleName\" = \"\(name)\";\n\"CFBundleDisplayName\" = \"\(name)\";\n"
                + "\"NSLocalNetworkUsageDescription\" = \"\(network)\";\n"
            try Data(text.utf8).write(to: folder.appendingPathComponent("InfoPlist.strings"))
        }
    }
}

enum ReceiverExport {
    /// Builds the Mac disk image and the Windows program. With a target only that device's file is kept
    /// and the read-me lists that device's first-run steps.
    static func make(_ profile: ReceiverProfile, in destination: URL, target: ViewerTarget? = nil) throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("StudioReceiver-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let output = temp.appendingPathComponent(ProductName.receiver, isDirectory: true)
        let mac = temp.appendingPathComponent("Mac", isDirectory: true)
        let app = mac.appendingPathComponent(ProductName.receiverBundle, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS", isDirectory: true)
        for directory in [output, resources, executable] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard let source = Bundle.main.executableURL,
              let icon = Bundle.main.url(forResource: "StudioRemote", withExtension: "icns"),
              let agent = Bundle.main.url(forResource: "receive-agent", withExtension: "txt"),
              let win = Bundle.main.url(forResource: "StudioReceiver", withExtension: "exe"),
              let original = Bundle.main.infoDictionary else {
            throw StudioError.message(L("받는 앱에 필요한 파일을 찾을 수 없어요.", "Couldn't find the files needed for the viewer app."))
        }
        try fm.copyItem(at: source, to: executable.appendingPathComponent("StudioRemote"))
        try fm.copyItem(at: icon, to: resources.appendingPathComponent("StudioRemote.icns"))
        try fm.copyItem(at: agent, to: resources.appendingPathComponent("receive-agent.txt"))
        for extra in ["receive-agent-en.txt", "MyMusicGacha.png"] {
            if let url = Bundle.main.resourceURL?.appendingPathComponent(extra), fm.fileExists(atPath: url.path) {
                try fm.copyItem(at: url, to: resources.appendingPathComponent(extra))
            }
        }
        try LocalizedNames.write(in: resources, korean: "파이널 퓨전 받기", english: "Final Fusion Viewer")
        let config = try JSONEncoder().encode(profile)
        try config.write(to: resources.appendingPathComponent("Receiver.json"))
        var info = original
        info["CFBundleIdentifier"] = "app.finalfusion.remote.receiver"
        info["CFBundleName"] = ProductName.receiver
        info["CFBundleDisplayName"] = ProductName.receiver
        info["StudioReceiverOnly"] = true
        info["StudioReceiverStartupCheck"] = true
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        // Sign the viewer with the host's fixed certificate so the viewer keeps its permissions across updates.
        let identity = original["FinalFusionSigningIdentity"] as? String ?? ""
        let signed = !identity.isEmpty && (try? run("/usr/bin/codesign", ["--force", "--sign", identity, app.path])) != nil
        if !signed { try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
        try run("/usr/bin/codesign", ["--verify", "--strict", app.path])

        let winApp = output.appendingPathComponent(ProductName.receiver + ".exe")
        try fm.copyItem(at: win, to: winApp)
        let file = try FileHandle(forWritingTo: winApp)
        do {
            _ = try file.seekToEnd()
            var payload = config
            payload.put(UInt32(config.count))
            payload.append(configTrailer)
            try file.write(contentsOf: payload)
            try file.close()
        } catch { try? file.close(); throw error }

        let instructions = target?.firstRun ?? L("""
        맥은 「\(ProductName.receiverImage)」 파일을 열어 안의 「Studio Receiver」를 응용 프로그램 폴더로 옮긴 뒤 여세요.
        Windows는 「\(ProductName.receiver).exe」 파일을 여세요. Windows 10·11 64비트와 Microsoft Edge 또는 Google Chrome이 필요해요.
        「연결하기」를 누른 뒤 처음에만 받는 앱에 나온 6자리 번호를 보내는 맥에 입력하고 「허용」을 누르세요.
        맥에서 원격 화면을 나가 설정으로 돌아오려면 \(ReceiverMode.exitKeys) 키를 누르세요.
        처음 열 때 보안 확인 창이 뜨면 안내에 따라 열기를 눌러 주세요.
        """, """
        Mac: open “\(ProductName.receiverImage)”, drag “Studio Receiver” into the Applications folder, and open it.
        Windows: open “\(ProductName.receiver).exe”. Requires 64-bit Windows 10 or 11 with Microsoft Edge or Google Chrome.
        Click “Connect”, then enter the 6-digit code shown in the viewer on the host Mac and click “Allow” (first time only).
        On a Mac, press \(ReceiverMode.exitKeys) to return to settings from the remote screen.
        If a security prompt appears the first time you open the app, follow the prompt to open it.
        """)
        let instructionsData = Data(instructions.utf8)
        try instructionsData.write(to: mac.appendingPathComponent(L("처음 읽기.txt", "Read Me First.txt")))
        try instructionsData.write(to: output.appendingPathComponent(L("처음 읽기.txt", "Read Me First.txt")))
        try fm.createSymbolicLink(at: mac.appendingPathComponent("Applications"),
                                  withDestinationURL: URL(fileURLWithPath: "/Applications", isDirectory: true))
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-fs", "HFS+", "-format", "UDRO",
                                    "-srcfolder", mac.path, "-volname", ProductName.receiver,
                                    output.appendingPathComponent(ProductName.receiverImage).path])
        if let target = target {
            try fm.removeItem(at: output.appendingPathComponent(target.isMac ? ProductName.receiver + ".exe" : ProductName.receiverImage))
        }
        let unique = ProductName.receiver + " " + UUID().uuidString.prefix(8)
        let result = destination.appendingPathComponent(unique, isDirectory: true)
        try fm.moveItem(at: output, to: result)
        return result
    }

    private static func run(_ command: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StudioError.message(L("받는 앱 파일을 만들 수 없어요.", "Couldn't create the viewer app files.")) }
    }
}
