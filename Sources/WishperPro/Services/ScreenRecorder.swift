import AVFoundation
import ScreenCaptureKit

/// Which microphone a recording uses. Stored as `""` (system default), `"none"` or an `AVCaptureDevice.uniqueID`.
enum RecordingMicrophone: Equatable, Sendable {
    case off
    case systemDefault
    case device(String)

    /// A saved device that is not connected falls back to the system default.
    init(storedValue: String, connected: [String]) {
        switch storedValue {
        case "none": self = .off
        case "": self = .systemDefault
        default: self = connected.contains(storedValue) ? .device(storedValue) : .systemDefault
        }
    }

    var storedValue: String {
        switch self {
        case .off: return "none"
        case .systemDefault: return ""
        case .device(let id): return id
        }
    }
}

enum ScreenRecordingError: LocalizedError {
    case folderUnavailable
    case startFailed(String)
    case interrupted(String)
    case contentClosed

    var errorDescription: String? {
        switch self {
        case .folderUnavailable:
            return "Não foi possível criar a pasta Filmes/Wishper Pro."
        case .startFailed(let reason):
            return "Não foi possível começar a gravar: \(reason)"
        case .interrupted(let reason):
            return "Gravação interrompida: \(reason). O que foi gravado ficou guardado."
        case .contentClosed:
            return "A janela ou a app gravada fechou."
        }
    }

    /// A system error as a clause for the messages above: lowercase first letter, no final full stop.
    static func reason(_ error: Error) -> String {
        var text = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") {
            text.removeLast()
        }
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}

/// One recording: a ScreenCaptureKit stream (screen, the Mac's sound, microphone) written by a `RecordingWriter`.
/// The stream starts at once so the microphone warms up, but nothing is written until `beginWriting()`.
@available(macOS 15, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Microphone audio as 100 ms PCM16 24 kHz chunks and their level: the bubble now, live translation in part 2.
    var onMicrophone: (@Sendable (Data, Double) -> Void)?
    /// The stream ended by itself: `nil` when the person stopped it from the system's menu, otherwise why (the
    /// recorded window or app closed, the stream failed, a write failed). The owner then closes the file with
    /// `stop()` — or drops it with `cancel()` before time zero — so the file has a single closer.
    var onEnded: (@Sendable (Error?) -> Void)?

    let url: URL
    private let filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private let writer: RecordingWriter
    private var stream: SCStream?
    // Touched only on `queue`, where every sample arrives in order.
    private let queue = DispatchQueue(label: "com.wishper.pro.screen-recorder")
    private var levelConverter: PCMConverter?
    private var pendingLevel = Data()
    private var isClosed = false
    private var reportedFailure = false

    init(filter: SCContentFilter, microphone: RecordingMicrophone, systemAudio: Bool, url: URL) throws {
        let size = RecordingSize.output(points: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))
        self.url = url
        self.filter = filter
        configuration = Self.configuration(size: size, microphone: microphone, systemAudio: systemAudio)
        writer = try RecordingWriter(url: url, videoSize: size, voice: microphone != .off, systemAudio: systemAudio)
        super.init()
    }

    static func configuration(size: CGSize, microphone: RecordingMicrophone, systemAudio: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.captureResolution = .best
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = systemAudio
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = microphone != .off
        if case .device(let id) = microphone {
            configuration.microphoneCaptureDeviceID = id
        }
        return configuration
    }

    func start() async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
    }

    /// Time zero is now, on the capture clock.
    func beginWriting() {
        queue.async { [self] in
            // A recording that was already closed or cancelled must not start a session.
            guard !isClosed else { return }
            writer.begin(at: CMClockGetTime(CMClockGetHostTimeClock()))
        }
    }

    /// Stops the stream and closes the file.
    func stop() async throws -> URL {
        try? await stream?.stopCapture()
        try await close()
        return url
    }

    /// Cancelled before time zero: nothing is kept.
    func cancel() async {
        try? await stream?.stopCapture()
        guard await markClosed() != nil else { return }
        writer.cancel()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !isClosed, sample.isValid else { return }
        switch type {
        case .screen:
            guard let frame = Self.completeFrame(sample) else { return }
            writer.appendVideo(frame, at: sample.presentationTimeStamp)
        case .audio:
            writer.appendSystemAudio(sample)
        case .microphone:
            guard let buffer = Self.pcmBuffer(sample) else { return }
            writer.appendVoice(buffer, at: sample.presentationTimeStamp)
            reportLevel(buffer)
        @unknown default:
            break
        }
        // Any write can fail (e.g. the disk is full), even while the screen is still.
        if let failure = writer.failure, !reportedFailure {
            reportedFailure = true
            onEnded?(failure)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let stoppedByPerson = (error as? SCStreamError)?.code == .userStopped
        onEnded?(stoppedByPerson ? nil : error)
    }

    /// macOS 15.2+: the recorded window or app closed. The stream stays alive (it would wake if the window reopened),
    /// so without this the recording would go on with a frozen image.
    @available(macOS 15.2, *)
    func streamDidBecomeInactive(_ stream: SCStream) {
        onEnded?(ScreenRecordingError.contentClosed)
    }

    /// Closes the file once, whoever gets there first: `stop()` or the stream ending by itself.
    private func close() async throws {
        guard let end = await markClosed() else { return }
        try await writer.finish(at: end)
    }

    /// After the samples already queued, stops writing; returns the end time, or nil if already closed.
    private func markClosed() async -> CMTime? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !isClosed else {
                    continuation.resume(returning: nil)
                    return
                }
                isClosed = true
                continuation.resume(returning: CMClockGetTime(CMClockGetHostTimeClock()))
            }
        }
    }

    /// Same 100 ms PCM16 24 kHz chunks as the dictation microphone; a new converter when the format changes.
    private func reportLevel(_ buffer: AVAudioPCMBuffer) {
        if levelConverter?.inputFormat != buffer.format {
            levelConverter = PCMConverter(from: buffer.format)
        }
        guard let levelConverter else { return }
        pendingLevel.append(levelConverter.convert(buffer))
        while pendingLevel.count >= PCM16.chunkBytes {
            let chunk = Data(pendingLevel.prefix(PCM16.chunkBytes))
            pendingLevel = Data(pendingLevel.dropFirst(PCM16.chunkBytes))
            onMicrophone?(chunk, PCM16.level(of: chunk))
        }
    }

    /// Only complete frames carry a new image; idle ones mean the screen did not change.
    private static func completeFrame(_ sample: CMSampleBuffer) -> CVPixelBuffer? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            SCFrameStatus(rawValue: rawStatus) == .complete
        else { return nil }
        return sample.imageBuffer
    }

    private static func pcmBuffer(_ sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sample.formatDescription,
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        ) == noErr else { return nil }
        return buffer
    }
}
