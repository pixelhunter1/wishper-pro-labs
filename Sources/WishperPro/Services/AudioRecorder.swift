import AVFoundation

final class AudioRecorder {
    private var recorder: AVAudioRecorder?

    func start() throws {
        guard recorder == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        let outputURL = Self.newRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw AudioRecorderError.startFailed
        }

        self.recorder = recorder
    }

    func stop() throws -> URL {
        guard let recorder else {
            throw AudioRecorderError.notRecording
        }

        let outputURL = recorder.url
        recorder.stop()
        self.recorder = nil
        return outputURL
    }

    func currentAudioLevel() -> Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()

        let averagePower = recorder.averagePower(forChannel: 0)
        let minDb: Float = -55
        guard averagePower > minDb else { return 0 }

        let normalized = (averagePower - minDb) / abs(minDb)
        return min(max(Double(normalized), 0), 1)
    }

    private static func newRecordingURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wishper-\(UUID().uuidString)")
            .appendingPathExtension("wav")
    }
}

private enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case startFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Já existe uma gravação em curso."
        case .notRecording:
            return "Não existe gravação ativa."
        case .startFailed:
            return "Não foi possível iniciar a gravação."
        }
    }
}
