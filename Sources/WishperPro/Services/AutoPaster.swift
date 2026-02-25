import AppKit
import ApplicationServices

struct AutoPaster {
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [
            promptKey: true,
        ] as CFDictionary

        return AXIsProcessTrustedWithOptions(options)
    }

    func paste(text: String) throws {
        guard hasAccessibilityPermission else {
            throw AutoPasterError.missingPermission
        }
        guard !text.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Give the pasteboard a brief moment before dispatching Cmd+V.
        usleep(30_000)

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
