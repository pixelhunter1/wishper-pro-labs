import AVFoundation

/// PCM16 little-endian, 24 kHz, mono: the format `gpt-live-transcribe` expects.
enum PCM16 {
    static let sampleRate: Double = 24_000
    static let bytesPerSecond = 48_000
    static let chunkBytes = bytesPerSecond / 10

    static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    }

    /// RMS level in dBFS mapped from -55…0 dB to 0…1 (the scale the old AVAudioRecorder meter used).
    static func level(of data: Data) -> Double {
        guard data.count >= 2 else { return 0 }
        return min(max((decibels(of: data) + 55) / 55, 0), 1)
    }

    /// RMS level in dBFS (−100 for silence).
    static func decibels(of data: Data) -> Double {
        let count = data.count / 2
        guard count > 0 else { return -100 }
        var sum: Double = 0
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32_768
                sum += sample * sample
            }
        }
        return 10 * log10(max(sum / Double(count), 1e-10))
    }
}

/// 44-byte RIFF header + PCM16 24 kHz mono, for the `gpt-transcribe` fallback upload.
enum WAV {
    static func make(pcm16 data: Data) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        let sampleRate = UInt32(PCM16.sampleRate)
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + data.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(sampleRate)
        append(sampleRate * 2)
        append(UInt16(2))
        append(UInt16(16))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(data.count))
        return header + data
    }
}

/// Converts microphone or file buffers (to PCM16 24 kHz mono by default), keeping resampler state between chunks.
final class PCMConverter {
    private let converter: AVAudioConverter

    var inputFormat: AVAudioFormat { converter.inputFormat }

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat = PCM16.format) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    /// The converted samples as PCM16 bytes (the default output format).
    func convert(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let output = convertBuffer(buffer), let samples = output.int16ChannelData else { return Data() }
        return Data(bytes: samples[0], count: Int(output.frameLength) * 2)
    }

    /// A buffer in another format (a late one from before a device switch) makes the converter fail: it is dropped.
    func convertBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        let pending = PendingBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = pending.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return next
        }
        return status == .error ? nil : output
    }
}

/// Hands one buffer to AVAudioConverter's input block exactly once.
private final class PendingBuffer: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

enum MicrophoneStreamError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Não foi possível iniciar o microfone."
    }
}

/// Captures the default input as ~100 ms PCM16 chunks and keeps the whole recording for the fallback upload.
final class MicrophoneStream: @unchecked Sendable {
    typealias ChunkHandler = @Sendable (_ chunk: Data, _ level: Double) -> Void

    // The tap runs on an audio thread; the lock guards converter, pending, recording and onChunk.
    private let lock = NSLock()
    private var converter: PCMConverter?
    private var pending = Data()
    private var recording = Data()
    private var onChunk: ChunkHandler?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    var recordedAudio: Data {
        locked { recording }
    }

    /// Starts the microphone. `onInterruption` fires when the microphone can't carry on after a device change.
    func start(onChunk: @escaping ChunkHandler, onInterruption: @escaping @Sendable () -> Void) throws {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        try prepare(inputFormat: format, onChunk: onChunk)
        self.engine = engine
        // Bluetooth headsets switch to their call profile (e.g. 44.1 → 16 kHz) just after the microphone starts,
        // and the engine stops itself on any format change, so it restarts with the new format.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // Restart after the engine has finished posting, not inside its notification.
            DispatchQueue.main.async {
                do {
                    try self?.restart()
                } catch {
                    onInterruption()
                }
            }
        }
        do {
            try run(engine, format: format)
        } catch {
            stop()
            throw error
        }
    }

    /// Sets up conversion without the engine; `start` uses it, and the self-test uses it to feed audio files.
    func prepare(inputFormat: AVAudioFormat, onChunk: @escaping ChunkHandler) throws {
        try switchInput(to: inputFormat)
        locked {
            self.onChunk = onChunk
            pending = Data()
            recording = Data()
        }
    }

    /// Converts from `format` from now on, keeping what was already recorded.
    func switchInput(to format: AVAudioFormat) throws {
        guard let converter = PCMConverter(from: format) else {
            throw MicrophoneStreamError.unavailable
        }
        locked { self.converter = converter }
    }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        let (chunks, handler) = locked { () -> ([Data], ChunkHandler?) in
            guard let converter else { return ([], nil) }
            let converted = converter.convert(buffer)
            pending.append(converted)
            recording.append(converted)
            var chunks: [Data] = []
            while pending.count >= PCM16.chunkBytes {
                chunks.append(Data(pending.prefix(PCM16.chunkBytes)))
                pending = Data(pending.dropFirst(PCM16.chunkBytes))
            }
            return (chunks, onChunk)
        }
        for chunk in chunks {
            handler?(chunk, PCM16.level(of: chunk))
        }
    }

    /// Stops capture and delivers the last partial chunk. Safe to call more than once.
    func stop() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        let (tail, handler) = locked { () -> (Data, ChunkHandler?) in
            defer {
                pending = Data()
                onChunk = nil
                converter = nil
            }
            return (pending, onChunk)
        }
        if !tail.isEmpty {
            handler?(tail, PCM16.level(of: tail))
        }
    }

    private func run(_ engine: AVAudioEngine, format: AVAudioFormat) throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw MicrophoneStreamError.unavailable
        }
    }

    /// Picks up the device's new format after a configuration change. A stopped stream stays stopped.
    private func restart() throws {
        guard let engine else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        try switchInput(to: format)
        try run(engine, format: format)
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
