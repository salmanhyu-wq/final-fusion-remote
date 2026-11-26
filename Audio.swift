import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia

/// Host system sound travels as raw Opus packets of 20 ms, 48 kHz stereo. The message's screen field is a running
/// packet number. Opus adds only a few milliseconds of its own, which keeps sound close to the picture.
enum SessionAudio {
    static let sampleRate = 48_000.0
    static let channels = 2
    static let bitRate = 128_000
    static let packetFrames = 960
    static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels), interleaved: false)!
    static let packets: AVAudioFormat = {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(packetFrames), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)!
    }()
}

/// Not thread-safe; use from one queue.
final class AudioEncoder {
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private var pending: [AVAudioPCMBuffer] = []

    func encode(_ sample: CMSampleBuffer) -> [Data] {
        guard let description = sample.formatDescription?.audioStreamBasicDescription,
              description.mFormatID == kAudioFormatLinearPCM else { return [] }
        var stream = description
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let format = AVAudioFormat(streamDescription: &stream),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return [] }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr else { return [] }
        return encode(buffer)
    }

    func encode(_ buffer: AVAudioPCMBuffer) -> [Data] {
        if converter == nil || source != buffer.format {
            guard let next = AVAudioConverter(from: buffer.format, to: SessionAudio.packets) else { return [] }
            next.bitRate = SessionAudio.bitRate
            converter = next
            source = buffer.format
            pending.removeAll()
        }
        guard let converter = converter else { return [] }
        pending.append(buffer)
        var packets: [Data] = []
        while true {
            let output = AVAudioCompressedBuffer(format: SessionAudio.packets, packetCapacity: 8,
                                                 maximumPacketSize: max(1_500, converter.maximumOutputPacketSize))
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, state in
                if pending.isEmpty {
                    state.pointee = .noDataNow
                    return nil
                }
                state.pointee = .haveData
                return pending.removeFirst()
            }
            guard error == nil, let descriptions = output.packetDescriptions else { break }
            for index in 0..<Int(output.packetCount) {
                let packet = descriptions[index]
                packets.append(Data(bytes: output.data + Int(packet.mStartOffset), count: Int(packet.mDataByteSize)))
            }
            if status != .haveData || output.packetCount == 0 { break }
        }
        return packets
    }
}

/// Not thread-safe; use from one queue. Packets must arrive in order.
final class AudioDecoder {
    private let converter = AVAudioConverter(from: SessionAudio.packets, to: SessionAudio.pcm)

    /// False on a Mac whose system cannot decode the packets; such a viewer does not ask for sound.
    var isAvailable: Bool { converter != nil }

    func reset() { converter?.reset() }

    func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        guard let converter = converter, (1...8192).contains(packet.count),
              let output = AVAudioPCMBuffer(pcmFormat: SessionAudio.pcm, frameCapacity: 4096) else { return nil }
        let input = AVAudioCompressedBuffer(format: SessionAudio.packets, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(packet.count))
        var consumed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, state in
            if consumed {
                state.pointee = .noDataNow
                return nil
            }
            consumed = true
            state.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// Plays the host's sound on the viewer close to the picture. Sound waits in a short cushion (40 ms, more after the
/// network stutters) and anything that would play over 80 ms behind the cushion is dropped instead of drifting late.
final class AudioPlayer {
    private static let cushionFrames = Int(SessionAudio.sampleRate * 0.04)
    private static let maxCushionFrames = Int(SessionAudio.sampleRate * 0.10)
    private static let lateFrames = Int(SessionAudio.sampleRate * 0.08)
    private static let bufferFrames = 4096
    private static let bytesPerFrame = SessionAudio.channels * MemoryLayout<Float>.stride
    private static let callbackQueue = DispatchQueue(label: "studio-remote.audio-output")
    static var isAvailable: Bool { AudioDecoder().isAvailable }

    private let queue = DispatchQueue(label: "studio-remote.audio-play", qos: .userInteractive)
    private let admission = NSLock()
    private var queuedPackets = 0
    private var acceptingPackets = true
    private let decoder = AudioDecoder()
    private let onDecoded: ((AVAudioPCMBuffer) -> Void)?
    private var output: AudioQueueRef?
    private var outputGeneration: UInt64 = 0
    private var outputStarted = false
    private var availableBuffers: [AudioQueueBufferRef] = []
    private var scheduledBuffers: [AudioQueueBufferRef: Int] = [:]
    private var queuedFrames = 0
    private var lastOutputProgress = DispatchTime.now()
    private var nextOutputAttempt = DispatchTime(uptimeNanoseconds: 0)
    private var cushion = AudioPlayer.cushionFrames
    private var played = false
    private var expected: UInt32?

    /// A test passes onDecoded to receive the sound instead of playing it.
    init(onDecoded: ((AVAudioPCMBuffer) -> Void)? = nil) {
        self.onDecoded = onDecoded
    }

    deinit {
        if let output { AudioQueueDispose(output, true) }
    }

    func receive(_ packet: Data, number: UInt32) {
        guard (1...8192).contains(packet.count) else { return }
        admission.lock()
        guard acceptingPackets, queuedPackets < 12 else { admission.unlock(); return }
        queuedPackets += 1
        admission.unlock()
        queue.async { [self] in
            defer {
                admission.lock()
                queuedPackets -= 1
                admission.unlock()
            }
            admission.lock()
            let accepting = acceptingPackets
            admission.unlock()
            guard accepting else { return }
            // The host restarts numbering with a fresh encoder.
            if let expected = expected, number != expected { decoder.reset() }
            expected = number &+ 1
            guard let buffer = decoder.decode(packet) else { return }
            if let onDecoded {
                onDecoded(buffer)
            } else {
                play(buffer)
            }
        }
    }

    func stop() {
        admission.lock()
        let wasAccepting = acceptingPackets
        acceptingPackets = false
        admission.unlock()
        guard wasAccepting else { return }
        queue.async { [self] in tearDown() }
    }

    private func play(_ buffer: AVAudioPCMBuffer) {
        let now = DispatchTime.now()
        // An output device can disappear without draining its last buffers.
        if queuedFrames > 0 && now >= lastOutputProgress + .milliseconds(500) {
            tearDown()
        }
        guard now >= nextOutputAttempt else { return }
        let frames = Int(buffer.frameLength)
        guard (1...Self.bufferFrames).contains(frames), let channels = buffer.floatChannelData else { return }
        if output == nil && !makeOutput() {
            outputFailed()
            return
        }
        guard let output else { return }
        guard queuedFrames <= cushion + Self.lateFrames else { return }
        if queuedFrames == 0 {
            lastOutputProgress = now
            if played { cushion = min(Self.maxCushionFrames, cushion + SessionAudio.packetFrames) }
            guard enqueue(on: output, frames: cushion, channels: nil) else { outputFailed(); return }
        }
        guard !availableBuffers.isEmpty else { return }
        guard enqueue(on: output, frames: frames, channels: channels) else { outputFailed(); return }
        if !outputStarted {
            guard AudioQueueStart(output, nil) == noErr else { outputFailed(); return }
            outputStarted = true
            played = true
        }
    }

    private func makeOutput() -> Bool {
        var format = AudioStreamBasicDescription(
            mSampleRate: SessionAudio.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(Self.bytesPerFrame), mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.bytesPerFrame), mChannelsPerFrame: UInt32(SessionAudio.channels),
            mBitsPerChannel: 32, mReserved: 0)
        let generation = outputGeneration
        let playbackQueue = queue
        var newOutput: AudioQueueRef?
        // Keep completion delivery separate so disposing on the playback queue cannot wait on itself.
        let status = AudioQueueNewOutputWithDispatchQueue(&newOutput, &format, 0, Self.callbackQueue) { [weak self] _, buffer in
            playbackQueue.async { [weak self] in
                guard let self, self.outputGeneration == generation,
                      let frames = self.scheduledBuffers.removeValue(forKey: buffer) else { return }
                self.queuedFrames -= frames
                self.availableBuffers.append(buffer)
                self.lastOutputProgress = .now()
            }
        }
        guard status == noErr, let newOutput else { return false }
        output = newOutput
        for _ in 0..<8 {
            var buffer: AudioQueueBufferRef?
            let capacity = UInt32(max(Self.bufferFrames, Self.maxCushionFrames) * Self.bytesPerFrame)
            guard AudioQueueAllocateBuffer(newOutput, capacity, &buffer) == noErr, let buffer else { return false }
            availableBuffers.append(buffer)
        }
        return true
    }

    private func enqueue(on output: AudioQueueRef, frames: Int, channels: UnsafePointer<UnsafeMutablePointer<Float>>?) -> Bool {
        guard let buffer = availableBuffers.popLast() else { return false }
        let destination = buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self)
        if let channels {
            for frame in 0..<frames {
                destination[2 * frame] = channels[0][frame]
                destination[2 * frame + 1] = channels[1][frame]
            }
        } else {
            destination.initialize(repeating: 0, count: frames * SessionAudio.channels)
        }
        buffer.pointee.mAudioDataByteSize = UInt32(frames * Self.bytesPerFrame)
        guard AudioQueueEnqueueBuffer(output, buffer, 0, nil) == noErr else { return false }
        queuedFrames += frames
        scheduledBuffers[buffer] = frames
        return true
    }

    private func outputFailed() {
        tearDown()
        nextOutputAttempt = .now() + .seconds(1)
    }

    private func tearDown() {
        outputGeneration &+= 1
        if let output { AudioQueueDispose(output, true) }
        output = nil
        outputStarted = false
        availableBuffers.removeAll()
        scheduledBuffers.removeAll()
        queuedFrames = 0
        cushion = Self.cushionFrames
        played = false
    }
}

/// Silences this Mac's speakers while a viewer listens to it, and puts them back afterwards, also after a crash.
final class HostSpeakerMute {
    private struct Change: Codable {
        let device: String
        let ownerPID: Int32
    }

    private static var journal: URL { LocalSetup.home.appendingPathComponent("sound-mute-session.json") }
    private var change: Change?

    static func recover() {
        guard let raw = try? Data(contentsOf: journal), raw.count <= 1024,
              let previous = try? JSONDecoder().decode(Change.self, from: raw), previous.ownerPID > 1 else { return }
        if previous.ownerPID != ProcessInfo.processInfo.processIdentifier {
            guard kill(previous.ownerPID, 0) == -1, errno == ESRCH else { return }
        }
        restore(previous)
    }

    var isActive: Bool { change != nil }

    func mute() {
        guard change == nil, !FileManager.default.fileExists(atPath: Self.journal.path),
              let device = Self.defaultOutput(), Self.muted(device) == false, let uid = Self.uid(device) else { return }
        let next = Change(device: uid, ownerPID: ProcessInfo.processInfo.processIdentifier)
        do {
            try LocalSetup.prepare()
            try JSONEncoder().encode(next).write(to: Self.journal, options: .atomic)
        } catch { return }
        if Self.setMuted(device, true) { change = next }
        else { try? FileManager.default.removeItem(at: Self.journal) }
    }

    func restore() {
        guard let previous = change else { return }
        change = nil
        Self.restore(previous)
    }

    private static func restore(_ change: Change) {
        if let device = device(uid: change.device) { _ = setMuted(device, false) }
        try? FileManager.default.removeItem(at: journal)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutput() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    /// Nil when the device has no mute switch, as with many HDMI displays.
    private static func muted(_ device: AudioDeviceID) -> Bool? {
        var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &property),
              AudioObjectIsPropertySettable(device, &property, &settable) == noErr, settable.boolValue else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        var property = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &property, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static func uid(_ device: AudioDeviceID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func device(uid: String) -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var name = uid as CFString
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &device)
        }
        return status == noErr && device != 0 ? device : nil
    }
}
