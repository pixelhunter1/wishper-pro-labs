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
