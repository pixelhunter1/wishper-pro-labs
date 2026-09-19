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
