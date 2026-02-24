import AppKit

enum RecordingCueSound: String, CaseIterable, Identifiable {
    case none
    case pop
    case tink
    case purr
    case glass
    case frog

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "Sem som"
        case .pop: return "Pop"
        case .tink: return "Tink"
        case .purr: return "Purr"
        case .glass: return "Glass"
        case .frog: return "Frog"
        }
    }

    fileprivate var systemSoundName: String? {
        switch self {
        case .none: return nil
        case .pop: return "Pop"
        case .tink: return "Tink"
        case .purr: return "Purr"
        case .glass: return "Glass"
        case .frog: return "Frog"
        }
    }
}

struct SoundCuePlayer {
    func playStartCue(_ cue: RecordingCueSound) {
        playCue(cue)
    }

    func playStopCue(_ cue: RecordingCueSound) {
        playCue(cue)
    }

    private func playCue(_ cue: RecordingCueSound) {
        guard cue != .none else { return }

        guard let sound = Self.loadCue(cue, volume: 0.35) else { return }

        sound.stop()
        sound.play()
    }

    private static func loadCue(_ cue: RecordingCueSound, volume: Float) -> NSSound? {
        guard let cueName = cue.systemSoundName else {
            return nil
        }

        let soundName = NSSound.Name(cueName)

        let sound: NSSound?
        if let bundledSound = NSSound(named: soundName) {
            sound = bundledSound
        } else {
            let systemURL = URL(fileURLWithPath: "/System/Library/Sounds/\(cueName).aiff")
            sound = NSSound(contentsOf: systemURL, byReference: true)
        }

        guard let sound else {
            return nil
        }

        sound.volume = volume
        return sound
    }
}
