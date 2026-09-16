import AppKit
import ApplicationServices

struct AutoPaster {
    /// Marks our temporary clipboard content so clipboard managers skip it (nspasteboard.org convention).
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Puts `text` on the clipboard and leaves it there.
    func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Pastes `text` into the focused field with Cmd+V. With `restoreClipboard`, the previous clipboard
    /// comes back 0.5 s later, unless something else was copied in the meantime.
    @MainActor
    func paste(text: String, restoreClipboard: Bool, pasteboard: NSPasteboard = .general) async throws {
        guard hasAccessibilityPermission else {
            throw AutoPasterError.missingPermission
        }
        guard !text.isEmpty else { return }

        let saved = restoreClipboard ? Self.snapshot(pasteboard) : nil
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if restoreClipboard {
            pasteboard.setData(Data(), forType: Self.transientType)
        }
        let ourChange = pasteboard.changeCount
        // Give the pasteboard a brief moment before dispatching Cmd+V.
        try await Task.sleep(for: .milliseconds(30))
        try Self.sendCommandV()

        guard let saved else { return }
        try? await Task.sleep(for: .milliseconds(500))
        if pasteboard.changeCount == ourChange {
            Self.restore(saved, to: pasteboard)
        }
    }

    /// Deep-copies every item and type: pasteboard items can't be written back once the pasteboard is cleared.
    static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    private static func sendCommandV() throws {
        guard
            let source = CGEventSource(stateID: .combinedSessionState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            throw AutoPasterError.cannotCreateEvent
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

private enum AutoPasterError: LocalizedError {
    case missingPermission
    case cannotCreateEvent

    var errorDescription: String? {
        switch self {
        case .missingPermission:
            return "Permissão de Accessibilidade necessária para auto-paste."
        case .cannotCreateEvent:
            return "Não foi possível simular o atalho Cmd+V."
        }
    }
}
