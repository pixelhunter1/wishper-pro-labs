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
        guard hasFocusedEditableTextTarget() else {
            throw AutoPasterError.noFocusedTextTarget
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

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

    private func hasFocusedEditableTextTarget() -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard result == .success, let focusedRef else {
            return false
        }

        let focusedElement = focusedRef as! AXUIElement
        return isEditableTextElementOrAncestor(focusedElement)
    }

    private func isEditableTextElementOrAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element

        for _ in 0..<6 {
            guard let node = current else { return false }
            if isEditableTextElement(node) {
                return true
            }
            current = parentElement(of: node)
        }

        return false
    }

    private func isEditableTextElement(_ element: AXUIElement) -> Bool {
        if let editable = boolAttribute("AXEditable" as CFString, of: element) {
            return editable
        }

        var isSettable = DarwinBoolean(false)
        let valueSettableResult = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable
        )
        if valueSettableResult == .success, isSettable.boolValue {
            return true
        }

        guard let role = stringAttribute(kAXRoleAttribute as CFString, of: element) else {
            return false
        }

        let textRoles = [
            "AXTextField",
            "AXTextArea",
            "AXSearchField",
            "AXComboBox",
        ]
        return textRoles.contains(role)
    }

    private func parentElement(of element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentRef
        )
        guard result == .success, let parentRef else {
            return nil
        }
        guard CFGetTypeID(parentRef) == AXUIElementGetTypeID() else {
            return nil
        }
        let parentElement = parentRef as! AXUIElement
        return parentElement
    }

    private func stringAttribute(_ attribute: CFString, of element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? String
    }

    private func boolAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &valueRef)
        guard result == .success else {
            return nil
        }
        return valueRef as? Bool
    }
}

private enum AutoPasterError: LocalizedError {
    case missingPermission
    case cannotCreateEvent
    case noFocusedTextTarget

    var errorDescription: String? {
        switch self {
        case .missingPermission:
            return "Permissão de Accessibilidade necessária para auto-paste."
        case .cannotCreateEvent:
            return "Não foi possível simular o atalho Cmd+V."
        case .noFocusedTextTarget:
            return "Sem campo de texto ativo para colar automaticamente."
        }
    }
}
