import AppKit
import AVFoundation
import Carbon
import Foundation
import ServiceManagement

enum DictationPhase: Equatable {
    case idle
    case listening
    case finalizing
    case done(String)
    case failed(String)
}

private enum DefaultsKey {
    static let hotkey = "wishper.push_to_talk_hotkey_data"
    static let translationEnabled = "wishper.translation_enabled"
    static let translationSource = "wishper.translation_source_language"
    static let translationTarget = "wishper.translation_target_language"
    static let autoPaste = "wishper.auto_paste"
    static let restoreClipboard = "wishper.restore_clipboard"
    static let showInDock = "wishper.show_in_dock"
    static let hotkeyBehavior = "wishper.hotkey_behavior"
    static let bubbleMode = "wishper.bubble_mode"
    static let bubblePosition = "wishper.bubble_position"
}

private func storedBool(_ key: String, default value: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? value
}

private func storedLanguage(_ key: String, default value: SupportedLanguage) -> SupportedLanguage {
    guard let raw = UserDefaults.standard.string(forKey: key) else { return value }
    // Before pt-PT/pt-BR existed, Portuguese was saved as "pt".
    return SupportedLanguage(rawValue: raw == "pt" ? SupportedLanguage.portuguesePT.rawValue : raw) ?? value
}

@MainActor
final class VoicePasteViewModel: ObservableObject {
    @Published var apiKeyDraft = ""
    @Published private(set) var statusMessage = "Pronto para ditar."
    @Published private(set) var isStatusError = false
    @Published private(set) var lastTranscript = ""
    @Published private(set) var phase: DictationPhase = .idle
    @Published private(set) var liveTranscript = ""
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var targetAppName: String?
    @Published private(set) var targetAppIcon: NSImage?
    @Published private(set) var isAPIKeySaved = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var hotkeyLabel = "Option + Space"
    @Published private(set) var isHotkeyReady = false
    @Published private(set) var isCapturingHotkey = false

    @Published var translationEnabled = storedBool(DefaultsKey.translationEnabled, default: false) {
        didSet { persistTranslationSettings() }
    }
    @Published var selectedSourceLanguage = storedLanguage(DefaultsKey.translationSource, default: .auto) {
        didSet { persistTranslationSettings() }
    }
    @Published var selectedTargetLanguage = storedLanguage(DefaultsKey.translationTarget, default: .english) {
        didSet { persistTranslationSettings() }
    }
    @Published var autoPasteEnabled = storedBool(DefaultsKey.autoPaste, default: true) {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: DefaultsKey.autoPaste) }
    }
    @Published var restoreClipboard = storedBool(DefaultsKey.restoreClipboard, default: true) {
        didSet { UserDefaults.standard.set(restoreClipboard, forKey: DefaultsKey.restoreClipboard) }
    }
    @Published var showInDock = storedBool(DefaultsKey.showInDock, default: false) {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: DefaultsKey.showInDock)
            applyDockVisibility()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @Published var hotkeyBehavior = HotkeyBehavior(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.hotkeyBehavior) ?? ""
    ) ?? .auto {
        didSet { UserDefaults.standard.set(hotkeyBehavior.rawValue, forKey: DefaultsKey.hotkeyBehavior) }
    }
    @Published var bubbleMode = BubbleMode(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.bubbleMode) ?? ""
    ) ?? .liveText {
        didSet { UserDefaults.standard.set(bubbleMode.rawValue, forKey: DefaultsKey.bubbleMode) }
    }
    @Published var bubblePosition = BubblePosition(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.bubblePosition) ?? ""
    ) ?? .bottomCenter {
        didSet { UserDefaults.standard.set(bubblePosition.rawValue, forKey: DefaultsKey.bubblePosition) }
    }

    var isRecording: Bool { phase == .listening }
    var isTranscribing: Bool { phase == .finalizing }

    var keyStatusText: String {
        isAPIKeySaved ? "Guardada no Keychain" : "Sem API key"
    }

    var needsSetup: Bool {
        !isAPIKeySaved || microphoneStatus != .authorized || !hasAccessibilityPermission
    }

    var menuStatusText: String {
        switch phase {
        case .listening:
            return "A ouvir…"
        case .finalizing:
            return "A finalizar…"
        case .done(let message), .failed(let message):
            return message
        case .idle:
            if isStatusError { return statusMessage }
            return isHotkeyReady ? "Pronto · \(hotkeyLabel)" : "Atalho indisponível"
        }
    }

    private let keychain = KeychainService()
    private let translationClient = OpenAITranslationClient()
    private let autoPaster = AutoPaster()
    private let hotkeyMonitor = GlobalHotkeyMonitor()
    private let soundCuePlayer = SoundCuePlayer()
    private var session: DictationSession?
    private var resetTask: Task<Void, Never>?
    private var activeAPIKey: String?
    private var activeShortcut: HotkeyShortcut = .default
    private var localCaptureMonitor: Any?
    private var globalCaptureMonitor: Any?
    private var hotkeySuspendedForCapture = false
    private var isHandsFree = false
    private var hotkeyPressedAt = Date.distantPast
    private var targetIsSelf = false

    init() {
        if let savedKey = keychain.loadAPIKey(), !savedKey.isEmpty {
            apiKeyDraft = savedKey
            isAPIKeySaved = true
            activeAPIKey = savedKey
        }
        hasAccessibilityPermission = autoPaster.hasAccessibilityPermission
        hotkeyMonitor.onEscape = { [weak self] in
            self?.cancelDictation()
        }

        let preferredShortcut = loadPersistedHotkey() ?? .default
        let registerPreferredResult = registerHotkey(preferredShortcut)
        switch registerPreferredResult {
        case .registered:
            applyRegisteredHotkey(preferredShortcut, persistSelection: false)
        case .failed:
            if preferredShortcut != .default {
                let fallback = HotkeyShortcut.default
                switch registerHotkey(fallback) {
                case .registered:
                    applyRegisteredHotkey(fallback, persistSelection: true)
                    setStatus("Atalho anterior indisponível. Aplicado \(fallback.label).", isError: true)
                case .failed(let message):
                    isHotkeyReady = false
                    hotkeyLabel = preferredShortcut.label
                    setStatus("\(message) Usa o menu Wishper Pro para ditar.", isError: true)
                }
            } else if case .failed(let message) = registerPreferredResult {
                isHotkeyReady = false
                hotkeyLabel = preferredShortcut.label
                setStatus("\(message) Usa o menu Wishper Pro para ditar.", isError: true)
            }
        }
    }

    // MARK: - Settings

    func saveAPIKey() {
        let trimmedKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            setStatus("Introduz uma API key válida.", isError: true)
            return
        }

        do {
            try keychain.saveAPIKey(trimmedKey)
            isAPIKeySaved = true
            apiKeyDraft = trimmedKey
            activeAPIKey = trimmedKey
            setStatus("API key guardada localmente.", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func clearAPIKey() {
        do {
            try keychain.deleteAPIKey()
            isAPIKeySaved = false
            apiKeyDraft = ""
            activeAPIKey = nil
            setStatus("API key removida.", isError: false)
        } catch {
            setStatus(error.localizedDescription, isError: true)
        }
    }

    func requestAccessibilityPermission() {
        hasAccessibilityPermission = autoPaster.requestAccessibilityPermission()
        if !hasAccessibilityPermission {
            SystemSettings.open(.accessibility)
        }
    }

    func refreshPermissions() {
        hasAccessibilityPermission = autoPaster.hasAccessibilityPermission
        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func requestMicrophoneAccess() {
        Task {
            _ = await Permissions.requestMicrophoneAccess()
            refreshPermissions()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            setStatus("Não foi possível alterar o arranque automático: \(error.localizedDescription)", isError: true)
        }
        refreshPermissions()
    }

    func applyDockVisibility() {
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
    }

    func copyLastTranscript() {
        guard !lastTranscript.isEmpty else { return }
        autoPaster.copy(lastTranscript)
    }

    func beginHotkeyCapture() {
        guard !isCapturingHotkey else { return }

        stopCaptureMonitors()
        isCapturingHotkey = true
        hotkeySuspendedForCapture = true
        isHotkeyReady = false
        hotkeyMonitor.stop()

        NSApp.activate(ignoringOtherApps: true)
        if let keyWindow = NSApp.keyWindow ?? NSApp.windows.first {
            keyWindow.makeKeyAndOrderFront(nil)
            keyWindow.makeFirstResponder(keyWindow.contentView)
        }

        setStatus("Pressiona a nova combinação de teclas (Esc para cancelar).", isError: false)

        localCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            guard self.isCapturingHotkey else { return event }
            _ = self.handleCaptureEvent(event)
            return event
        }

        globalCaptureMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return }
            guard self.isCapturingHotkey else { return }
            _ = self.handleCaptureEvent(event)
        }
    }

    func cancelHotkeyCapture() {
        guard isCapturingHotkey else { return }
        stopCaptureMonitors()
        isCapturingHotkey = false
        restoreCurrentHotkeyAfterCapture(
            statusMessage: "Captura de atalho cancelada.",
            isError: false
        )
    }

    // MARK: - Dictation

    func toggleRecordingFromButton() {
        switch phase {
        case .listening:
            stopDictation()
        case .finalizing:
            break
        case .idle, .done, .failed:
            isHandsFree = true
            startDictation()
        }
    }

    func cancelDictation() {
        guard phase == .listening else { return }
        session?.cancel()
        session = nil
        endListening()
        soundCuePlayer.playStopCue()
        setPhase(.idle)
        setStatus("Ditado cancelado.", isError: false)
    }

    private func handleHotkey(_ event: HotkeyEvent) {
        let now = Date()
        if event == .press {
            hotkeyPressedAt = now
        }
        let action = HotkeyDecider.action(
            behavior: hotkeyBehavior,
            event: event,
            state: hotkeyState,
            heldFor: now.timeIntervalSince(hotkeyPressedAt)
        )
        switch action {
        case .start:
            isHandsFree = false
            startDictation()
        case .stop:
            stopDictation()
        case .enterHandsFree:
            isHandsFree = true
        case .ignore:
            break
        }
    }

    private var hotkeyState: HotkeyState {
        switch phase {
        case .listening:
            return .listening(handsFree: isHandsFree)
        case .finalizing:
            return .busy
        case .idle, .done, .failed:
            return .idle
        }
    }

    private func startDictation() {
        guard let apiKey = activeAPIKey, !apiKey.isEmpty else {
            isAPIKeySaved = false
            fail("Guarda a API key antes de iniciar o ditado.")
            SettingsOpener.open()
            return
        }
        // Checked synchronously so a quick press/release can't race an async permission prompt.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            requestMicrophoneAccess()
            setStatus("Permite o acesso ao microfone e volta a tentar.", isError: false)
            return
        default:
            fail("Permissão de microfone negada.")
            SettingsOpener.open()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let session = DictationSession(options: .init(
            apiKey: apiKey,
            languages: selectedSourceLanguage.isoCode.map { [$0] } ?? [],
            prompt: transcriptionPrompt()
        ))
        session.onUpdate = { [weak self] text, level in
            self?.liveTranscript = text
            self?.audioLevel = level
        }
        session.onInterruption = { [weak self] in
            self?.stopDictation()
        }
        do {
            try session.start()
        } catch {
            fail(error.localizedDescription)
            return
        }

        self.session = session
        targetAppName = frontmost?.localizedName
        targetAppIcon = frontmost?.icon
        targetIsSelf = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        liveTranscript = ""
        audioLevel = 0
        setPhase(.listening)
        hotkeyMonitor.setEscapeEnabled(true)
        soundCuePlayer.playStartCue()
        setStatus("A ouvir…", isError: false)
    }

    private func stopDictation() {
        guard phase == .listening, let session else { return }
        endListening()
        soundCuePlayer.playStopCue()
        setPhase(.finalizing)
        setStatus("A finalizar…", isError: false)
        Task { [weak self] in
            do {
                let text = try await session.finish()
                await self?.deliver(text, usedFallback: session.usedFallback)
            } catch {
                self?.fail(error.localizedDescription)
            }
            if self?.session === session {
                self?.session = nil
            }
        }
    }

    private func endListening() {
        hotkeyMonitor.setEscapeEnabled(false)
        isHandsFree = false
        audioLevel = 0
    }

    private func deliver(_ transcript: String, usedFallback: Bool) async {
        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            fail("Não foi possível gerar texto da gravação.")
            return
        }

        var warning: String?
        if translationEnabled, let apiKey = activeAPIKey {
            do {
                text = try await translationClient.translate(
                    text: text,
                    sourceLanguage: selectedSourceLanguage.translationName,
                    targetLanguage: selectedTargetLanguage.translationName,
                    apiKey: apiKey
                )
            } catch {
                warning = "Tradução falhou: \(error.localizedDescription)"
            }
        }
        lastTranscript = text
        hasAccessibilityPermission = autoPaster.hasAccessibilityPermission

        if autoPasteEnabled, hasAccessibilityPermission, !targetIsSelf {
            do {
                try await autoPaster.paste(text: text, restoreClipboard: restoreClipboard)
                complete(targetAppName.map { "Colado · \($0)" } ?? "Colado", warning: warning, usedFallback: usedFallback)
                return
            } catch {
                warning = warning ?? error.localizedDescription
            }
        } else if autoPasteEnabled, !hasAccessibilityPermission {
            warning = warning ?? "Falta a permissão de Acessibilidade para colar. O texto ficou no clipboard."
        }
        autoPaster.copy(text)
        complete("Copiado", warning: warning, usedFallback: usedFallback)
    }

    private func complete(_ message: String, warning: String?, usedFallback: Bool) {
        setPhase(.done(message))
        if let warning {
            setStatus(warning, isError: true)
        } else {
            setStatus(usedFallback ? "\(message) (modo ficheiro)" : message, isError: false)
        }
    }

    private func fail(_ message: String) {
        setPhase(.failed(message))
        setStatus(message, isError: true)
    }

    /// `done` stays visible for 1.2 s and `failed` for 2.5 s, then the phase returns to idle.
    private func setPhase(_ newPhase: DictationPhase) {
        phase = newPhase
        resetTask?.cancel()
        let visibleFor: Duration
        switch newPhase {
        case .done:
            visibleFor = .milliseconds(1_200)
        case .failed:
            visibleFor = .milliseconds(2_500)
        case .idle, .listening, .finalizing:
            return
        }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: visibleFor)
            guard !Task.isCancelled, let self, self.phase == newPhase else { return }
            self.phase = .idle
        }
    }

    private func transcriptionPrompt() -> String? {
        switch selectedSourceLanguage {
        case .portuguesePT:
            return "Transcrição em português europeu de Portugal. Utilizar ortografia e vocabulário de Portugal (ex: facto, autocarro, telemóvel, pequeno-almoço, ecrã)."
        case .portugueseBR:
            return "Transcrição em português brasileiro. Utilizar ortografia e vocabulário do Brasil (ex: fato, ônibus, celular, café da manhã, tela)."
        default:
            return nil
        }
    }

    // MARK: - Hotkey

    private func registerHotkey(_ shortcut: HotkeyShortcut) -> HotkeyRegistrationResult {
        hotkeyMonitor.start(
            shortcut: shortcut,
            onPress: { [weak self] in self?.handleHotkey(.press) },
            onRelease: { [weak self] in self?.handleHotkey(.release) }
        )
    }

    private func finishHotkeyCapture(_ newShortcut: HotkeyShortcut) {
        stopCaptureMonitors()
        isCapturingHotkey = false

        if newShortcut == activeShortcut {
            restoreCurrentHotkeyAfterCapture(
                statusMessage: "Atalho mantido em \(newShortcut.label).",
                isError: false
            )
            return
        }

        let previousShortcut = activeShortcut
        switch registerHotkey(newShortcut) {
        case .registered:
            hotkeySuspendedForCapture = false
            applyRegisteredHotkey(newShortcut, persistSelection: true)
            setStatus("Atalho push-to-talk atualizado para \(newShortcut.label).", isError: false)
        case .failed(let message):
            _ = registerHotkey(previousShortcut)
            hotkeySuspendedForCapture = false
            applyRegisteredHotkey(previousShortcut, persistSelection: false)
            setStatus(message, isError: true)
        }
    }

    private func handleCaptureEvent(_ event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape) {
            cancelHotkeyCapture()
            return true
        }

        if event.type == .flagsChanged {
            guard Self.isModifierKey(event.keyCode) else { return false }
            guard let modifierMask = Self.modifierMask(for: event.keyCode) else { return false }
            guard let expectedFlag = Self.primaryModifierFlag(from: modifierMask) else { return false }
            guard event.modifierFlags.contains(expectedFlag) else { return false }

            let shortcut = HotkeyShortcut(
                keyCode: UInt32(event.keyCode),
                modifiers: modifierMask,
                kind: .modifierOnly
            )
            finishHotkeyCapture(shortcut)
            return true
        }

        guard event.type == .keyDown else {
            return false
        }

        if Self.isModifierKey(event.keyCode) {
            return false
        }

        let shortcut = makeShortcut(from: event)
        finishHotkeyCapture(shortcut)
        return true
    }

    private func makeShortcut(from event: NSEvent) -> HotkeyShortcut {
        HotkeyShortcut(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers(from: event.modifierFlags),
            kind: .keyCombo
        )
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let normalized = flags.intersection(.deviceIndependentFlagsMask)
        var value: UInt32 = 0
        if normalized.contains(.control) { value |= UInt32(controlKey) }
        if normalized.contains(.option) { value |= UInt32(optionKey) }
        if normalized.contains(.shift) { value |= UInt32(shiftKey) }
        if normalized.contains(.command) { value |= UInt32(cmdKey) }
        return value
    }

    private static func isModifierKey(_ keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }

    private static func modifierMask(for keyCode: UInt16) -> UInt32? {
        switch Int(keyCode) {
        case kVK_Command, kVK_RightCommand:
            return UInt32(cmdKey)
        case kVK_Shift, kVK_RightShift:
            return UInt32(shiftKey)
        case kVK_Option, kVK_RightOption:
            return UInt32(optionKey)
        case kVK_Control, kVK_RightControl:
            return UInt32(controlKey)
        default:
            return nil
        }
    }

    private static func primaryModifierFlag(from carbonModifiers: UInt32) -> NSEvent.ModifierFlags? {
        if carbonModifiers & UInt32(cmdKey) != 0 { return .command }
        if carbonModifiers & UInt32(optionKey) != 0 { return .option }
        if carbonModifiers & UInt32(controlKey) != 0 { return .control }
        if carbonModifiers & UInt32(shiftKey) != 0 { return .shift }
        return nil
    }

    private func stopCaptureMonitors() {
        if let localCaptureMonitor {
            NSEvent.removeMonitor(localCaptureMonitor)
            self.localCaptureMonitor = nil
        }

        if let globalCaptureMonitor {
            NSEvent.removeMonitor(globalCaptureMonitor)
            self.globalCaptureMonitor = nil
        }
    }

    private func restoreCurrentHotkeyAfterCapture(statusMessage: String, isError: Bool) {
        if hotkeySuspendedForCapture {
            switch registerHotkey(activeShortcut) {
            case .registered:
                hotkeySuspendedForCapture = false
                applyRegisteredHotkey(activeShortcut, persistSelection: false)
                setStatus(statusMessage, isError: isError)
            case .failed(let message):
                hotkeySuspendedForCapture = false
                isHotkeyReady = false
                setStatus(message, isError: true)
            }
        } else {
            setStatus(statusMessage, isError: isError)
        }
    }

    private func loadPersistedHotkey() -> HotkeyShortcut? {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.hotkey) else {
            return nil
        }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    private func persistHotkey(_ shortcut: HotkeyShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.hotkey)
    }

    private func applyRegisteredHotkey(_ shortcut: HotkeyShortcut, persistSelection: Bool) {
        activeShortcut = shortcut
        hotkeyLabel = shortcut.label
        isHotkeyReady = true

        if persistSelection {
            persistHotkey(shortcut)
        }
    }

    private func persistTranslationSettings() {
        let defaults = UserDefaults.standard
        defaults.set(translationEnabled, forKey: DefaultsKey.translationEnabled)
        defaults.set(selectedSourceLanguage.rawValue, forKey: DefaultsKey.translationSource)
        defaults.set(selectedTargetLanguage.rawValue, forKey: DefaultsKey.translationTarget)
    }

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        isStatusError = isError
    }
}

enum SupportedLanguage: String, CaseIterable, Identifiable {
    case auto
    case portuguesePT = "pt-PT"
    case portugueseBR = "pt-BR"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .portuguesePT: return "Português (Portugal)"
        case .portugueseBR: return "Português (Brasil)"
        case .english: return "Inglês"
        case .spanish: return "Espanhol"
        case .french: return "Francês"
        case .german: return "Alemão"
        case .italian: return "Italiano"
        }
    }

    var isoCode: String? {
        switch self {
        case .auto: return nil
        case .portuguesePT, .portugueseBR: return "pt"
        default: return rawValue
        }
    }

    var translationName: String {
        switch self {
        case .auto: return "Auto"
        case .portuguesePT: return "Português de Portugal"
        case .portugueseBR: return "Português do Brasil"
        default: return displayName
        }
    }

    static var targetLanguages: [SupportedLanguage] {
        allCases.filter { $0 != .auto }
    }
}
