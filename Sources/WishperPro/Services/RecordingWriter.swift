import AVFoundation
import CoreMedia
import Foundation

/// Output video size: the content in pixels, scaled down (same aspect) until the longer side is at most 3840 and the
/// shorter at most 2160, rounded down to even numbers (H.264 needs even sizes).
enum RecordingSize {
    static func output(points: CGSize, scale: CGFloat) -> CGSize {
        let width = max(points.width * scale, 2)
        let height = max(points.height * scale, 2)
        let factor = min(1, 3_840 / max(width, height), 2_160 / min(width, height))
        return CGSize(width: even(width * factor), height: even(height * factor))
    }

    /// The small margin keeps 2159.9999… (floating point) at 2160.
    private static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(Int(value + 0.001) & ~1)
    }
}

/// Where recordings go and what they are called.
enum RecordingFile {
    /// `~/Movies/Wishper Pro`. Movies is not behind a privacy permission; Desktop is, and ad-hoc reinstalls lose it.
    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wishper Pro", isDirectory: true)
    }

    /// "Gravação 2026-09-19 às 14.32.10.mov" in local time, with " 2", " 3"… when the name is taken.
    static func url(for date: Date, in folder: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.dateFormat = "yyyy-MM-dd 'às' HH.mm.ss"
        let base = "Gravação \(formatter.string(from: date))"
        var url = folder.appendingPathComponent("\(base).mov")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(number).mov")
            number += 1
        }
        return url
    }
}

/// Writes a recording: H.264 video, then the voice (AAC mono) and the Mac's sound (AAC stereo) when present, all on
/// the capture clock and starting at `begin(at:)`. Not thread-safe: its owner calls it on one queue.
final class RecordingWriter {
    /// The voice is written as 48 kHz mono whatever the microphone gives (Bluetooth headsets change format mid-way).
    static let voiceFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    /// Voice timestamps count samples; a block further than this from its own timestamp is handled apart.
    static let voiceDrift = CMTime(value: 50, timescale: 1_000)

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let frames: AVAssetWriterInputPixelBufferAdaptor
    private let voice: AVAssetWriterInput?
    private let systemAudio: AVAssetWriterInput?
    private var start: CMTime?
    private var lastFrame: CVPixelBuffer?
    private var lastFrameTime = CMTime.negativeInfinity
    private var voiceConverter: PCMConverter?
    private var nextVoiceTime: CMTime?

    /// The writer's error once it can no longer write (e.g. the disk is full).
    var failure: Error? {
        writer.status == .failed ? writer.error ?? CocoaError(.fileWriteUnknown) : nil
    }

    init(url: URL, videoSize: CGSize, voice hasVoice: Bool, systemAudio hasSystemAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        // A fragment every 10 s: if the app dies mid-recording, the file still opens up to the last fragment.
        writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height),
        ])
        frames = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
        voice = hasVoice ? Self.audioInput(channels: 1, bitRate: 128_000) : nil
        systemAudio = hasSystemAudio ? Self.audioInput(channels: 2, bitRate: 192_000) : nil
        for input in [video, voice, systemAudio].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(input)
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Time zero. The latest frame so far enters at that time: ScreenCaptureKit only sends frames when the screen
    /// changes.
    func begin(at time: CMTime) {
        writer.startSession(atSourceTime: time)
        start = time
        if let lastFrame {
            appendFrame(lastFrame, at: time)
        }
    }

    /// Before time zero only the latest frame is kept.
    func appendVideo(_ frame: CVPixelBuffer, at time: CMTime) {
        guard let start, time >= start else {
            lastFrame = frame
            return
        }
        appendFrame(frame, at: time)
    }

    /// Converts to 48 kHz mono (a new converter when the format changes) and times the voice by counting samples, so
    /// blocks never overlap or leave holes. After a gap of more than 50 ms the count restarts at the block's time; a
    /// block more than 50 ms behind the count is dropped (the microphone's clock ran fast).
    func appendVoice(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let voice, let start, time >= start else { return }
        if voiceConverter?.inputFormat != buffer.format {
            voiceConverter = PCMConverter(from: buffer.format, to: Self.voiceFormat)
        }
        guard let converted = voiceConverter?.convertBuffer(buffer), converted.frameLength > 0 else { return }
        var presentation = nextVoiceTime ?? time
        if presentation < time - Self.voiceDrift {
            presentation = time
        } else if presentation > time + Self.voiceDrift {
            return
        }
        guard voice.isReadyForMoreMediaData,
              let sample = Self.sampleBuffer(converted, at: presentation),
              voice.append(sample)
        else { return }
        nextVoiceTime = presentation + CMTime(value: CMTimeValue(converted.frameLength), timescale: 48_000)
    }

    /// ScreenCaptureKit's blocks go in as they come: the stream is asked for a fixed 48 kHz stereo format.
    func appendSystemAudio(_ sample: CMSampleBuffer) {
        guard let systemAudio, let start, sample.presentationTimeStamp >= start,
              systemAudio.isReadyForMoreMediaData
        else { return }
        systemAudio.append(sample)
    }

    /// Holds the last frame until `end` (so the video lasts as long as the audio) and closes the file.
    nonisolated(nonsending) func finish(at end: CMTime) async throws {
        guard start != nil else {
            cancel()
            throw CocoaError(.fileWriteUnknown)
        }
        // A failed writer raises an exception on endSession and finishWriting; what it wrote stays in its fragments.
        guard writer.status == .writing else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        if let lastFrame, end > lastFrameTime {
            appendFrame(lastFrame, at: end)
        }
        writer.endSession(atSourceTime: end)
        for input in [video, voice, systemAudio].compactMap({ $0 }) {
            input.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Stops without keeping a file (cancelled before time zero).
    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
        try? FileManager.default.removeItem(at: writer.outputURL)
    }

    /// A CMSampleBuffer holding `buffer`'s samples at `time`.
    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        ) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sample
        ) == noErr, let sample,
            CMSampleBufferSetDataBufferFromAudioBufferList(
                sample,
                blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0,
                bufferList: buffer.audioBufferList
            ) == noErr
        else { return nil }
        return sample
    }

    private func appendFrame(_ frame: CVPixelBuffer, at time: CMTime) {
        guard time > lastFrameTime else { return }
        // The newest image is kept even when the encoder is busy: finish(at:) repeats it at the end.
        lastFrame = frame
        guard video.isReadyForMoreMediaData, frames.append(frame, withPresentationTime: time) else { return }
        lastFrameTime = time
    }

    private static func audioInput(channels: Int, bitRate: Int) -> AVAssetWriterInput {
        AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
        ])
    }
}
