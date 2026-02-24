import AppKit
import Carbon
import Foundation

enum HotkeyKind: String, Codable {
    case keyCombo
    case modifierOnly
}

struct HotkeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let kind: HotkeyKind

    init(keyCode: UInt32, modifiers: UInt32, kind: HotkeyKind = .keyCombo) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.kind = kind
    }

    static let `default` = HotkeyShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        kind: .keyCombo
    )

    var label: String {
        HotkeyLabelFormatter.label(for: self)
    }

    var isModifierOnly: Bool {
        kind == .modifierOnly
    }
}

enum HotkeyRegistrationResult {
    case registered(shortcutLabel: String)
    case failed(message: String)
}

final class GlobalHotkeyMonitor {
    private static let signature: OSType = 0x57535052 // "WSPR"

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var fallbackGlobalMonitor: Any?
    private var fallbackLocalMonitor: Any?
    private var activeHotKeyID: UInt32?
    private var activeShortcut: HotkeyShortcut?
    private var onTrigger: (() -> Void)?
    private var lastTriggerTime: Date = .distantPast
    private var modifierKeyState: [UInt32: Bool] = [:]
    private let debounceWindow: TimeInterval = 0.6

    func start(
        shortcut: HotkeyShortcut,
        onTrigger: @escaping () -> Void
    ) -> HotkeyRegistrationResult {
        stop()
        self.onTrigger = onTrigger
        self.activeShortcut = shortcut

        if shortcut.isModifierOnly {
            installModifierOnlyMonitors()
            return .registered(shortcutLabel: shortcut.label)
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else {
                    return noErr
                }

                let monitor = Unmanaged<GlobalHotkeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard status == noErr else {
                    return noErr
                }

                monitor.handleCarbonHotKeyEvent(hotKeyID)
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )

        guard installStatus == noErr else {
            stop()
            return .failed(message: "Não foi possível instalar o atalho global.")
        }

        var hotKeyRef: EventHotKeyRef?
        let id: UInt32 = 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            stop()
            return .failed(
                message: "Não foi possível ativar o atalho \(shortcut.label). Pode estar em conflito no macOS."
            )
        }

        self.hotKeyRef = hotKeyRef
        self.activeHotKeyID = id
        return .registered(shortcutLabel: shortcut.label)
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        if let fallbackGlobalMonitor {
            NSEvent.removeMonitor(fallbackGlobalMonitor)
            self.fallbackGlobalMonitor = nil
        }

        if let fallbackLocalMonitor {
            NSEvent.removeMonitor(fallbackLocalMonitor)
            self.fallbackLocalMonitor = nil
        }

        activeHotKeyID = nil
        activeShortcut = nil
        onTrigger = nil
        modifierKeyState.removeAll(keepingCapacity: true)
    }

    private func installModifierOnlyMonitors() {
        guard let activeShortcut else { return }
        guard activeShortcut.isModifierOnly else { return }

        fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return }
            guard self.matches(event: event, shortcut: activeShortcut) else { return }
            self.fireIfNeeded()
        }

        fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            guard self.matches(event: event, shortcut: activeShortcut) else { return event }
            self.fireIfNeeded()
            return event
        }
    }

    private func handleCarbonHotKeyEvent(_ hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == Self.signature else { return }
        guard let activeHotKeyID, hotKeyID.id == activeHotKeyID else { return }
        fireIfNeeded()
    }

    private func matches(event: NSEvent, shortcut: HotkeyShortcut) -> Bool {
        if shortcut.isModifierOnly {
            return matchesModifierOnly(event: event, shortcut: shortcut)
        }
        return matchesKeyCombo(event: event, shortcut: shortcut)
    }

    private func matchesKeyCombo(event: NSEvent, shortcut: HotkeyShortcut) -> Bool {
        guard event.type == .keyDown else { return false }
        guard UInt32(event.keyCode) == shortcut.keyCode else { return false }
        let normalized = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbon = Self.carbonModifiers(from: normalized)
        return carbon == shortcut.modifiers
    }

    private func matchesModifierOnly(event: NSEvent, shortcut: HotkeyShortcut) -> Bool {
        guard event.type == .flagsChanged else { return false }
        guard UInt32(event.keyCode) == shortcut.keyCode else { return false }

        let expectedFlag = Self.primaryModifierFlag(from: shortcut.modifiers)
        guard let expectedFlag else { return false }

        let hasExpectedFlag = event.modifierFlags.contains(expectedFlag)
        let wasPressed = modifierKeyState[shortcut.keyCode] ?? false

        if !wasPressed && hasExpectedFlag {
            modifierKeyState[shortcut.keyCode] = true
            return true
        }

        if wasPressed && !hasExpectedFlag {
            modifierKeyState[shortcut.keyCode] = false
        } else if !wasPressed && !hasExpectedFlag {
            modifierKeyState[shortcut.keyCode] = false
        }

        return false
    }

    private func fireIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) >= debounceWindow else {
            return
        }
        lastTriggerTime = now
        onTrigger?()
    }

    private static func primaryModifierFlag(from carbonModifiers: UInt32) -> NSEvent.ModifierFlags? {
        if carbonModifiers & UInt32(cmdKey) != 0 { return .command }
        if carbonModifiers & UInt32(optionKey) != 0 { return .option }
        if carbonModifiers & UInt32(controlKey) != 0 { return .control }
        if carbonModifiers & UInt32(shiftKey) != 0 { return .shift }
        return nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.control) { value |= UInt32(controlKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    deinit {
        stop()
    }
}

private enum HotkeyLabelFormatter {
    static func label(for shortcut: HotkeyShortcut) -> String {
        if shortcut.isModifierOnly {
            return keyName(shortcut.keyCode)
        }

        var parts: [String] = []
        if shortcut.modifiers & UInt32(controlKey) != 0 { parts.append("Control") }
        if shortcut.modifiers & UInt32(optionKey) != 0 { parts.append("Option") }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { parts.append("Shift") }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { parts.append("Command") }
        parts.append(keyName(shortcut.keyCode))
        return parts.joined(separator: " + ")
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Escape"
        case kVK_Delete: return "Delete"
        case kVK_ForwardDelete: return "Forward Delete"
        case kVK_LeftArrow: return "Left Arrow"
        case kVK_RightArrow: return "Right Arrow"
        case kVK_UpArrow: return "Up Arrow"
        case kVK_DownArrow: return "Down Arrow"
        case kVK_Command: return "Left Command"
        case kVK_RightCommand: return "Right Command"
        case kVK_Shift: return "Left Shift"
        case kVK_RightShift: return "Right Shift"
        case kVK_Option: return "Left Option"
        case kVK_RightOption: return "Right Option"
        case kVK_Control: return "Left Control"
        case kVK_RightControl: return "Right Control"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "KeyCode \(keyCode)"
        }
    }
}
