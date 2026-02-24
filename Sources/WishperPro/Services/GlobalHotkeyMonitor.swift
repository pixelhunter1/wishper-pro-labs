import Carbon
import Foundation

struct HotkeyShortcut: Identifiable, Equatable {
    let id: String
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32

    static let presets: [HotkeyShortcut] = [
        HotkeyShortcut(
            id: "opt_space",
            label: "Option + Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey)
        ),
        HotkeyShortcut(
            id: "ctrl_opt_space",
            label: "Control + Option + Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey)
        ),
        HotkeyShortcut(
            id: "cmd_opt_space",
            label: "Command + Option + Space",
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey)
        ),
        HotkeyShortcut(
            id: "f8",
            label: "F8",
            keyCode: UInt32(kVK_F8),
            modifiers: 0
        ),
        HotkeyShortcut(
            id: "f9",
            label: "F9",
            keyCode: UInt32(kVK_F9),
            modifiers: 0
        ),
        HotkeyShortcut(
            id: "f10",
            label: "F10",
            keyCode: UInt32(kVK_F10),
            modifiers: 0
        ),
    ]

    static var `default`: HotkeyShortcut {
        presets[0]
    }

    static func byID(_ id: String) -> HotkeyShortcut? {
        presets.first(where: { $0.id == id })
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
    private var activeHotKeyID: UInt32?
    private var onTrigger: (() -> Void)?
    private var lastTriggerTime: Date = .distantPast
    private let debounceWindow: TimeInterval = 0.6

    func start(
        shortcut: HotkeyShortcut,
        onTrigger: @escaping () -> Void
    ) -> HotkeyRegistrationResult {
        stop()
        self.onTrigger = onTrigger

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
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

                monitor.handleHotKeyEvent(hotKeyID)
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
            GetApplicationEventTarget(),
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

        activeHotKeyID = nil
        onTrigger = nil
    }

    private func handleHotKeyEvent(_ hotKeyID: EventHotKeyID) {
        guard hotKeyID.signature == Self.signature else { return }
        guard let activeHotKeyID, hotKeyID.id == activeHotKeyID else { return }

        let now = Date()
        guard now.timeIntervalSince(lastTriggerTime) >= debounceWindow else {
            return
        }

        lastTriggerTime = now
        onTrigger?()
    }

    deinit {
        stop()
    }
}
