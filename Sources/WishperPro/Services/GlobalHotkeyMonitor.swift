import Carbon
import Foundation

enum HotkeyRegistrationResult {
    case registered(shortcutLabel: String)
    case failed(message: String)
}

final class GlobalHotkeyMonitor {
    private struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
        let label: String
    }

    private static let signature: OSType = 0x57535052 // "WSPR"

    private let preferredShortcuts: [Shortcut] = [
        Shortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey),
            label: "Option + Space"
        ),
        Shortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(optionKey | controlKey),
            label: "Control + Option + Space"
        ),
    ]

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?
    private var activeHotKeyID: UInt32?
    private var onTrigger: (() -> Void)?
    private var lastTriggerTime: Date = .distantPast
    private let debounceWindow: TimeInterval = 0.6

    func start(onTrigger: @escaping () -> Void) -> HotkeyRegistrationResult {
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

        for (index, shortcut) in preferredShortcuts.enumerated() {
            var hotKeyRef: EventHotKeyRef?
            let id = UInt32(index + 1)
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr {
                self.hotKeyRef = hotKeyRef
                self.activeHotKeyID = id
                return .registered(shortcutLabel: shortcut.label)
            }
        }

        stop()
        return .failed(
            message: "Atalho global indisponível (atalho em conflito no macOS)."
        )
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
