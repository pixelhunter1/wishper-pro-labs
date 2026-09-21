import Foundation

/// A stretch of speech: when it starts and ends (seconds since the recording's time zero) and its PCM16 24 kHz audio.
struct Phrase: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var pcm: Data
}

/// Splits the voice into phrases at pauses, as it is recorded. Speech is `speechAboveNoise` over the room's noise
/// (the 10th percentile of the last 10 s): a fixed threshold sits on quiet voices, and the user speaks at −42…−49 dBFS
/// on the Studio Display with the room at −62…−75.
struct PhraseDetector {
    // Calibration knobs, measured on a real 37 s recording (6 phrases) on 2026-09-19.
    static let speechAboveNoise = 12.0
    static let pause: TimeInterval = 0.6
    /// Cutting phrases shorter than this was tried and reverted: each phrase is read on its own and every reading
    /// leaves silence behind it (a reading covers ~72% of the time its phrase was spoken), so twice the phrases means
    /// twice the pauses, and the narration comes out in fits and starts. Long phrases read better.
    static let maxPhrase: TimeInterval = 15
    /// The earliest a phrase may be cut: `cut()` looks for the quietest moment between here and now.
    static let cutAfter: TimeInterval = 6
    /// Someone who does not pause at all is cut here whatever the levels say, rather than growing without end.
    static let hardMaxPhrase: TimeInterval = 20
    /// How close to the room's noise a moment must be to count as a real gap between words. Speech is
    /// `speechAboveNoise` (12 dB) over the noise, so this sits well below it: cutting anywhere louder lands in the
    /// middle of a word.
    static let quietEnough = 5.0
    static let minSpeech: TimeInterval = 0.2
    /// Speech shorter than this does not close a phrase of its own: an "ok" or a "hmm" between two thoughts would
    /// otherwise become a phrase by itself, translated with no context and read in a third of the time it was said.
    /// It waits instead, and joins whatever is said next.
    static let minStandalone: TimeInterval = 1.2
    /// …unless the pause grows this long, which means nothing is coming and the short phrase stands alone after all.
    static let abandonPause: TimeInterval = 2.5
    static let preRoll: TimeInterval = 0.1
    static let postRoll: TimeInterval = 0.16
    /// Before any audio: a quiet room.
    static let defaultNoise = -65.0
    /// Digital silence would make any hiss count as speech.
    static let lowestNoise = -70.0

    static let frameSeconds: TimeInterval = 0.02
    private static let frameBytes = 960 // 20 ms of PCM16 at 24 kHz
    private static let noiseFrames = 500 // 10 s

    private var noiseLevels: [Double] = []
    private var noise = defaultNoise
    private var framesSinceNoise = 0
    private var partial = Data()
    // Audio kept from `bufferStart`: the open phrase, or the pre-roll while there is none. One level per frame.
    private var buffer = Data()
    private var bufferLevels: [Double] = []
    private var bufferStart: TimeInterval = 0
    private var next: TimeInterval?
    private var phraseStart: TimeInterval?
    private var lastSpeechEnd: TimeInterval = 0

    /// The room before time zero (the countdown): only teaches the noise level. Ignored once audio is appended.
    mutating func prime(_ pcm: Data) {
        guard next == nil else { return }
        var offset = pcm.startIndex
        while offset + Self.frameBytes <= pcm.endIndex {
            learnNoise(PCM16.decibels(of: pcm.subdata(in: offset..<offset + Self.frameBytes)))
            offset += Self.frameBytes
        }
    }

    /// Appends voice written at `time` (seconds since time zero) and returns the phrases it closed.
    mutating func append(_ pcm: Data, at time: TimeInterval) -> [Phrase] {
        var closed: [Phrase] = []
        // A hole in the voice (the microphone skipped): close what is open and count from the block's time.
        if let next, abs(time - next) > 0.05 {
            closed += close(at: min(lastSpeechEnd + Self.postRoll, next))
            restart(at: time)
        } else if next == nil {
            restart(at: time)
        }
        partial.append(pcm)
        var offset = 0
        while offset + Self.frameBytes <= partial.count {
            closed += frame(partial.subdata(in: offset..<offset + Self.frameBytes))
            offset += Self.frameBytes
        }
        // removeSubrange keeps the indices starting at 0 (removeFirst would shift them).
        partial.removeSubrange(0..<offset)
        return closed
    }

    /// The recording stopped: the open phrase, if any.
    mutating func finish() -> [Phrase] {
        guard let next else { return [] }
        return close(at: min(lastSpeechEnd + Self.postRoll, next))
    }

    private mutating func frame(_ bytes: Data) -> [Phrase] {
        let time = next ?? 0
        let level = PCM16.decibels(of: bytes)
        let isSpeech = level > noise + Self.speechAboveNoise
        learnNoise(level)
        buffer.append(bytes)
        bufferLevels.append(level)
        next = time + Self.frameSeconds
        if isSpeech {
            if phraseStart == nil { phraseStart = time }
            lastSpeechEnd = time + Self.frameSeconds
        }
        guard let phraseStart else {
            trim(keeping: Self.preRoll)
            return []
        }
        let now = time + Self.frameSeconds
        if now - lastSpeechEnd >= Self.pause {
            // Too little said to stand alone: hold it for what comes next, unless the pause says nothing is coming.
            if lastSpeechEnd - phraseStart < Self.minStandalone, now - lastSpeechEnd < Self.abandonPause {
                return []
            }
            return close(at: lastSpeechEnd + Self.postRoll)
        }
        if now - phraseStart >= Self.hardMaxPhrase {
            return cut(force: true)
        }
        if now - phraseStart >= Self.maxPhrase {
            return cut(force: false)
        }
        return []
    }

    /// Emits the open phrase up to `end` (if it had enough speech) and keeps only the pre-roll.
    private mutating func close(at end: TimeInterval) -> [Phrase] {
        guard let start = phraseStart else { return [] }
        phraseStart = nil
        defer { trim(keeping: Self.preRoll) }
        guard lastSpeechEnd - start >= Self.minSpeech else { return [] }
        return [phrase(from: start - Self.preRoll, to: end)]
    }

    /// A phrase too long for one reading is cut at its quietest 100 ms between `cutAfter` and the present — but only
    /// where that moment is a real gap between words (`quietEnough` over the room's noise). Someone speaking without
    /// pausing has no such moment: the phrase is left to grow until `hardMaxPhrase`, when `force` cuts it anyway,
    /// rather than slicing through the middle of a word.
    private mutating func cut(force: Bool) -> [Phrase] {
        guard let start = phraseStart else { return [] }
        let first = frameIndex(start + Self.cutAfter)
        let last = bufferLevels.count - 5
        var quietest = last
        var lowest = Double.infinity
        if first < last {
            for index in first..<last {
                let window = bufferLevels[index..<index + 5].reduce(0, +) / 5
                if window < lowest {
                    lowest = window
                    quietest = index + 2
                }
            }
        }
        guard force || lowest <= noise + Self.quietEnough else { return [] }
        let at = bufferStart + Double(quietest) * Self.frameSeconds
        let result = phrase(from: start - Self.preRoll, to: at)
        dropBuffer(before: at)
        phraseStart = at
        return [result]
    }

    private func phrase(from start: TimeInterval, to end: TimeInterval) -> Phrase {
        let from = max(start, bufferStart)
        let lower = min(max(0, byteOffset(from)), buffer.count)
        let upper = min(max(lower, byteOffset(end)), buffer.count)
        return Phrase(start: from, end: end, pcm: buffer.subdata(in: lower..<upper))
    }

    private mutating func learnNoise(_ level: Double) {
        noiseLevels.append(level)
        if noiseLevels.count > Self.noiseFrames {
            noiseLevels.removeFirst(noiseLevels.count - Self.noiseFrames)
        }
        framesSinceNoise += 1
        // Every 100 ms is enough; the percentile sorts 10 s of levels.
        guard framesSinceNoise >= 5 || noiseLevels.count <= 5 else { return }
        framesSinceNoise = 0
        let sorted = noiseLevels.sorted()
        noise = max(sorted[sorted.count / 10], Self.lowestNoise)
    }

    private mutating func restart(at time: TimeInterval) {
        partial = Data()
        buffer = Data()
        bufferLevels = []
        bufferStart = time
        next = time
        phraseStart = nil
    }

    private mutating func trim(keeping seconds: TimeInterval) {
        let keep = Int((seconds / Self.frameSeconds).rounded())
        let extra = bufferLevels.count - keep
        guard extra > 0 else { return }
        dropFrames(extra)
    }

    private mutating func dropBuffer(before time: TimeInterval) {
        dropFrames(max(0, min(frameIndex(time), bufferLevels.count)))
    }

    private mutating func dropFrames(_ count: Int) {
        buffer.removeSubrange(0..<count * Self.frameBytes)
        bufferLevels.removeFirst(count)
        bufferStart += Double(count) * Self.frameSeconds
    }

    private func frameIndex(_ time: TimeInterval) -> Int {
        Int(((time - bufferStart) / Self.frameSeconds).rounded())
    }

    private func byteOffset(_ time: TimeInterval) -> Int {
        Int(((time - bufferStart) * PCM16.sampleRate).rounded()) * 2
    }
}
