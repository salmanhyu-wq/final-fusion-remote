import AppKit
import CoreServices
import CryptoKit
import MachO

enum ReceiverUpdatePhase: UInt32 {
    case version = 1, offer, chunk, complete, result, request

    static let checkOnlyGreeting: UInt8 = 2
}

struct ReceiverUpdateVersion: Comparable {
    let parts: [Int]

    init?(_ label: String) {
        guard label.utf8.count <= 23 else { return nil }
        let parts = label.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard parts.count == 3, parts.allSatisfy({ (0...999_999).contains($0) }),
              parts.map(String.init).joined(separator: ".") == label else { return nil }
        self.parts = parts
    }

    var label: String { parts.map(String.init).joined(separator: ".") }

    static var current: Self? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Self.init)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct ReceiverUpdateOffer: Codable {
    static let maxSize = 16 * 1024 * 1024
    static let chunkSize = 32 * 1024
    let version: String
    let size: Int
    let checksum: String

    init(version: ReceiverUpdateVersion, payload: Data) {
        self.version = version.label
        size = payload.count
        checksum = hex(Data(SHA256.hash(data: payload)))
    }

    func isNewer(than current: ReceiverUpdateVersion) -> Bool {
        guard let version = ReceiverUpdateVersion(version), version > current else { return false }
        return (1...Self.maxSize).contains(size) && strictHex(checksum, count: 32) != nil
    }

    func matches(_ payload: Data) -> Bool {
        payload.count == size && hex(Data(SHA256.hash(data: payload))) == checksum
    }

    func stage(_ payload: Data) throws -> URL {
        guard matches(payload), let version = ReceiverUpdateVersion(version) else {
            throw StudioError.message(L("받은 업데이트 파일을 확인하지 못했어요.", "Couldn't verify the received update file."))
        }
        try LocalSetup.prepare()
        let folder = LocalSetup.home.appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(ProductName.receiver + " " + version.label + ".dmg")
        try payload.write(to: file, options: .atomic)
        return file
    }

    static func package(_ profile: ReceiverProfile) throws -> Data {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("Studio-update-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let exported = try ReceiverExport.make(profile, in: temp)
        let image = exported.appendingPathComponent(ProductName.receiverImage)
        guard let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...maxSize).contains(size) else {
            throw StudioError.message(L("업데이트 파일이 너무 커서 보내지 못했어요.", "The update file is too large to send."))
        }
        return try Data(contentsOf: image)
    }
}

struct ReceiverUpdateDownload {
    let offer: ReceiverUpdateOffer
    private(set) var payload = Data()

    mutating func append(_ chunk: Data) -> Bool {
        guard (1...ReceiverUpdateOffer.chunkSize).contains(chunk.count),
              chunk.count <= offer.size - payload.count else { return false }
        payload.append(chunk)
        return true
    }
}

enum ReceiverUpdateInstallError: Error {
    case openInstaller
}

struct ReceiverUpdateInstall {
    let application: URL
    private let replacement: URL
    private let staging: URL

    func finish() { try? FileManager.default.removeItem(at: staging) }

    func refreshLaunchRegistration() {
        _ = LSRegisterURL(application as CFURL, true)
    }

    func rollBack() -> Bool {
        guard Self.swapContents(of: application, with: replacement) else { return false }
        refreshLaunchRegistration()
        finish()
        return true
    }

    static func swapContents(of application: URL, with replacement: URL) -> Bool {
        // Keep the app folder's file identity so Dock bookmarks still resolve.
        let installedContents = application.appendingPathComponent("Contents", isDirectory: true)
        let stagedContents = replacement.appendingPathComponent("Contents", isDirectory: true)
        return renamex_np(installedContents.path, stagedContents.path, UInt32(RENAME_SWAP)) == 0
    }

    static func prepare(_ image: URL, offer: ReceiverUpdateOffer) throws -> Self {
        let fm = FileManager.default
        let application = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parent = application.deletingLastPathComponent()
        let allowed = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)]
        guard let current = ReceiverUpdateVersion.current, offer.isNewer(than: current),
              let size = try image.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == offer.size,
              offer.matches(try Data(contentsOf: image)) else {
            throw StudioError.message(L("받은 업데이트 파일을 확인하지 못했어요.", "Couldn't verify the received update file."))
        }

        let mount = fm.temporaryDirectory.appendingPathComponent("Studio-mount-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: mount) }
        try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", mount.path]) }

        let candidate = mount.appendingPathComponent(ProductName.receiverBundle, isDirectory: true)
        guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "StudioReceiverOnly") as? Bool == true,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == offer.version,
              let config = bundle.url(forResource: "Receiver", withExtension: "json"),
              let size = try config.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...4096).contains(size),
              let profile = try? JSONDecoder().decode(ReceiverProfile.self, from: Data(contentsOf: config)),
              let currentProfile = ReceiverProfile.bundled(), profile == currentProfile else {
            throw StudioError.message(L("이 맥의 연결 정보와 맞는 받는 앱을 찾지 못했어요.", "Couldn't find a viewer app that matches this Mac's connection."))
        }
        #if arch(x86_64)
        let architecture = CPU_TYPE_X86_64
        #else
        let architecture = CPU_TYPE_ARM64
        #endif
        guard bundle.executableArchitectures?.contains(NSNumber(value: architecture)) == true else {
            throw StudioError.message(L("이 맥에서 실행할 수 있는 앱을 찾지 못했어요.", "Couldn't find an app that runs on this Mac."))
        }

        try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", candidate.path])
        guard application.pathExtension == "app",
              allowed.contains(where: { $0.resolvingSymlinksInPath().path == parent.path }),
              fm.isWritableFile(atPath: parent.path),
              let staging = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: application, create: true) else {
            throw ReceiverUpdateInstallError.openInstaller
        }
        let replacement = staging.appendingPathComponent(application.lastPathComponent, isDirectory: true)
        do {
            do { try fm.copyItem(at: candidate, to: replacement) }
            catch { throw ReceiverUpdateInstallError.openInstaller }
            try run("/usr/bin/codesign", ["--verify", "--strict", "--deep", replacement.path])
            if bundle.object(forInfoDictionaryKey: "StudioReceiverStartupCheck") as? Bool == true {
                guard let executable = Bundle(url: replacement)?.executableURL,
                      fm.isExecutableFile(atPath: executable.path) else {
                    throw StudioError.message(L("새 받는 앱을 열 수 없어요. 지금 앱은 계속 쓸 수 있어요.", "Couldn't open the new viewer app. You can keep using the current app."))
                }
                do { try run(executable.path, ["--verify-receiver-startup"]) }
                catch { throw StudioError.message(L("이 맥에서 새 받는 앱을 시작하지 못했어요. 지금 앱은 계속 쓸 수 있어요.", "Couldn't start the new viewer app on this Mac. You can keep using the current app.")) }
            }
            guard swapContents(of: application, with: replacement) else {
                throw ReceiverUpdateInstallError.openInstaller
            }
            return Self(application: application, replacement: replacement, staging: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func run(_ command: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StudioError.message(L("업데이트 설치 파일을 열지 못했어요.", "Couldn't open the update installer.")) }
    }
}
