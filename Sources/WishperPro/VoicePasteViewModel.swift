import AppKit
import AVFoundation
import Carbon
import Foundation
import ServiceManagement
import SwiftUI

private enum DefaultsKey {
    static let translationEnabled = "wishper.translation_enabled"
    static let translationSource = "wishper.translation_source_language"
    static let translationTarget = "wishper.translation_target_language"
    static let autoPaste = "wishper.auto_paste"
    static let showInDock = "wishper.show_in_dock"
    static let hotkeyBehavior = "wishper.hotkey_behavior"
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
    @Published var apiKeyDraft: String = ""
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var autoPasteEnabled = storedBool(DefaultsKey.autoPaste, default: true) {
        didSet { UserDefaults.standard.set(autoPasteEnabled, forKey: DefaultsKey.autoPaste) }
    }
    @Published var showInDock = storedBool(DefaultsKey.showInDock, default: false) {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: DefaultsKey.showInDock)
            applyDockVisibility()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @Published var statusMessage = "Pronto para ditar."
    @Published var isStatusError = false
    @Published var lastTranscript = ""
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var isSpeechDetected = false
    @Published private(set) var isAPIKeySaved = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var hotkeyLabel = "Option + Space"
    @Published private(set) var isHotkeyReady = false
    @Published private(set) var isCapturingHotkey = false
    @Published var hotkeyBehavior = HotkeyBehavior(
        rawValue: UserDefaults.standard.string(forKey: DefaultsKey.hotkeyBehavior) ?? ""
    ) ?? .auto {
        didSet { UserDefaults.standard.set(hotkeyBehavior.rawValue, forKey: DefaultsKey.hotkeyBehavior) }
    }
    @Published var translationEnabled = storedBool(DefaultsKey.translationEnabled, default: false) {
        didSet { persistTranslationSettings() }
    }
    @Published var selectedSourceLanguage = storedLanguage(DefaultsKey.translationSource, default: .auto) {
        didSet { persistTranslationSettings() }
    }
    @Published var selectedTargetLanguage = storedLanguage(DefaultsKey.translationTarget, default: .english) {
        didSet { persistTranslationSettings() }
    }

    var keyStatusText: String {
        isAPIKeySaved ? "Guardada no Keychain" : "Sem API key"
    }

    var needsSetup: Bool {
        !isAPIKeySaved || microphoneStatus != .authorized || !hasAccessibilityPermission
    }

    var menuStatusText: String {
        if isRecording { return "A ouvir…" }
        if isTranscribing { return "A finalizar…" }
        if isStatusError { return statusMessage }
        return isHotkeyReady ? "Pronto · \(hotkeyLabel)" : "Atalho indisponível"
    }

    var isActionDisabled: Bool {
        isTranscribing || (!isRecording && !isAPIKeySaved)
    }

    var bubbleStateTitle: String {
        if isTranscribing { return "A transcrever" }
        if isRecording { return isSpeechDetected ? "A falar" : "A ouvir" }
        return "Parado"
    }

    var bubbleStateSubtitle: String {
        if isTranscribing { return "processando áudio" }
        if isRecording { return isSpeechDetected ? "voz detetada" : "à escuta" }
        return "aguardando"
    }

    private let keychain = KeychainService()
    private let recorder = AudioRecorder()
    private let transcriptionClient = OpenAITranscriptionClient()
    private let translationClient = OpenAITranslationClient()
    private let autoPaster = AutoPaster()
    private let hotkeyMonitor = GlobalHotkeyMonitor()
    private let soundCuePlayer = SoundCuePlayer()
    private var transcriptionTask: Task<Void, Never>?
    private var audioMeterTask: Task<Void, Never>?
    private var activeAPIKey: String?
    private var activeShortcut: HotkeyShortcut = .default
    private var localCaptureMonitor: Any?
    private var globalCaptureMonitor: Any?
    private var hotkeySuspendedForCapture = false
    private var isHandsFree = false
    private var hotkeyPressedAt = Date.distantPast
    private static let hotkeyDefaultsKey = "wishper.push_to_talk_hotkey_data"
    private static let transcriptionModel = "gpt-4o-mini-transcribe"
    private static let transcriptionTimeoutSeconds: TimeInterval = 30
    private static let transcriptionMaxRetries = 0

    init() {
        if let savedKey = keychain.loadAPIKey(), !savedKey.isEmpty {
            apiKeyDraft = savedKey
            isAPIKeySaved = true
            activeAPIKey = savedKey
        }

        hasAccessibilityPermission = autoPaster.hasAccessibilityPermission

        hotkeyMonitor.onEscape = { [weak self] in
            self?.cancelRecording()
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
                    setStatus("\(message) Usa o botão Iniciar Ditado.", isError: true)
                }
            } else if case .failed(let message) = registerPreferredResult {
                isHotkeyReady = false
                hotkeyLabel = preferredShortcut.label
                setStatus("\(message) Usa o botão Iniciar Ditado.", isError: true)
            }
        }
    }

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
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
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

    func cancelTranscription() {
        guard isTranscribing else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        setStatus("Transcrição cancelada.", isError: false)
    }

    func toggleRecordingFromButton() {
        if isRecording {
            stopAndTranscribe()
        } else if !isTranscribing {
            isHandsFree = true
            startRecording()
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        hotkeyMonitor.setEscapeEnabled(false)
        isHandsFree = false
        if let url = try? recorder.stop() {
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        stopAudioMetering()
        soundCuePlayer.playStopCue()
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
            startRecording()
        case .stop:
            stopAndTranscribe()
        case .enterHandsFree:
            isHandsFree = true
        case .ignore:
            break
        }
    }

    private var hotkeyState: HotkeyState {
        if isRecording { return .listening(handsFree: isHandsFree) }
        return isTranscribing ? .busy : .idle
    }

    private func startRecording() {
        guard let savedKey = activeAPIKey, !savedKey.isEmpty else {
            isAPIKeySaved = false
            setStatus("Guarda a API key antes de iniciar o ditado.", isError: true)
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
            setStatus("Permissão de microfone negada.", isError: true)
            SettingsOpener.open()
            return
        }

        do {
            try recorder.start()
            isRecording = true
            lastTranscript = ""
            startAudioMetering()
            hotkeyMonitor.setEscapeEnabled(true)
            soundCuePlayer.playStartCue()
            setStatus("A ouvir…", isError: false)
        } catch {
            stopAudioMetering()
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func stopAndTranscribe() {
        hotkeyMonitor.setEscapeEnabled(false)
        isHandsFree = false
        let recordingURL: URL
        do {
            recordingURL = try recorder.stop()
        } catch {
            isRecording = false
            stopAudioMetering()
            setStatus(error.localizedDescription, isError: true)
            return
        }

        isRecording = false
        stopAudioMetering()
        soundCuePlayer.playStopCue()
        isTranscribing = true
        setStatus("A transcrever áudio...", isError: false)
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.isTranscribing = false
                    self.transcriptionTask = nil
                    try? FileManager.default.removeItem(at: recordingURL)
                }
            }

            do {
                guard let apiKey = await MainActor.run(body: { self.activeAPIKey }), !apiKey.isEmpty else {
                    throw VoicePasteError.missingAPIKey
                }

                let languageHint = await MainActor.run(body: { self.transcriptionLanguageHint() })
                let prompt = await MainActor.run(body: { self.transcriptionPrompt() })
                let transcriptionResult = try await self.transcriptionClient.transcribeAudio(
                    fileURL: recordingURL,
                    apiKey: apiKey,
                    model: Self.transcriptionModel,
                    languageHint: languageHint,
                    prompt: prompt,
                    timeoutSeconds: Self.transcriptionTimeoutSeconds,
                    maxRetries: Self.transcriptionMaxRetries
                )
                try Task.checkCancellation()

                let cleanTranscript = transcriptionResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTranscript.isEmpty else {
                    throw VoicePasteError.emptyTranscription
                }

                var outputText = cleanTranscript
                var translationRequested = false
                var translationFailedMessage: String?
                let translationRequest = await MainActor.run(body: { self.currentTranslationRequest() })
                if let translationRequest {
                    translationRequested = true
                    await MainActor.run {
                        self.setStatus("A traduzir para \(translationRequest.targetLanguage)...", isError: false)
                    }

                    do {
                        outputText = try await self.translationClient.translate(
                            text: cleanTranscript,
                            sourceLanguage: translationRequest.sourceLanguage,
                            targetLanguage: translationRequest.targetLanguage,
                            apiKey: apiKey
                        )
                    } catch {
                        translationFailedMessage = error.localizedDescription
                    }
                }

                await MainActor.run {
                    self.lastTranscript = outputText
                }

                let shouldAutoPaste = await MainActor.run(body: { self.autoPasteEnabled })
                guard shouldAutoPaste else {
                    await MainActor.run {
                        if let translationFailedMessage {
                            self.setStatus(
                                "Transcrição concluída. Tradução falhou: \(translationFailedMessage)",
                                isError: true
                            )
                        } else {
                            self.setStatus(
                                translationRequested ? "Transcrição e tradução concluídas." : "Transcrição concluída.",
                                isError: false
                            )
                        }
                    }
                    return
                }

                let hasPermission = autoPaster.hasAccessibilityPermission
                await MainActor.run {
                    self.hasAccessibilityPermission = hasPermission
                }

                if hasPermission {
                    do {
                        try autoPaster.paste(text: outputText)
                        await MainActor.run {
                            if let translationFailedMessage {
                                self.setStatus(
                                    "Transcrição colada. Tradução falhou: \(translationFailedMessage)",
                                    isError: true
                                )
                            } else {
                                self.setStatus(
                                    translationRequested
                                        ? "Transcrição traduzida e colada no campo ativo."
                                        : "Transcrição colada no campo ativo.",
                                    isError: false
                                )
                            }
                        }
                    } catch {
                        await MainActor.run {
                            let baseMessage: String
                            if let translationFailedMessage {
                                baseMessage = "Transcrição pronta. Tradução falhou: \(translationFailedMessage)"
                            } else {
                                baseMessage = translationRequested
                                    ? "Transcrição traduzida pronta."
                                    : "Transcrição pronta."
                            }
                            self.setStatus(
                                "\(baseMessage) \(error.localizedDescription)",
                                isError: true
                            )
                        }
                    }
                } else {
                    await MainActor.run {
                        if let translationFailedMessage {
                            self.setStatus(
                                "Transcrição pronta. Tradução falhou: \(translationFailedMessage)",
                                isError: true
                            )
                        } else {
                            self.setStatus(
                                translationRequested
                                    ? "Tradução pronta, mas falta permissão de Accessibilidade para colar."
                                    : "Transcrição pronta, mas falta permissão de Accessibilidade para colar.",
                                isError: true
                            )
                        }
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.setStatus("Transcrição cancelada.", isError: false)
                }
            } catch {
                await MainActor.run {
                    self.setStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func startAudioMetering() {
        stopAudioMetering()
        audioMeterTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let level = self.recorder.currentAudioLevel()
                self.audioLevel = level
                self.isSpeechDetected = level > 0.12
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func stopAudioMetering() {
        audioMeterTask?.cancel()
        audioMeterTask = nil
        audioLevel = 0
        isSpeechDetected = false
    }

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
        guard let data = UserDefaults.standard.data(forKey: Self.hotkeyDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    private func persistHotkey(_ shortcut: HotkeyShortcut) {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: Self.hotkeyDefaultsKey)
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

    private func currentTranslationRequest() -> TranslationRequest? {
        guard translationEnabled else { return nil }
        return TranslationRequest(
            sourceLanguage: selectedSourceLanguage.translationName,
            targetLanguage: selectedTargetLanguage.translationName
        )
    }

    private func transcriptionLanguageHint() -> String? {
        return selectedSourceLanguage.isoCode
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

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        isStatusError = isError
    }

    private struct TranslationRequest {
        let sourceLanguage: String
        let targetLanguage: String
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

private enum VoicePasteError: LocalizedError {
    case missingAPIKey
    case emptyTranscription

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key não encontrada."
        case .emptyTranscription:
            return "Não foi possível gerar texto da gravação."
        }
    }
}
