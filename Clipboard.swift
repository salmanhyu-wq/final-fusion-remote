import AppKit
import Darwin

/// What one copy carries from one Mac's clipboard to the other: a JSON header, then each part's bytes in order.
struct ParcelHeader: Codable {
    struct Part: Codable {
        /// "text", "rtf", "html", "png" or "file".
        let type: String
        let size: Int
        var name: String?
    }
    let parts: [Part]
    var screenshot: Bool? = nil

    var isScreenshot: Bool {
        screenshot == true && parts.count == 1 && parts[0].type == "png" && parts[0].size > 0
    }
}

/// The first byte of every parcel message. The message's screen field is the parcel's number.
enum ParcelPhase: UInt8 {
    case begin = 1, chunk, end, cancel
    /// The sender's newest copy cannot travel (a folder, or files over the limit).
    case skipped
}

/// Shares one Mac's clipboard with the other side of a session: text, pictures and copied files, in both directions.
/// Call from the main queue. Pasteboard providers and disk I/O run on a private serial queue
/// because either can block for seconds (for example when a cloud provider fetches a file).
final class ClipboardShare {
    static let chunkSize = 30_000
    static let maxText = 4 * 1024 * 1024
    static let maxImage = 32 * 1024 * 1024
    static let maxFiles = 200 * 1024 * 1024
    static let maxFileCount = 64
    private static let maxStoredFiles = 512
    private static let maxStoredBytes = 2 * maxFiles
    static let screenshotMarker = NSPasteboard.PasteboardType("app.finalfusion.remote-screenshot")
    private static let maxQueuedBytes = 4 * 1024 * 1024
    private static let fileChunksPerTick = 2
    private static let textTypes: [(name: String, type: NSPasteboard.PasteboardType)] =
        [("text", .string), ("rtf", .rtf), ("html", .html)]
    /// Password managers mark what should not leave the Mac.
    private static let privateTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                       "com.agilebits.onepassword"]

    enum Activity: Equatable {
        case sending(files: Int, progress: Double)
        case sent(files: Int)
        case receiving(files: Int, progress: Double)
        case received(files: Int)
        case screenshotReceived
        case skipped
        case interrupted
    }

    private enum Source {
        case data(Data)
        case file(URL, Int)
        var size: Int {
            switch self {
            case let .data(data): return data.count
            case let .file(_, size): return size
            }
        }
    }

    private enum Copy {
        case ignored, unsupported
        case parcel(ParcelHeader, [Source])
    }

    private final class Outgoing {
        let id: UInt32
        let header: Data
        let sources: [Source]
        let files: Int
        let total: Int
        var began = false
        var index = 0
        var offset = 0
        var sent = 0
        var percent = 0
        var handle: FileHandle?
        var held: Data?

        init(id: UInt32, header: Data, sources: [Source], files: Int) {
            self.id = id
            self.header = header
            self.sources = sources
            self.files = files
            total = sources.reduce(0) { $0 + $1.size }
        }
    }

    private final class Incoming {
        let id: UInt32
        let parts: [ParcelHeader.Part]
        let names: [String?]
        let isScreenshot: Bool
        let files: Int
        let total: Int
        var index = 0
        var filled = 0
        var received = 0
        var percent = 0
        var buffers: [Data]
        var directory: URL?
        var reservation: FileHandle?
        var handle: FileHandle?
        var urls: [URL] = []

        init(id: UInt32, header: ParcelHeader, names: [String?]) {
            self.id = id
            parts = header.parts
            self.names = names
            isScreenshot = header.isScreenshot
            files = names.compactMap { $0 }.count
            total = parts.reduce(0) { $0 + $1.size }
            buffers = Array(repeating: Data(), count: parts.count)
        }
    }

    private let pasteboard: NSPasteboard
    private let folder: URL
    private let send: (UInt32, Data) -> Bool
    private let hasRoom: () -> Bool
    private let readFileSize: (URL) -> Int?
    private let worker = DispatchQueue(label: "final-fusion.clipboard", qos: .utility)
    var onActivity: ((Activity) -> Void)?

    // Main-queue admission control keeps a stalled disk from accumulating the whole transfer in RAM.
    private var active: DispatchWorkItem?
    private var queuedBytes = 0
    private var dropping = false

    // Everything below is owned by the worker.
    private var timer: DispatchSourceTimer?
    private var ticks = 0
    private var seenChange = 0
    private var nextID: UInt32 = 1
    private var outgoing: Outgoing?
    private var incoming: Incoming?
    private var keptDirectory: URL?

    /// `folder` holds files that arrive, until the next files arrive.
    init(pasteboard: NSPasteboard = .general, folder: URL,
         send: @escaping (UInt32, Data) -> Bool, hasRoom: @escaping () -> Bool,
         readFileSize: @escaping (URL) -> Int? = ClipboardShare.fileSize) {
        self.pasteboard = pasteboard
        self.folder = folder
        self.send = send
        self.hasRoom = hasRoom
        self.readFileSize = readFileSize
    }

    static var defaultFolder: URL { LocalSetup.home.appendingPathComponent("clipboard-files", isDirectory: true) }

    /// Files from sessions that ended more than a day ago are no longer needed for a paste.
    static func removeOldFiles(in folder: URL = defaultFolder) {
        guard let reservation = lockFiles(in: folder, create: false) else { return }
        defer { try? reservation.close() }
        removeExpiredParcels(in: folder)
    }

    private static func removeExpiredParcels(in folder: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        for item in items where UUID(uuidString: item.lastPathComponent) != nil {
            let modified = (try? item.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > 86_400 { try? FileManager.default.removeItem(at: item) }
        }
    }

    private static func lockFiles(in folder: URL, create: Bool) -> FileHandle? {
        if create {
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                            attributes: [.posixPermissions: 0o700])) != nil else { return nil }
        }
        let path = folder.appendingPathComponent(".receive.lock")
        let fd = path.withUnsafeFileSystemRepresentation { raw in
            raw.map { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600) } ?? -1
        }
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func reserveFiles(in folder: URL, bytes: Int, files: Int, keeping: Set<String>) -> FileHandle? {
        guard let reservation = lockFiles(in: folder, create: true) else { return nil }
        removeExpiredParcels(in: folder)
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var totalBytes = Int64(bytes)
        var totalFiles = files
        var removable: [(url: URL, modified: Date, bytes: Int64, files: Int)] = []
        guard let parcels = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys)) else { return nil }
        for parcel in parcels where UUID(uuidString: parcel.lastPathComponent) != nil {
            guard let attributes = try? parcel.resourceValues(forKeys: keys), attributes.isSymbolicLink == false,
                  attributes.isDirectory == true,
                  let items = try? fm.contentsOfDirectory(at: parcel, includingPropertiesForKeys: Array(keys)) else { return nil }
            var parcelBytes: Int64 = 0
            for item in items {
                guard let attributes = try? item.resourceValues(forKeys: keys),
                      attributes.isRegularFile == true, attributes.isSymbolicLink == false,
                      let size = attributes.fileSize, size >= 0 else { return nil }
                parcelBytes += Int64(size)
            }
            totalBytes += parcelBytes
            totalFiles += items.count
            if !keeping.contains(parcel.standardizedFileURL.path) {
                removable.append((parcel, attributes.contentModificationDate ?? .distantPast, parcelBytes, items.count))
            }
        }
        for old in removable.sorted(by: { $0.modified < $1.modified }) {
            if totalBytes <= maxStoredBytes && totalFiles <= maxStoredFiles { break }
            guard (try? fm.removeItem(at: old.url)) != nil else { continue }
            totalBytes -= old.bytes
            totalFiles -= old.files
        }
        return totalBytes <= maxStoredBytes && totalFiles <= maxStoredFiles ? reservation : nil
    }

    private func pastedParcels() -> Set<String> {
        Set((pasteboard.pasteboardItems ?? []).compactMap {
            guard $0.types.contains(.fileURL), let path = $0.string(forType: .fileURL),
                  let url = URL(string: path), url.isFileURL else { return nil }
            return url.deletingLastPathComponent().standardizedFileURL.path
        })
    }

    /// Only what is copied after this point is shared.
    func start() {
        guard active == nil else { return }
        let run = DispatchWorkItem {}
        active = run
        let baseline = pasteboard.changeCount
        worker.async { [self] in
            guard !run.isCancelled else { return }
            seenChange = baseline
            ticks = 0
            let timer = DispatchSource.makeTimerSource(queue: worker)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick(run) }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        guard let run = active else { return }
        run.cancel()
        active = nil
        dropping = false
        worker.async { [self] in
            timer?.cancel()
            timer = nil
            finishOutgoing()
            discardIncoming()
        }
    }

    private func report(_ activity: Activity, run: DispatchWorkItem) {
        DispatchQueue.main.async { [weak self] in
            guard !run.isCancelled else { return }
            self?.onActivity?(activity)
        }
    }

    private func tick(_ run: DispatchWorkItem) {
        guard !run.isCancelled else { return }
        ticks += 1
        if ticks % 8 == 0 { checkPasteboard(run) }
        pump(run)
    }

    // MARK: Sending

    private func checkPasteboard(_ run: DispatchWorkItem) {
        let change = pasteboard.changeCount
        guard change != seenChange else { return }
        seenChange = change
        // A newer copy replaces one that is still on its way.
        if let previous = outgoing {
            if previous.began { _ = send(previous.id, Data([ParcelPhase.cancel.rawValue])) }
            finishOutgoing()
        }
        let copy = readPasteboard()
        guard !run.isCancelled, pasteboard.changeCount == change else { return }
        switch copy {
        case .ignored:
            break
        case .unsupported:
            _ = send(nextID, Data([ParcelPhase.skipped.rawValue]))
            nextID &+= 1
            report(.skipped, run: run)
        case let .parcel(copy, sources):
            guard let header = try? JSONEncoder().encode(copy), header.count <= Self.chunkSize else { return }
            let files = copy.parts.filter { $0.type == "file" }.count
            outgoing = Outgoing(id: nextID, header: header, sources: sources, files: files)
            nextID &+= 1
            if files > 0 { report(.sending(files: files, progress: 0), run: run) }
        }
    }

    private func readPasteboard() -> Copy {
        let types = pasteboard.types ?? []
        guard !types.contains(where: { Self.privateTypes.contains($0.rawValue) }) else { return .ignored }
        // Read only explicitly declared file references. The URL reader can also convert other
        // representations; copying a pathname as text must never cause file access or a transfer.
        if types.contains(.fileURL) {
            let items = (pasteboard.pasteboardItems ?? []).filter { $0.types.contains(.fileURL) }
            guard (1...Self.maxFileCount).contains(items.count) else { return .unsupported }
            var parts: [ParcelHeader.Part] = []
            var sources: [Source] = []
            var total = 0
            for item in items {
                guard let address = item.string(forType: .fileURL), let url = URL(string: address),
                      url.isFileURL, url.path.hasPrefix("/"), !url.hasDirectoryPath,
                      url.host.map({ $0.isEmpty || $0.lowercased() == "localhost" }) ?? true,
                      let size = readFileSize(url), size >= 0, size <= Self.maxFiles - total else {
                    return .unsupported
                }
                total += size
                parts.append(.init(type: "file", size: size, name: url.lastPathComponent))
                sources.append(.file(url, size))
            }
            return .parcel(ParcelHeader(parts: parts), sources)
        }
        var parts: [ParcelHeader.Part] = []
        var sources: [Source] = []
        for (name, type) in Self.textTypes where types.contains(type) {
            let data = type == .string ? pasteboard.string(forType: type).map { Data($0.utf8) } : pasteboard.data(forType: type)
            guard let data = data, !data.isEmpty, data.count <= Self.maxText else { continue }
            parts.append(.init(type: name, size: data.count))
            sources.append(.data(data))
        }
        let png = types.contains(.png) ? pasteboard.data(forType: .png) : nil
        let tiff = png == nil && types.contains(.tiff) ? pasteboard.data(forType: .tiff) : nil
        if let image = png ?? tiff.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
           !image.isEmpty, image.count <= Self.maxImage {
            parts.append(.init(type: "png", size: image.count))
            sources.append(.data(image))
        }
        guard !parts.isEmpty else { return .ignored }
        let screenshot = types.contains(Self.screenshotMarker) && parts.map(\.type) == ["png"]
        return .parcel(ParcelHeader(parts: parts, screenshot: screenshot ? true : nil), sources)
    }

    static func fileSize(_ url: URL) -> Int? {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        return values?.isRegularFile == true ? values?.fileSize : nil
    }

    private static func openFile(_ url: URL, expectedSize: Int) -> FileHandle? {
        // Recheck the opened file: the copied path could have been replaced by a link or FIFO.
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size == expectedSize else {
            close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Sends a little at a time and only while the connection has room, so the picture keeps its share.
    private func pump(_ run: DispatchWorkItem) {
        guard let parcel = outgoing else { return }
        var fileChunks = 0
        for _ in 0..<12 {
            guard !run.isCancelled, hasRoom() else { return }
            if !parcel.began {
                guard send(parcel.id, Data([ParcelPhase.begin.rawValue]) + parcel.header) else { return }
                parcel.began = true
                continue
            }
            guard parcel.index < parcel.sources.count else {
                guard send(parcel.id, Data([ParcelPhase.end.rawValue])) else { return }
                finishOutgoing()
                if parcel.files > 0 { report(.sent(files: parcel.files), run: run) }
                return
            }
            let source = parcel.sources[parcel.index]
            if parcel.offset >= source.size {
                try? parcel.handle?.close()
                parcel.handle = nil
                parcel.index += 1
                parcel.offset = 0
                continue
            }
            let wanted = min(Self.chunkSize, source.size - parcel.offset)
            let chunk: Data
            if let held = parcel.held {
                chunk = held
            } else {
                switch source {
                case let .data(data):
                    chunk = data.subdata(in: parcel.offset..<parcel.offset + wanted)
                case let .file(url, size):
                    if parcel.handle == nil { parcel.handle = Self.openFile(url, expectedSize: size) }
                    // A file that changed or vanished after it was copied ends the parcel.
                    guard let data = try? parcel.handle?.read(upToCount: wanted), data.count == wanted else {
                        if !run.isCancelled { _ = send(parcel.id, Data([ParcelPhase.cancel.rawValue])) }
                        finishOutgoing()
                        report(.interrupted, run: run)
                        return
                    }
                    chunk = data
                }
            }
            guard !run.isCancelled else { return }
            guard send(parcel.id, Data([ParcelPhase.chunk.rawValue]) + chunk) else {
                parcel.held = chunk
                return
            }
            parcel.held = nil
            parcel.offset += chunk.count
            parcel.sent += chunk.count
            if parcel.files > 0 {
                let percent = parcel.sent * 100 / parcel.total
                if percent != parcel.percent {
                    parcel.percent = percent
                    report(.sending(files: parcel.files, progress: Double(parcel.sent) / Double(parcel.total)), run: run)
                }
                // The socket's pending count cannot see buffers in the relay or on the peer.
                // Cap file bursts as well, leaving space for control and picture traffic.
                fileChunks += 1
                if fileChunks >= Self.fileChunksPerTick { return }
            }
        }
    }

    private func finishOutgoing() {
        try? outgoing?.handle?.close()
        outgoing = nil
    }

    // MARK: Receiving

    func receive(id: UInt32, data: Data) {
        guard let run = active, let first = data.first, let phase = ParcelPhase(rawValue: first) else { return }
        if dropping && phase != .begin { return }
        let cost = max(4096, data.count)
        guard cost <= Self.maxQueuedBytes - queuedBytes else {
            if !dropping {
                dropping = true
                worker.async { [self] in
                    guard !run.isCancelled else { return }
                    discardIncoming()
                    report(.interrupted, run: run)
                }
            }
            return
        }
        dropping = false
        queuedBytes += cost
        worker.async { [self] in
            if !run.isCancelled { receiveParcel(id: id, phase: phase, body: data.dropFirst(), run: run) }
            DispatchQueue.main.async { [weak self] in self?.queuedBytes -= cost }
        }
    }

    private func receiveParcel(id: UInt32, phase: ParcelPhase, body: Data, run: DispatchWorkItem) {
        switch phase {
        case .begin:
            discardIncoming()
            guard let header = try? JSONDecoder().decode(ParcelHeader.self, from: Data(body)),
                  let names = Self.acceptedNames(header.parts) else { return }
            let parcel = Incoming(id: id, header: header, names: names)
            if parcel.files > 0 {
                guard let reservation = Self.reserveFiles(in: folder, bytes: parcel.total, files: parcel.files,
                                                          keeping: pastedParcels()) else {
                    report(.interrupted, run: run)
                    return
                }
                parcel.reservation = reservation
                let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])) != nil else { return }
                parcel.directory = directory
                report(.receiving(files: parcel.files, progress: 0), run: run)
            }
            incoming = parcel
            if !advance(parcel) { discardIncoming() }
        case .chunk:
            guard let parcel = incoming, parcel.id == id else { return }
            var rest = Data(body)
            while !rest.isEmpty {
                guard parcel.index < parcel.parts.count else { discardIncoming(); return }
                let take = min(rest.count, parcel.parts[parcel.index].size - parcel.filled)
                let piece = rest.prefix(take)
                if parcel.names[parcel.index] != nil {
                    guard let handle = parcel.handle, (try? handle.write(contentsOf: piece)) != nil else { discardIncoming(); return }
                } else {
                    parcel.buffers[parcel.index].append(piece)
                }
                parcel.filled += take
                parcel.received += take
                rest = rest.dropFirst(take)
                guard advance(parcel) else { discardIncoming(); return }
            }
            if parcel.files > 0, parcel.total > 0 {
                let percent = parcel.received * 100 / parcel.total
                if percent != parcel.percent {
                    parcel.percent = percent
                    report(.receiving(files: parcel.files, progress: Double(parcel.received) / Double(parcel.total)), run: run)
                }
            }
        case .end:
            guard let parcel = incoming, parcel.id == id else { return }
            guard parcel.index == parcel.parts.count, !run.isCancelled else { discardIncoming(); return }
            incoming = nil
            apply(parcel, run: run)
        case .cancel:
            if incoming?.id == id {
                let hadFiles = (incoming?.files ?? 0) > 0
                discardIncoming()
                if hadFiles { report(.interrupted, run: run) }
            }
        case .skipped:
            report(.skipped, run: run)
        }
    }

    /// File names are reduced to a plain name inside the receiving folder; anything else in the header refuses the parcel.
    private static func acceptedNames(_ parts: [ParcelHeader.Part]) -> [String?]? {
        guard (1...maxFileCount).contains(parts.count) else { return nil }
        var names: [String?] = []
        var used = Set<String>()
        var fileBytes = 0
        var kinds = Set<String>()
        for part in parts {
            guard part.size >= 0 else { return nil }
            switch part.type {
            case "text", "rtf", "html":
                guard part.size <= maxText, kinds.insert(part.type).inserted else { return nil }
                names.append(nil)
            case "png":
                guard part.size <= maxImage, kinds.insert(part.type).inserted else { return nil }
                names.append(nil)
            case "file":
                guard part.size <= maxFiles - fileBytes else { return nil }
                fileBytes += part.size
                var name = ((part.name ?? "") as NSString).lastPathComponent
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
                if name.isEmpty || name == "." || name == ".." || name.utf8.count > 240 { name = "file" }
                var unique = name
                var copy = 2
                while !used.insert(unique.lowercased()).inserted {
                    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                    unique = ext.isEmpty ? "\(base) \(copy)" : "\(base) \(copy).\(ext)"
                    copy += 1
                }
                names.append(unique)
            default: return nil
            }
        }
        // Copied files travel alone; everything else is one clipboard item.
        let files = names.compactMap { $0 }.count
        return files == 0 || files == parts.count ? names : nil
    }

    /// Closes every part that is complete, including empty ones, and opens the next file.
    private func advance(_ parcel: Incoming) -> Bool {
        while parcel.index < parcel.parts.count {
            if let name = parcel.names[parcel.index], parcel.handle == nil {
                guard let url = parcel.directory?.appendingPathComponent(name),
                      FileManager.default.createFile(atPath: url.path, contents: nil),
                      let handle = try? FileHandle(forWritingTo: url) else { return false }
                parcel.handle = handle
                parcel.urls.append(url)
            }
            guard parcel.filled == parcel.parts[parcel.index].size else { return true }
            try? parcel.handle?.close()
            parcel.handle = nil
            parcel.index += 1
            parcel.filled = 0
        }
        return true
    }

    private func apply(_ parcel: Incoming, run: DispatchWorkItem) {
        if !parcel.urls.isEmpty {
            if run.isCancelled {
                if let directory = parcel.directory { try? FileManager.default.removeItem(at: directory) }
                return
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(parcel.urls as [NSURL]) else {
                if let directory = parcel.directory { try? FileManager.default.removeItem(at: directory) }
                report(.interrupted, run: run)
                return
            }
            seenChange = pasteboard.changeCount
            if let previous = keptDirectory { try? FileManager.default.removeItem(at: previous) }
            keptDirectory = parcel.directory
            report(.received(files: parcel.urls.count), run: run)
        } else {
            let item = NSPasteboardItem()
            for (index, part) in parcel.parts.enumerated() {
                let data = parcel.buffers[index]
                switch part.type {
                case "text": item.setString(String(decoding: data, as: UTF8.self), forType: .string)
                case "rtf": item.setData(data, forType: .rtf)
                case "html": item.setData(data, forType: .html)
                case "png":
                    let bitmap = NSBitmapImageRep(data: data)
                    if parcel.isScreenshot && bitmap == nil { return }
                    item.setData(data, forType: .png)
                    if let tiff = bitmap?.tiffRepresentation(using: .lzw, factor: 1) {
                        item.setData(tiff, forType: .tiff)
                    }
                default: break
                }
            }
            guard !item.types.isEmpty, !run.isCancelled else { return }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { return }
            // What just arrived must not travel back.
            seenChange = pasteboard.changeCount
            if parcel.isScreenshot { report(.screenshotReceived, run: run) }
        }
    }

    private func discardIncoming() {
        guard let parcel = incoming else { return }
        incoming = nil
        try? parcel.handle?.close()
        if let directory = parcel.directory { try? FileManager.default.removeItem(at: directory) }
    }
}
