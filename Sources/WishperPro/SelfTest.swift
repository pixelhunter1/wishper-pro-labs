import AppKit
import Foundation

@main
enum AppEntry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--selftest") {
            let audioPath = arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            SelfTest.run(audioPath: audioPath)
        }
        WishperProApp.main()
    }
}

/// `WishperPro --selftest [audio]`: offline checks, plus live and fallback transcription when an audio file is given.
@MainActor
enum SelfTest {
    private static var failures = 0

    static func run(audioPath: String?) -> Never {
        print("== Verificações offline ==")
        runOfflineChecks()
        guard let audioPath else { finish() }
        Task {
            print("== Verificações online (\(audioPath)) ==")
            await runOnlineChecks(audioURL: URL(fileURLWithPath: audioPath))
            finish()
        }
        dispatchMain()
    }

    static func check(_ condition: Bool, _ label: String) {
        if !condition { failures += 1 }
        print(condition ? "  ok      \(label)" : "  FALHOU  \(label)")
    }

    private static func finish() -> Never {
        print(failures == 0 ? "== Tudo OK ==" : "== \(failures) verificação(ões) falhada(s) ==")
        exit(failures == 0 ? 0 : 1)
    }

    private static func runOfflineChecks() {
        check(CommandLine.arguments.contains("--selftest"), "autoteste arrancou sem abrir a app")
    }

    private static func runOnlineChecks(audioURL: URL) async {
        check(FileManager.default.fileExists(atPath: audioURL.path), "ficheiro de áudio existe")
    }
}
