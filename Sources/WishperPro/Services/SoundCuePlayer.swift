import AppKit

struct SoundCuePlayer {
    func playStartCue() {
        play("Pop")
    }

    func playStopCue() {
        play("Tink")
    }

    private func play(_ name: String) {
        guard let sound = Self.loadSound(named: name, volume: 0.35) else { return }
        sound.stop()
        sound.play()
    }

    private static func loadSound(named name: String, volume: Float) -> NSSound? {
        let soundName = NSSound.Name(name)

        let sound: NSSound?
        if let bundledSound = NSSound(named: soundName) {
            sound = bundledSound
        } else {
            let systemURL = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
            sound = NSSound(contentsOf: systemURL, byReference: true)
        }

        guard let sound else {
            return nil
        }

        sound.volume = volume
        return sound
    }
}
