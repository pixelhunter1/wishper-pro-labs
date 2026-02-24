import AppKit
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
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var isSpeechDetected = false
    @Published private(set) var isAPIKeySaved = false
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hotkeyLabel = "Option + Space"
    @Published private(set) var isHotkeyReady = false

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
    private let autoPaster = AutoPaster()
    private let hotkeyMonitor = GlobalHotkeyMonitor()
    private let soundCuePlayer = SoundCuePlayer()
    private var transcriptionTask: Task<Void, Never>?
    private var audioMeterTask: Task<Void, Never>?
    private var activeAPIKey: String?

    init() {
        if let savedKey = keychain.loadAPIKey(), !savedKey.isEmpty {
            apiKeyDraft = savedKey
            isAPIKeySaved = true
            activeAPIKey = savedKey
        }

        hasAccessibilityPermission = autoPaster.hasAccessibilityPermission

        let result = hotkeyMonitor.start { [weak self] in
            guard let self else { return }
            Task {
                await self.toggleRecording(origin: .hotkey)
            }
        }

        switch result {
        case .registered(let shortcutLabel):
            hotkeyLabel = shortcutLabel
            isHotkeyReady = true
        case .failed(let message):
            isHotkeyReady = false
            setStatus("\(message) Usa o botão Iniciar Ditado.", isError: true)
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

    func cancelTranscription() {
        guard isTranscribing else { return }
        transcriptionTask?.cancel()
        transcriptionTask = nil
        isTranscribing = false
        setStatus("Transcrição cancelada.", isError: false)
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
            soundCuePlayer.playStartCue()
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

                let transcript = try await self.transcriptionClient.transcribeAudio(
                    fileURL: recordingURL,
                    apiKey: apiKey,
                    timeoutSeconds: 30
                )
                try Task.checkCancellation()

                let cleanTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanTranscript.isEmpty else {
                    throw VoicePasteError.emptyTranscription
                }

                await MainActor.run {
                    self.lastTranscript = cleanTranscript
                }

                let shouldAutoPaste = await MainActor.run(body: { self.autoPasteEnabled })
                guard shouldAutoPaste else {
                    await MainActor.run {
                        self.setStatus("Transcrição concluída.", isError: false)
                    }
                    return
                }

                let hasPermission = autoPaster.hasAccessibilityPermission
                await MainActor.run {
                    self.hasAccessibilityPermission = hasPermission
                }

                if hasPermission {
                    try autoPaster.paste(text: cleanTranscript)
                    await MainActor.run {
                        self.setStatus("Transcrição colada no campo ativo.", isError: false)
                    }
                } else {
                    await MainActor.run {
                        self.setStatus(
                            "Transcrição pronta, mas falta permissão de Accessibilidade para colar.",
                            isError: true
                        )
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

    private func setStatus(_ message: String, isError: Bool) {
        statusMessage = message
        isStatusError = isError
    }

    private enum TriggerOrigin {
        case button
        case hotkey
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
