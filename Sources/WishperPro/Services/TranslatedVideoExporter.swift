import AppKit
import AVFoundation
import QuartzCore

/// Where the translated video's subtitles go.
enum SubtitleStyle: String, CaseIterable, Identifiable, Sendable {
    case player
    case image
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "No leitor"
        case .image: return "Na imagem"
        case .off: return "Sem legendas"
        }
    }

    var detail: String {
        switch self {
        case .player: return "Podem ligar-se e desligar-se no leitor de vídeo."
        case .image: return "Ficam sempre visíveis, também no Instagram e no WhatsApp. O vídeo demora mais a ficar pronto."
        case .off: return "O vídeo traduzido fica só com a voz."
        }
    }
}

/// Where each reading goes on the video's timeline: at the start of its phrase, sped up (pitch kept, up to 1.25×)
/// when it is longer than the time until the next phrase. If it still does not fit, the next one waits for it, and the
/// delay goes away at the next pause long enough.
enum VoicePlacement {
    static let gap: TimeInterval = 0.08
    static let maxRate = 1.25

    struct Slot: Equatable, Sendable {
        var start: TimeInterval
        var rate: Double
    }

    /// `readings` in order: when each phrase started and how long its reading lasts. `end` is the video's duration.
    static func place(_ readings: [(start: TimeInterval, duration: TimeInterval)], end: TimeInterval) -> [Slot] {
        var slots: [Slot] = []
        var free: TimeInterval = 0
        for (index, reading) in readings.enumerated() {
            let start = max(reading.start, free)
            let limit = index + 1 < readings.count ? readings[index + 1].start - gap : end
            let room = limit - start
            let rate = room > 0 ? min(max(reading.duration / room, 1), maxRate) : maxRate
            slots.append(Slot(start: start, rate: rate))
            free = start + reading.duration / rate
        }
        return slots
    }
}

struct SubtitleCue: Equatable, Sendable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// Subtitle cues: at most two lines of 42 characters each, a long phrase split over several cues with its time shared
/// by characters, at least 1 s per phrase, and no cue running into the next.
enum SubtitleCues {
    static let lineLength = 42
    static let minDuration: TimeInterval = 1

    static func make(_ phrases: [(text: String, start: TimeInterval, end: TimeInterval)]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for phrase in phrases {
            let parts = split(phrase.text)
            let characters = Double(parts.reduce(0) { $0 + $1.count })
            let duration = max(phrase.end - phrase.start, minDuration)
            var time = phrase.start
            for part in parts {
                let share = duration * Double(part.count) / characters
                cues.append(SubtitleCue(start: time, end: time + share, text: part))
                time += share
            }
        }
        for index in cues.indices.dropLast() where cues[index].end > cues[index + 1].start {
            cues[index].end = cues[index + 1].start
        }
        return cues
    }

    /// Lines of at most 42 characters, broken between words, two per cue.
    static func split(_ text: String) -> [String] {
        var lines: [String] = []
        var line = ""
        for word in text.split(whereSeparator: \.isWhitespace) {
            if !line.isEmpty, line.count + 1 + word.count > lineLength {
                lines.append(line)
                line = String(word)
            } else {
                line = line.isEmpty ? String(word) : "\(line) \(word)"
            }
        }
        if !line.isEmpty { lines.append(line) }
        return stride(from: 0, to: lines.count, by: 2).map { lines[$0..<min($0 + 2, lines.count)].joined(separator: "\n") }
    }
}

enum TranslatedVideoError: LocalizedError {
    case unreadable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "A gravação original não tem vídeo."
        case .failed(let reason): return reason
        }
    }
}

/// Builds the translated video from the original recording: its video (copied, or re-encoded with the subtitles drawn
/// in), the readings mixed with the Mac's sound in one AAC stereo track, and a subtitle track when they go in the
/// player.
@available(macOS 15, *)
enum TranslatedVideoExporter {
    static let sampleRate = 48_000.0

    /// `progress` gets 0…1 while the video is re-encoded (subtitles in the image).
    static func export(
        original: URL,
        phrases: [TranslatedPhrase],
        subtitles: SubtitleStyle,
        to output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        let asset = AVURLAsset(url: original)
        let duration = try await asset.load(.duration)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TranslatedVideoError.unreadable
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("wishper-translation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let lengths = phrases.map { Double($0.audio.count / 2) / PCM16.sampleRate }
        let slots = VoicePlacement.place(zip(phrases, lengths).map { ($0.start, $1) }, end: duration.seconds)
        let cues = SubtitleCues.make(zip(phrases, zip(slots, lengths)).map { phrase, placed in
            (phrase.text, placed.0.start, placed.0.start + placed.1 / placed.0.rate)
        })

        let audioURL = work.appendingPathComponent("audio.m4a")
        try await writeAudio(phrases: phrases, slots: slots, original: asset, duration: duration, to: audioURL)

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw TranslatedVideoError.unreadable
        }
        try video.insertTimeRange(range, of: videoTrack, at: .zero)
        let audioAsset = AVURLAsset(url: audioURL)
        if let mixed = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let length = min(duration, try await audioAsset.load(.duration))
            try audio.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: mixed, at: .zero)
        }

        var videoComposition: AVVideoComposition?
        if subtitles == .player, !cues.isEmpty {
            let subtitleURL = work.appendingPathComponent("subtitles.mov")
            try await writeSubtitles(cues, until: duration, to: subtitleURL)
            let subtitleAsset = AVURLAsset(url: subtitleURL)
            if let source = try await subtitleAsset.loadTracks(withMediaType: .subtitle).first,
               let track = composition.addMutableTrack(withMediaType: .subtitle, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(range, of: source, at: .zero)
            }
        } else if subtitles == .image, !cues.isEmpty {
            videoComposition = try await drawnSubtitles(cues, over: composition, size: try await videoTrack.load(.naturalSize))
        }

        let preset = videoComposition == nil ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw TranslatedVideoError.failed("não foi possível preparar a exportação")
        }
        session.videoComposition = videoComposition
        let states = session.states(updateInterval: 0.5)
        let watcher = Task {
            for await state in states {
                if case .exporting(let exporting) = state {
                    progress(exporting.fractionCompleted)
                }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: output, as: fileType)
    }

    /// `.mp4` keeps the `tx3g` subtitle track with a passthrough export (checked on macOS 26).
    static let fileType = AVFileType.mp4

    // MARK: Audio

    /// The readings at their slots plus the Mac's sound, clipped, as AAC 48 kHz stereo. Written 100 ms at a time, so a
    /// long recording never sits whole in memory.
    private static func writeAudio(
        phrases: [TranslatedPhrase],
        slots: [VoicePlacement.Slot],
        original: AVAsset,
        duration: CMTime,
        to url: URL
    ) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let clips = zip(phrases, slots).compactMap { phrase, slot -> (start: Int, samples: [Float])? in
            guard let samples = samples(of: phrase.audio, rate: slot.rate) else { return nil }
            return (Int((slot.start * sampleRate).rounded()), samples)
        }
        let macSound = try await MacSoundReader(asset: original)
        let total = Int((duration.seconds * sampleRate).rounded())
        let chunk = 4_800
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)),
              let channels = buffer.floatChannelData
        else { throw TranslatedVideoError.failed("sem memória para o áudio") }
        var position = 0
        while position < total {
            let count = min(chunk, total - position)
            buffer.frameLength = AVAudioFrameCount(count)
            let left = channels[0]
            let right = channels[1]
            if let macSound {
                macSound.fill(left, right, count: count)
            } else {
                left.update(repeating: 0, count: count)
                right.update(repeating: 0, count: count)
            }
            for clip in clips where clip.start < position + count && clip.start + clip.samples.count > position {
                for frame in max(position, clip.start)..<min(position + count, clip.start + clip.samples.count) {
                    let sample = clip.samples[frame - clip.start]
                    left[frame - position] += sample
                    right[frame - position] += sample
                }
            }
            for index in 0..<count {
                left[index] = min(max(left[index], -1), 1)
                right[index] = min(max(right[index], -1), 1)
            }
            try file.write(from: buffer)
            position += count
        }
    }

    /// A reading (PCM16 24 kHz) as 48 kHz float samples, sped up by `rate` with the pitch kept.
    static func samples(of pcm16: Data, rate: Double) -> [Float]? {
        let frames = pcm16.count / 2
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: PCM16.format, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: PCM16.format, to: output),
              let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(frames * 2 + 256))
        else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        pcm16.withUnsafeBytes { raw in
            input.int16ChannelData![0].update(from: raw.bindMemory(to: Int16.self).baseAddress!, count: frames)
        }
        let pending = PendingBuffer(input)
        var error: NSError?
        // endOfStream after the only buffer, so the resampler hands over its tail.
        converter.convert(to: converted, error: &error) { _, status in
            guard let next = pending.take() else {
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil else { return nil }
        let result = rate > 1.001 ? (try? stretched(converted, rate: rate)) ?? converted : converted
        return Array(UnsafeBufferPointer(start: result.floatChannelData![0], count: Int(result.frameLength)))
    }

    /// Speeds audio up without changing its pitch, rendered offline.
    private static func stretched(_ buffer: AVAudioPCMBuffer, rate: Double) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.rate = Float(rate)
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: buffer.format)
        engine.connect(pitch, to: engine.mainMixerNode, format: buffer.format)
        try engine.enableManualRenderingMode(.offline, format: buffer.format, maximumFrameCount: 4_096)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(buffer)
        player.play()
        let expected = AVAudioFrameCount(Double(buffer.frameLength) / rate)
        guard let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: expected),
              let block = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096)
        else { return buffer }
        while output.frameLength < expected {
            guard try engine.renderOffline(min(4_096, expected - output.frameLength), to: block) == .success else { break }
            let offset = Int(output.frameLength)
            output.floatChannelData![0].advanced(by: offset)
                .update(from: block.floatChannelData![0], count: Int(block.frameLength))
            output.frameLength += block.frameLength
        }
        return output
    }

    // MARK: Subtitles

    /// A QuickTime subtitle track (`tx3g`), with empty samples between cues so each one leaves on time.
    private static func writeSubtitles(_ cues: [SubtitleCue], until end: CMTime, to url: URL) async throws {
        let format = try textFormat()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
        guard writer.canAdd(input) else { throw TranslatedVideoError.failed("não foi possível escrever as legendas") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TranslatedVideoError.failed("legendas") }
        writer.startSession(atSourceTime: .zero)
        var time = 0.0
        var samples: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        for cue in cues where cue.end > cue.start {
            if cue.start > time { samples.append(("", time, cue.start)) }
            samples.append((cue.text, max(cue.start, time), cue.end))
            time = cue.end
        }
        if end.seconds > time { samples.append(("", time, end.seconds)) }
        for sample in samples {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard let buffer = textSample(sample.text, from: sample.start, to: sample.end, format: format),
                  input.append(buffer)
            else { throw writer.error ?? TranslatedVideoError.failed("legendas") }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TranslatedVideoError.failed("legendas") }
    }

    private static func textFormat() throws -> CMFormatDescription {
        let white: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 255,
            kCMTextFormatDescriptionColor_Green: 255,
            kCMTextFormatDescriptionColor_Blue: 255,
            kCMTextFormatDescriptionColor_Alpha: 255,
        ]
        let clear: [CFString: Any] = [
            kCMTextFormatDescriptionColor_Red: 0,
            kCMTextFormatDescriptionColor_Green: 0,
            kCMTextFormatDescriptionColor_Blue: 0,
            kCMTextFormatDescriptionColor_Alpha: 0,
        ]
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: clear,
            kCMTextFormatDescriptionExtension_HorizontalJustification: 1,
            kCMTextFormatDescriptionExtension_VerticalJustification: -1,
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0,
                kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0,
                kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0,
                kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1,
                kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor: white,
                kCMTextFormatDescriptionStyle_FontSize: 18,
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Subtitle,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw TranslatedVideoError.failed("formato das legendas") }
        return description
    }

    /// A `tx3g` sample: the text's UTF-8 length as a big-endian 16-bit number, then the text.
    private static func textSample(_ text: String, from start: TimeInterval, to end: TimeInterval, format: CMFormatDescription) -> CMSampleBuffer? {
        let utf8 = Array(text.utf8)
        var bytes = [UInt8(utf8.count >> 8 & 0xFF), UInt8(utf8.count & 0xFF)] + utf8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let block,
            CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: end - start, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var size = bytes.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }

    /// Subtitles drawn into the picture: white text on a dark box, centred near the bottom, 4.5% of the height.
    private static func drawnSubtitles(_ cues: [SubtitleCue], over composition: AVComposition, size: CGSize) async throws -> AVVideoComposition {
        let videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let videoLayer = CALayer()
        videoLayer.frame = parent.frame
        parent.addSublayer(videoLayer)
        let fontSize = (size.height * 0.045).rounded()
        for cue in cues {
            let box = subtitleBox(cue.text, fontSize: fontSize, maxWidth: size.width * 0.9)
            box.position = CGPoint(x: size.width / 2, y: size.height * 0.06 + box.bounds.height / 2)
            box.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 1
            show.toValue = 1
            show.beginTime = AVCoreAnimationBeginTimeAtZero + cue.start
            show.duration = cue.end - cue.start
            show.isRemovedOnCompletion = true
            box.add(show, forKey: "show")
            parent.addSublayer(box)
        }
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        return videoComposition
    }

    /// The subtitle as a picture: CATextLayer draws nothing in an export, so the box and its text are drawn here.
    private static func subtitleBox(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CALayer {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ])
        let textSize = string.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).size
        let padding = (fontSize * 0.35).rounded()
        let size = CGSize(width: ceil(textSize.width) + padding * 2, height: ceil(textSize.height) + padding * 2)
        let box = CALayer()
        box.bounds = CGRect(origin: .zero, size: size)
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return box }
        let radius = (fontSize * 0.25).rounded()
        context.addPath(CGPath(roundedRect: box.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        context.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        string.draw(with: CGRect(x: padding, y: padding, width: size.width - padding * 2, height: size.height - padding * 2),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        box.contents = context.makeImage()
        return box
    }
}

/// The original recording's Mac sound (its stereo track) as 48 kHz float, read in order as the mix needs it.
@available(macOS 15, *)
private final class MacSoundReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var left: [Float] = []
    private var right: [Float] = []
    private var isDone = false

    /// Nil when the recording has no Mac sound.
    init?(asset: AVAsset) async throws {
        var stereo: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let description = try await track.load(.formatDescriptions).first
            if description.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }) == 2 {
                stereo = track
            }
        }
        guard let stereo else { return nil }
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderTrackOutput(track: stereo, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TranslatedVideoExporter.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? TranslatedVideoError.unreadable }
    }

    /// Writes the next `count` frames (silence after the end).
    func fill(_ leftOut: UnsafeMutablePointer<Float>, _ rightOut: UnsafeMutablePointer<Float>, count: Int) {
        while left.count < count, !isDone {
            guard let sample = output.copyNextSampleBuffer(), let buffer = ScreenRecorder.pcmBuffer(sample),
                  let channels = buffer.floatChannelData
            else {
                isDone = true
                break
            }
            let frames = Int(buffer.frameLength)
            left += UnsafeBufferPointer(start: channels[0], count: frames)
            right += UnsafeBufferPointer(start: channels[buffer.format.channelCount > 1 ? 1 : 0], count: frames)
        }
        let available = min(count, left.count)
        leftOut.update(from: left, count: available)
        rightOut.update(from: right, count: available)
        (leftOut + available).update(repeating: 0, count: count - available)
        (rightOut + available).update(repeating: 0, count: count - available)
        left.removeFirst(available)
        right.removeFirst(available)
    }
}
