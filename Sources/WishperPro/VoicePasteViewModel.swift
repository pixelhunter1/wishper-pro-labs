import AppKit
import AVFoundation
import Carbon
import Foundation
import SwiftUI

@MainActor
final class VoicePasteViewModel: ObservableObject {
    @Published var apiKeyDraft: String = ""
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var autoPasteEnabled = true
    @Published var statusMessage = "Pronto para ditar."
    @Published var isStatusError = false
    @Published var lastTranscript = ""
    @Published private(set) var lastTranscriptionDiagnostics = "Sem métricas de transcrição ainda."
    @Published private(set) var transcriptionDiagnosticsHistory: [String] = []
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var isSpeechDetected = false
    @Published private(set) var isAPIKeySaved = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hotkeyLabel = "Option + Space"
    @Published private(set) var isHotkeyReady = false
    @Published private(set) var isCapturingHotkey = false
    @Published var selectedTranscriptionModel: TranscriptionModel = .gpt4oMiniTranscribe
    @Published var translationEnabled = false
    @Published var selectedSourceLanguage: SupportedLanguage = .auto
    @Published var selectedTargetLanguage: SupportedLanguage = .english
    @Published var selectedTTSVoice: TTSVoice = .alloy
    @Published var selectedTTSModel: TTSModel = .gpt4oMiniTTS
    @Published var selectedPortugueseVariant: PortugueseVariant = .portugal
    @Published var selectedStartCueSound: RecordingCueSound = .pop
    @Published var selectedStopCueSound: RecordingCueSound = .tink
    @Published private(set) var isSpeaking = false
    @Published private(set) var isLoadingTTS = false

    var keyStatusText: String {
        isAPIKeySaved
            ? "API key guardada localmente no Keychain."
            : "Nenhuma API key guardada."
    }

    var accessibilityStatusText: String {
        hasAccessibilityPermission
            ? "Permissão de Accessibilidade ativa."
            : "Sem permissão de Accessibilidade."
    }

    var isActionDisabled: Bool {
        isTranscribing || (!isRecording && !isAPIKeySaved)
    }

    var hotkeyCaptureHint: String {
        isCapturingHotkey
            ? "Pressiona agora a combinação desejada (Esc para cancelar)."
            : "Define qualquer combinação diretamente pelo teclado."
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

    var modelStatusText: String {
        "Modelo ativo: \(selectedTranscriptionModel.displayName)"
    }

    var translationStatusText: String {
        guard translationEnabled else {
            return "Tradução desativada."
        }
        return "Traduzir de \(languageDisplayName(selectedSourceLanguage)) para \(languageDisplayName(selectedTargetLanguage))."
    }

    var ttsStatusText: String {
        "Voz ativa: \(selectedTTSVoice.displayName) (\(selectedTTSModel.subtitle), \(selectedPortugueseVariant.displayName))"
    }

    var recordingCueStatusText: String {
        "Início: \(selectedStartCueSound.displayName) | Fim: \(selectedStopCueSound.displayName)"
    }

    var availableTTSVoices: [TTSVoice] {
        TTSVoice.allCases
    }

    var availableRecordingCueSounds: [RecordingCueSound] {
        RecordingCueSound.allCases
    }

    var ttsCompatibilityHint: String? {
        let supportedVoices = selectedTTSModel.supportedVoices
        guard supportedVoices.count < TTSVoice.allCases.count else { return nil }
        return "Este modelo mostra todas as vozes, mas só suporta \(supportedVoices.count)."
    }

    private let keychain = KeychainService()
    private let recorder = AudioRecorder()
    private let transcriptionClient = OpenAITranscriptionClient()
    private let translationClient = OpenAITranslationClient()
    private let ttsClient = OpenAITTSClient()
    private let autoPaster = AutoPaster()
    private let hotkeyMonitor = GlobalHotkeyMonitor()
    private let soundCuePlayer = SoundCuePlayer()
    private var transcriptionTask: Task<Void, Never>?
    private var audioMeterTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var activeAPIKey: String?
    private var activeShortcut: HotkeyShortcut = .default
    private var localCaptureMonitor: Any?
    private var globalCaptureMonitor: Any?
    private var hotkeySuspendedForCapture = false
    private static let hotkeyDefaultsKey = "wishper.push_to_talk_hotkey_data"
    private static let transcriptionModelDefaultsKey = "wishper.transcription_model"
    private static let translationEnabledDefaultsKey = "wishper.translation_enabled"
    private static let translationSourceDefaultsKey = "wishper.translation_source_language"
    private static let translationTargetDefaultsKey = "wishper.translation_target_language"
    private static let ttsVoiceDefaultsKey = "wishper.tts_voice"
    private static let ttsModelDefaultsKey = "wishper.tts_model"
    private static let portugueseVariantDefaultsKey = "wishper.portuguese_variant"
    private static let startCueSoundDefaultsKey = "wishper.start_cue_sound"
    private static let stopCueSoundDefaultsKey = "wishper.stop_cue_sound"
    private static let transcriptionTimeoutSeconds: TimeInterval = 30
    private static let transcriptionMaxRetries = 0

    init() {
        if let savedKey = keychain.loadAPIKey(), !savedKey.isEmpty {
            apiKeyDraft = savedKey
            isAPIKeySaved = true
            activeAPIKey = savedKey
        }

        hasAccessibilityPermission = autoPaster.hasAccessibilityPermission
        loadPersistedSettings()

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

    func onTranscriptionModelChanged() {
        persistTranscriptionModel(selectedTranscriptionModel.rawValue)
    }

    func onTranslationSettingsChanged() {
        persistTranslationSettings()
    }

    func onPortugueseVariantChanged() {
        onTTSSettingsChanged()
        persistTranslationSettings()
    }

    func onTTSVoiceChanged() {
        if !selectedTTSModel.supportedVoices.contains(selectedTTSVoice) {
            selectedTTSModel = .gpt4oMiniTTS
            setStatus(
                "Voz \(selectedTTSVoice.displayName) requer modelo avançado. Alterado para GPT-4o Mini TTS.",
                isError: false
            )
        }
        onTTSSettingsChanged()
    }

    func onTTSModelChanged() {
        onTTSSettingsChanged()
    }

    func onRecordingCueSettingsChanged() {
        UserDefaults.standard.set(selectedStartCueSound.rawValue, forKey: Self.startCueSoundDefaultsKey)
        UserDefaults.standard.set(selectedStopCueSound.rawValue, forKey: Self.stopCueSoundDefaultsKey)
    }

    func pasteAPIKeyFromClipboard() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            setStatus("A área de transferência está vazia.", isError: true)
            return
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            setStatus("Não foi encontrado texto válido para colar.", isError: true)
            return
        }

        apiKeyDraft = trimmed
        setStatus("API key colada. Agora clica em Guardar Key.", isError: false)
    }

    func requestAccessibilityPermission() {
        hasAccessibilityPermission = autoPaster.requestAccessibilityPermission()
        if hasAccessibilityPermission {
            setStatus("Permissão de Accessibilidade ativa.", isError: false)
        } else {
            setStatus(
                "Ativa em Definições do Sistema > Privacidade e Segurança > Acessibilidade.",
                isError: true
            )
        }
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

    func speakText(_ text: String) {
        stopSpeaking()
        guard let apiKey = activeAPIKey, !apiKey.isEmpty else {
            setStatus("Guarda a API key para usar a voz.", isError: true)
            return
        }
        normalizeTTSSelection()
        let voice = selectedTTSVoice
        let model = selectedTTSModel
        let portugueseVariant = selectedPortugueseVariant
        isLoadingTTS = true
        ttsTask = Task { [weak self] in
            guard let self else { return }
            do {
                let speechText = await self.speechTextForTTS(
                    from: text,
                    apiKey: apiKey,
                    portugueseVariant: portugueseVariant
                )
                let audioData = try await self.ttsClient.synthesize(
                    text: speechText,
                    apiKey: apiKey,
                    voice: voice,
                    model: model
                )
                try Task.checkCancellation()
                let player = try AVAudioPlayer(data: audioData)
                await MainActor.run {
                    self.audioPlayer = player
                    self.isLoadingTTS = false
                    self.isSpeaking = true
                }
                player.play()
                while player.isPlaying {
                    try await Task.sleep(for: .milliseconds(200))
                }
                await MainActor.run {
                    self.isSpeaking = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    self.isLoadingTTS = false
                    self.isSpeaking = false
                }
            } catch {
                await MainActor.run {
                    self.isLoadingTTS = false
                    self.isSpeaking = false
                    self.setStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    func previewTTSVoice(_ voice: TTSVoice) {
        speakText(voice.previewText(for: selectedPortugueseVariant))
    }

    func stopSpeaking() {
        ttsTask?.cancel()
        ttsTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isLoadingTTS = false
        isSpeaking = false
    }

    func onTTSSettingsChanged() {
        normalizeTTSSelection()
        UserDefaults.standard.set(selectedTTSVoice.rawValue, forKey: Self.ttsVoiceDefaultsKey)
        UserDefaults.standard.set(selectedTTSModel.rawValue, forKey: Self.ttsModelDefaultsKey)
        UserDefaults.standard.set(selectedPortugueseVariant.rawValue, forKey: Self.portugueseVariantDefaultsKey)
    }

    func toggleRecordingFromButton() {
        Task {
            await toggleRecording(origin: .button)
        }
    }

    private func toggleRecording(origin: TriggerOrigin) async {
        if isTranscribing {
            return
        }

        if isRecording {
            await stopAndTranscribe()
        } else {
            await startRecording(origin: origin)
        }
    }

    private func startRecording(origin: TriggerOrigin) async {
        guard let savedKey = activeAPIKey, !savedKey.isEmpty else {
            isAPIKeySaved = false
            setStatus("Guarda a API key antes de iniciar o ditado.", isError: true)
            return
        }
        isAPIKeySaved = true

        let microphoneGranted = await Permissions.requestMicrophoneAccess()
        guard microphoneGranted else {
            setStatus("Permissão de microfone negada.", isError: true)
            return
        }

        do {
            try recorder.start()
            isRecording = true
            lastTranscript = ""
            startAudioMetering()
            soundCuePlayer.playStartCue(selectedStartCueSound)
            let message: String
            switch origin {
            case .hotkey:
                message = "A gravar. Usa \(hotkeyLabel) para parar."
            case .button:
                message = isHotkeyReady
                    ? "A gravar. Usa \(hotkeyLabel) ou o botão para parar."
                    : "A gravar. Clica novamente para parar."
            }
            setStatus(message, isError: false)
        } catch {
            stopAudioMetering()
            setStatus(error.localizedDescription, isError: true)
        }
    }

    private func stopAndTranscribe() async {
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
        soundCuePlayer.playStopCue(selectedStopCueSound)
        isTranscribing = true
        setStatus("A transcrever áudio...", isError: false)
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            let pipelineStartTime = Date()
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

                let model = await MainActor.run(body: { self.selectedTranscriptionModel.rawValue })
                let languageHint = await MainActor.run(body: { self.transcriptionLanguageHint() })
                let transcriptionResult = try await self.transcriptionClient.transcribeAudio(
                    fileURL: recordingURL,
                    apiKey: apiKey,
                    model: model,
                    languageHint: languageHint,
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
                var translationElapsedSeconds: TimeInterval?
                let translationRequest = await MainActor.run(body: { self.currentTranslationRequest() })
                if let translationRequest {
                    translationRequested = true
                    await MainActor.run {
                        self.setStatus("A traduzir para \(translationRequest.targetLanguage)...", isError: false)
                    }

                    let translationStartTime = Date()
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
                    translationElapsedSeconds = Date().timeIntervalSince(translationStartTime)
                }

                let pipelineElapsedSeconds = Date().timeIntervalSince(pipelineStartTime)
                let diagnosticsSummary = await MainActor.run {
                    self.buildTranscriptionDiagnostics(
                        transcriptionMetrics: transcriptionResult.metrics,
                        pipelineElapsedSeconds: pipelineElapsedSeconds,
                        translationElapsedSeconds: translationElapsedSeconds,
                        translationRequested: translationRequested,
                        translationFailed: translationFailedMessage != nil
                    )
                }

                await MainActor.run {
                    self.lastTranscript = outputText
                    self.lastTranscriptionDiagnostics = diagnosticsSummary
                    self.pushTranscriptionDiagnosticsHistory(diagnosticsSummary)
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
                    self.lastTranscriptionDiagnostics = "Transcrição cancelada."
                    self.pushTranscriptionDiagnosticsHistory("Transcrição cancelada.")
                    self.setStatus("Transcrição cancelada.", isError: false)
                }
            } catch {
                let pipelineElapsedSeconds = Date().timeIntervalSince(pipelineStartTime)
                await MainActor.run {
                    let diagnostics = "Falhou após \(self.formatDurationSeconds(pipelineElapsedSeconds)): \(error.localizedDescription)"
                    self.lastTranscriptionDiagnostics = diagnostics
                    self.pushTranscriptionDiagnosticsHistory(diagnostics)
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
        hotkeyMonitor.start(shortcut: shortcut) { [weak self] in
            guard let self else { return }
            Task {
                await self.toggleRecording(origin: .hotkey)
            }
        }
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

    private func loadPersistedSettings() {
        if let modelRaw = UserDefaults.standard.string(forKey: Self.transcriptionModelDefaultsKey),
           let model = TranscriptionModel(rawValue: modelRaw) {
            selectedTranscriptionModel = model
        }

        if UserDefaults.standard.object(forKey: Self.translationEnabledDefaultsKey) != nil {
            translationEnabled = UserDefaults.standard.bool(forKey: Self.translationEnabledDefaultsKey)
        }

        if let sourceRaw = UserDefaults.standard.string(forKey: Self.translationSourceDefaultsKey),
           let source = SupportedLanguage(rawValue: sourceRaw) {
            selectedSourceLanguage = source
        }

        if let targetRaw = UserDefaults.standard.string(forKey: Self.translationTargetDefaultsKey),
           let target = SupportedLanguage(rawValue: targetRaw) {
            selectedTargetLanguage = target
        }

        if let voiceRaw = UserDefaults.standard.string(forKey: Self.ttsVoiceDefaultsKey),
           let voice = TTSVoice(rawValue: voiceRaw) {
            selectedTTSVoice = voice
        }

        if let modelRaw = UserDefaults.standard.string(forKey: Self.ttsModelDefaultsKey),
           let model = TTSModel(rawValue: modelRaw) {
            selectedTTSModel = model
        }

        if let variantRaw = UserDefaults.standard.string(forKey: Self.portugueseVariantDefaultsKey),
           let variant = PortugueseVariant(rawValue: variantRaw) {
            selectedPortugueseVariant = variant
        }

        if let startCueRaw = UserDefaults.standard.string(forKey: Self.startCueSoundDefaultsKey),
           let startCue = RecordingCueSound(rawValue: startCueRaw) {
            selectedStartCueSound = startCue
        }

        if let stopCueRaw = UserDefaults.standard.string(forKey: Self.stopCueSoundDefaultsKey),
           let stopCue = RecordingCueSound(rawValue: stopCueRaw) {
            selectedStopCueSound = stopCue
        }

        normalizeTTSSelection()
    }

    private func persistTranscriptionModel(_ model: String) {
        UserDefaults.standard.set(model, forKey: Self.transcriptionModelDefaultsKey)
    }

    private func persistTranslationSettings() {
        UserDefaults.standard.set(translationEnabled, forKey: Self.translationEnabledDefaultsKey)
        UserDefaults.standard.set(selectedSourceLanguage.rawValue, forKey: Self.translationSourceDefaultsKey)
        UserDefaults.standard.set(selectedTargetLanguage.rawValue, forKey: Self.translationTargetDefaultsKey)
    }

    private func currentTranslationRequest() -> TranslationRequest? {
        guard translationEnabled else { return nil }
        return TranslationRequest(
            sourceLanguage: languageDisplayName(selectedSourceLanguage),
            targetLanguage: languageDisplayName(selectedTargetLanguage)
        )
    }

    private func transcriptionLanguageHint() -> String? {
        if selectedSourceLanguage == .portuguese {
            return selectedPortugueseVariant.transcriptionLanguageHint
        }
        return selectedSourceLanguage.isoCode
    }

    private func languageDisplayName(_ language: SupportedLanguage) -> String {
        if language == .portuguese {
            return selectedPortugueseVariant.translationDisplayName
        }
        return language.displayName
    }

    private func speechTextForTTS(
        from text: String,
        apiKey: String,
        portugueseVariant: PortugueseVariant
    ) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        guard shouldNormalizePortugueseForSpeech(trimmed) else {
            return trimmed
        }

        do {
            return try await translationClient.translate(
                text: trimmed,
                sourceLanguage: "Português",
                targetLanguage: portugueseVariant.translationDisplayName,
                apiKey: apiKey
            )
        } catch {
            return trimmed
        }
    }

    private func shouldNormalizePortugueseForSpeech(_ text: String) -> Bool {
        if selectedSourceLanguage == .portuguese { return true }
        if translationEnabled && selectedTargetLanguage == .portuguese { return true }
        return Self.looksLikePortuguese(text)
    }

    private static func looksLikePortuguese(_ text: String) -> Bool {
        let normalized = " \(text.lowercased()) "
        let markers = [" não ", " que ", " para ", " com ", " uma ", " está ", "ção", "ções", "ões", "lh", "nh"]
        let hitCount = markers.reduce(0) { partialResult, marker in
            partialResult + (normalized.contains(marker) ? 1 : 0)
        }
        return hitCount >= 2
    }

    private func normalizeTTSSelection() {
        let supportedVoices = selectedTTSModel.supportedVoices
        guard !supportedVoices.isEmpty else { return }
        if !supportedVoices.contains(selectedTTSVoice), let fallbackVoice = supportedVoices.first {
            selectedTTSVoice = fallbackVoice
        }
    }

    private func buildTranscriptionDiagnostics(
        transcriptionMetrics: OpenAITranscriptionMetrics,
        pipelineElapsedSeconds: TimeInterval,
        translationElapsedSeconds: TimeInterval?,
        translationRequested: Bool,
        translationFailed: Bool
    ) -> String {
        var parts: [String] = [
            "transcrição \(formatDurationSeconds(transcriptionMetrics.totalElapsedSeconds))",
            "total \(formatDurationSeconds(pipelineElapsedSeconds))",
            "tamanho \(Self.byteCountFormatter.string(fromByteCount: Int64(transcriptionMetrics.audioBytes)))",
            "modelo \(transcriptionMetrics.model)",
            "tentativas \(transcriptionMetrics.attempts.count)",
        ]

        if let audioDurationSeconds = transcriptionMetrics.audioDurationSeconds {
            parts.append("áudio \(formatDurationSeconds(audioDurationSeconds))")
        }

        if let languageHint = transcriptionMetrics.languageHint, !languageHint.isEmpty {
            parts.append("língua \(languageHint)")
        }

        if transcriptionMetrics.attempts.count > 1 {
            let retryReasons = transcriptionMetrics.attempts
                .dropLast()
                .compactMap(\.failureReason)
            if !retryReasons.isEmpty {
                parts.append("retry \(retryReasons.joined(separator: ","))")
            }
        }

        if let finalAttempt = transcriptionMetrics.attempts.last,
           let openAIProcessingMilliseconds = finalAttempt.openAIProcessingMilliseconds {
            parts.append("OpenAI \(openAIProcessingMilliseconds)ms")
        }

        if translationRequested {
            if let translationElapsedSeconds {
                let prefix = translationFailed ? "tradução falhou em" : "tradução"
                parts.append("\(prefix) \(formatDurationSeconds(translationElapsedSeconds))")
            } else {
                parts.append(translationFailed ? "tradução falhou" : "tradução ativa")
            }
        }

        return parts.joined(separator: " | ")
    }

    private func formatDurationSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else {
            return "n/a"
        }

        if seconds >= 10 {
            return String(format: "%.0fs", seconds)
        }

        return String(format: "%.1fs", seconds)
    }

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter
    }()

    private func pushTranscriptionDiagnosticsHistory(_ diagnostics: String) {
        let timestamp = Self.diagnosticsTimestampFormatter.string(from: Date())
        transcriptionDiagnosticsHistory.insert("[\(timestamp)] \(diagnostics)", at: 0)
        if transcriptionDiagnosticsHistory.count > 8 {
            transcriptionDiagnosticsHistory.removeLast(transcriptionDiagnosticsHistory.count - 8)
        }
    }

    private static let diagnosticsTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_PT")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        isStatusError = isError
    }


    private struct TranslationRequest {
        let sourceLanguage: String
        let targetLanguage: String
    }

    private enum TriggerOrigin {
        case button
        case hotkey
    }
}

enum PortugueseVariant: String, CaseIterable, Identifiable {
    case portugal = "pt-PT"
    case brazil = "pt-BR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .portugal: return "Português (Portugal)"
        case .brazil: return "Português (Brasil)"
        }
    }

    var translationDisplayName: String {
        switch self {
        case .portugal: return "Português de Portugal"
        case .brazil: return "Português do Brasil"
        }
    }

    var transcriptionLanguageHint: String {
        "pt"
    }
}

enum SupportedLanguage: String, CaseIterable, Identifiable {
    case auto
    case portuguese = "pt"
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .portuguese: return "Português"
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
        default: return rawValue
        }
    }

    static var targetLanguages: [SupportedLanguage] {
        allCases.filter { $0 != .auto }
    }
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case gpt4oTranscribe = "gpt-4o-transcribe"
    case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
    case whisper1 = "whisper-1"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gpt4oTranscribe: return "GPT-4o Transcribe"
        case .gpt4oMiniTranscribe: return "GPT-4o Mini Transcribe"
        case .whisper1: return "Whisper-1 (legacy)"
        }
    }

    var subtitle: String {
        switch self {
        case .gpt4oTranscribe: return "Melhor qualidade"
        case .gpt4oMiniTranscribe: return "Mais rápido, mais económico"
        case .whisper1: return "Modelo clássico"
        }
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
