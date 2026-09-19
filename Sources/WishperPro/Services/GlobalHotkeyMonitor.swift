import AppKit
import Carbon
import Foundation

enum HotkeyBehavior: String, CaseIterable, Identifiable {
    case auto
    case hold
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automático"
        case .hold: return "Manter premido"
        case .toggle: return "Alternar"
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return "Mantém premido para falar enquanto seguras. Um toque rápido deixa a gravar até voltares a tocar."
        case .hold:
            return "Grava apenas enquanto o atalho estiver premido."
        case .toggle:
            return "Um toque inicia a gravação e outro toque termina."
        }
    }
}

enum HotkeyEvent: Equatable {
    case press
    case release
}

enum HotkeyState: Equatable {
    case idle
    case listening(handsFree: Bool)
    case busy
}

enum HotkeyAction: Equatable {
    case start
    case stop
    case enterHandsFree
    case ignore
}

enum HotkeyDecider {
    /// A press shorter than this is a tap (hands-free in `.auto`).
    static let tapThreshold: TimeInterval = 0.4

    static func action(
        behavior: HotkeyBehavior,
        event: HotkeyEvent,
        state: HotkeyState,
        heldFor: TimeInterval
    ) -> HotkeyAction {
        switch (behavior, event, state) {
        case (_, .press, .idle):
            return .start
        case (.toggle, .press, .listening):
            return .stop
        case (.auto, .press, .listening(handsFree: true)):
            return .stop
        case (.hold, .release, .listening):
            return .stop
        case (.auto, .release, .listening(handsFree: false)):
            return heldFor < tapThreshold ? .enterHandsFree : .stop
        default:
            return .ignore
        }
    }
}

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

@MainActor
final class GlobalHotkeyMonitor {
    private static let signature: OSType = 0x57535052 // "WSPR"
    private static let shortcutHotKeyID: UInt32 = 1
    private static let escapeHotKeyID: UInt32 = 2
    private static let stopRecordingHotKeyID: UInt32 = 3

    /// Called when Esc is pressed while `setEscapeEnabled(true)` is active.
    var onEscape: (@MainActor () -> Void)?
    /// Called when Control-Command-Esc is pressed while `setStopRecordingEnabled(true)` is active.
    var onStopRecording: (@MainActor () -> Void)?

    private var eventHandler: EventHandlerRef?
    private var shortcutHotKeyRef: EventHotKeyRef?
    private var escapeHotKeyRef: EventHotKeyRef?
    private var stopRecordingHotKeyRef: EventHotKeyRef?
    private var globalModifierMonitor: Any?
    private var localModifierMonitor: Any?
    private var activeShortcut: HotkeyShortcut?
    private var isModifierDown = false
    private var onPress: (@MainActor () -> Void)?
    private var onRelease: (@MainActor () -> Void)?

    // ponytail: no deinit cleanup — the monitor lives as long as the app.

    func start(
        shortcut: HotkeyShortcut,
        onPress: @escaping @MainActor () -> Void,
        onRelease: @escaping @MainActor () -> Void
    ) -> HotkeyRegistrationResult {
        stop()
        guard installEventHandlerIfNeeded() else {
            return .failed(message: "Não foi possível instalar o atalho global.")
        }
        self.onPress = onPress
        self.onRelease = onRelease
        activeShortcut = shortcut

        if shortcut.isModifierOnly {
            installModifierMonitors()
            return .registered(shortcutLabel: shortcut.label)
        }

        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            EventHotKeyID(signature: Self.signature, id: Self.shortcutHotKeyID),
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            stop()
            return .failed(
                message: "Não foi possível ativar o atalho \(shortcut.label). Pode estar em conflito no macOS."
            )
        }
        shortcutHotKeyRef = hotKeyRef
        return .registered(shortcutLabel: shortcut.label)
    }

    /// Esc cancels a dictation. It is registered only while listening, so other apps keep their Esc.
    func setEscapeEnabled(_ enabled: Bool) {
        setHotKey(&escapeHotKeyRef, enabled: enabled, keyCode: kVK_Escape, modifiers: 0, id: Self.escapeHotKeyID)
    }

    /// Control-Command-Esc stops a screen recording, as it stops macOS's own. Registered only while recording.
    func setStopRecordingEnabled(_ enabled: Bool) {
        setHotKey(
            &stopRecordingHotKeyRef,
            enabled: enabled,
            keyCode: kVK_Escape,
            modifiers: controlKey | cmdKey,
            id: Self.stopRecordingHotKeyID
        )
    }

    private func setHotKey(_ ref: inout EventHotKeyRef?, enabled: Bool, keyCode: Int, modifiers: Int, id: UInt32) {
        if enabled {
            guard ref == nil, installEventHandlerIfNeeded() else { return }
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(keyCode),
                UInt32(modifiers),
                EventHotKeyID(signature: Self.signature, id: id),
                GetEventDispatcherTarget(),
                0,
                &hotKeyRef
            )
            if status == noErr {
                ref = hotKeyRef
            }
        } else if let registered = ref {
            UnregisterEventHotKey(registered)
            ref = nil
        }
    }

    func stop() {
        if let shortcutHotKeyRef {
            UnregisterEventHotKey(shortcutHotKeyRef)
            self.shortcutHotKeyRef = nil
        }
        if let globalModifierMonitor {
            NSEvent.removeMonitor(globalModifierMonitor)
            self.globalModifierMonitor = nil
        }
        if let localModifierMonitor {
            NSEvent.removeMonitor(localModifierMonitor)
            self.localModifierMonitor = nil
        }
        activeShortcut = nil
        onPress = nil
        onRelease = nil
        isModifierDown = false
    }

    private func installEventHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }
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
                guard status == noErr else { return noErr }
                let isPress = GetEventKind(eventRef) == UInt32(kEventHotKeyPressed)
                let signature = hotKeyID.signature
                let id = hotKeyID.id
                let address = UInt(bitPattern: userData)
                // Carbon delivers hot key events on the main thread.
                let handled = MainActor.assumeIsolated {
                    guard let pointer = UnsafeRawPointer(bitPattern: address) else { return false }
                    return Unmanaged<GlobalHotkeyMonitor>.fromOpaque(pointer).takeUnretainedValue()
                        .handleHotKey(signature: signature, id: id, isPress: isPress)
                }
                // Another monitor's hot key (dictation and recording each have one) goes on to its handler.
                return handled ? noErr : OSStatus(eventNotHandledErr)
            },
            2,
            &eventTypes,
            userData,
            &eventHandler
        )
        return status == noErr
    }

    /// Whether the hot key was this monitor's.
    private func handleHotKey(signature: OSType, id: UInt32, isPress: Bool) -> Bool {
        guard signature == Self.signature else { return false }
        switch id {
        case Self.shortcutHotKeyID where shortcutHotKeyRef != nil:
            if isPress { onPress?() } else { onRelease?() }
        case Self.escapeHotKeyID where escapeHotKeyRef != nil:
            if isPress { onEscape?() }
        case Self.stopRecordingHotKeyID where stopRecordingHotKeyRef != nil:
            if isPress { onStopRecording?() }
        default:
            return false
        }
        return true
    }

    private func installModifierMonitors() {
        globalModifierMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                self?.handleModifierChange(keyCode: keyCode, flags: flags)
            }
        }
        localModifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                self?.handleModifierChange(keyCode: keyCode, flags: flags)
            }
            return event
        }
    }

    private func handleModifierChange(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let shortcut = activeShortcut,
              shortcut.isModifierOnly,
              UInt32(keyCode) == shortcut.keyCode,
              let expectedFlag = Self.primaryModifierFlag(from: shortcut.modifiers)
        else { return }
        let isDown = flags.contains(expectedFlag)
        guard isDown != isModifierDown else { return }
        isModifierDown = isDown
        if isDown { onPress?() } else { onRelease?() }
    }

    private static func primaryModifierFlag(from carbonModifiers: UInt32) -> NSEvent.ModifierFlags? {
        if carbonModifiers & UInt32(cmdKey) != 0 { return .command }
        if carbonModifiers & UInt32(optionKey) != 0 { return .option }
        if carbonModifiers & UInt32(controlKey) != 0 { return .control }
        if carbonModifiers & UInt32(shiftKey) != 0 { return .shift }
        return nil
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
