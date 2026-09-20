import Foundation

/// A plain text log in `~/Library/Logs/Wishper Pro.log`, for problems that only show up on a real recording: what the
/// error said in full, and how much voice the file dropped. Nothing personal goes in it — no transcript, no
/// translation, only counts and error text.
enum DiagnosticLog {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("Wishper Pro.log")

    private static let queue = DispatchQueue(label: "com.wishper.pro.diagnostic-log")

    static func write(_ line: String) {
        let now = Date()
        queue.async {
            // Local time: an ISO8601 stamp would read an hour off from the clock the person is looking at.
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "pt_PT")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let stamped = "\(formatter.string(from: now))  \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
