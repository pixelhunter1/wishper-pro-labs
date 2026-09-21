import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

enum RecordingPhase: Equatable {
    case idle
    case choosing
    case countdown(Int)
    case recording(since: Date)
    case saving
    case saved(URL)
    /// The translated video is being made; the export's progress when it is known.
    case translating(Double?)
    /// The translated video is saved; `missing` phrases stayed without a voice.
    case translated(URL, missing: Int)
    case failed(String)

    var menuTitle: String {
        switch self {
        case .countdown: return "Cancelar gravação"
        case .recording: return "Parar gravação"
        case .saving: return "A guardar…"
        case .translating: return "Cancelar tradução"
        case .idle, .choosing, .saved, .translated, .failed: return "Gravar ecrã…"
        }
    }

    /// The menu item does nothing while the picker is open or the file is being saved.
    var acceptsMenuAction: Bool {
        switch self {
        case .choosing, .saving: return false
        case .idle, .countdown, .recording, .saved, .translating, .translated, .failed: return true
        }
    }

    /// A recording is being prepared, made, saved or translated: its settings wait for the next one.
    var isBusy: Bool {
        switch self {
        case .choosing, .countdown, .recording, .saving, .translating: return true
        case .idle, .saved, .translated, .failed: return false
        }
    }

    /// The bubble shows every phase except idle and choosing (the system picker is up then).
    var showsBubble: Bool {
        switch self {
        case .idle, .choosing: return false
        case .countdown, .recording, .saving, .saved, .translating, .translated, .failed: return true
        }
    }

    /// Control-Command-Esc cancels the countdown or stops the recording, like the menu item.
    var acceptsStopShortcut: Bool {
        switch self {
        case .countdown, .recording: return true
        case .idle, .choosing, .saving, .saved, .translating, .translated, .failed: return false
        }
    }
}

/// "01:23", or "1:02:03" from an hour on.
enum RecordingClock {
    static func text(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3_600
        let minutes = total / 60 % 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%02d:%02d", minutes, rest)
    }
}

struct RecordingInput: Identifiable, Equatable {
    let id: String
    let name: String
}

private enum RecordingDefaultsKey {
    static let microphone = "wishper.recording_microphone"
    static let systemAudio = "wishper.recording_system_audio"
    static let translation = "wishper.recording_translation"
    static let voice = "wishper.recording_voice"
    static let subtitles = "wishper.recording_subtitles"
    static let tone = "wishper.recording_tone"
}

/// What the recording's translation takes from dictation: the API key, the dictionary and the spoken language.
struct TranslationContext {
    var apiKey: String
    var dictionary: [String]
    var source: SupportedLanguage
}

/// Screen recording from the menu: picker → countdown → recording → the file in Finder. Kept apart from
/// VoicePasteViewModel, which stays the source of truth for dictation. ScreenCaptureKit needs macOS 15, so the
/// recorder is kept as `AnyObject` and everything that touches it is behind `#available`.
@MainActor
final class RecordingController: ObservableObject {
    static var isSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var level: Double = 0
    @Published private(set) var elapsed: TimeInterval = 0
    /// Shown under the recording in the bubble (e.g. no microphone access).
    @Published private(set) var notice: String?
    @Published private(set) var microphones: [RecordingInput] = []
    @Published var microphoneID = UserDefaults.standard.string(forKey: RecordingDefaultsKey.microphone) ?? "" {
        didSet { UserDefaults.standard.set(microphoneID, forKey: RecordingDefaultsKey.microphone) }
    }
    @Published var recordsSystemAudio = UserDefaults.standard.bool(forKey: RecordingDefaultsKey.systemAudio) {
        didSet { UserDefaults.standard.set(recordsSystemAudio, forKey: RecordingDefaultsKey.systemAudio) }
    }
    /// `""` records without translating; otherwise a `SupportedLanguage.rawValue`.
    @Published var translationLanguage = UserDefaults.standard.string(forKey: RecordingDefaultsKey.translation) ?? "" {
        didSet { UserDefaults.standard.set(translationLanguage, forKey: RecordingDefaultsKey.translation) }
    }
    @Published var tone = NarrationTone.stored(UserDefaults.standard.string(forKey: RecordingDefaultsKey.tone)) {
        didSet { UserDefaults.standard.set(tone.rawValue, forKey: RecordingDefaultsKey.tone) }
    }
    @Published var voiceID = LiveVoice.stored(UserDefaults.standard.string(forKey: RecordingDefaultsKey.voice)) {
        didSet { UserDefaults.standard.set(voiceID, forKey: RecordingDefaultsKey.voice) }
    }
    @Published var subtitles = SubtitleStyle(rawValue: UserDefaults.standard.string(forKey: RecordingDefaultsKey.subtitles) ?? "") ?? .player {
        didSet { UserDefaults.standard.set(subtitles.rawValue, forKey: RecordingDefaultsKey.subtitles) }
    }

    /// Windows the picker leaves out besides the app's own: the bubble. Set by the AppDelegate.
    var excludedWindowIDs: @MainActor () -> [Int] = { [] }
    /// The translation's API key, dictionary and spoken language; nil without an API key. Set by the AppDelegate.
    var translationContext: @MainActor () -> TranslationContext? = { nil }

    /// The menu's choice: a saved microphone that is not connected shows as the system default.
    var menuMicrophone: String {
        RecordingMicrophone(storedValue: microphoneID, connected: microphones.map(\.id)).storedValue
    }

    private let soundCuePlayer = SoundCuePlayer()
    /// Control-Command-Esc, registered from the countdown until the recording ends.
    private let stopShortcut = GlobalHotkeyMonitor()
    private var recorder: AnyObject?
    private var pickerObserver: AnyObject?
    private var countdown: Task<Void, Never>?
    private var isStarting = false
    private var stopTask: Task<Void, Never>?
    private var clock: Timer?
    private var resetTask: Task<Void, Never>?
    private var deviceObservers: [NSObjectProtocol] = []
    /// This recording's translator and language, from the countdown until the translated video is saved.
    private var translator: RecordingTranslator?
    private var translationTarget: SupportedLanguage?
    private var translationTask: Task<Void, Never>?
    private var translationOriginal: URL?

    init() {
        guard Self.isSupported else { return }
        stopShortcut.onStopRecording = { [weak self] in
            guard let self, self.phase.acceptsStopShortcut else { return }
            self.toggle()
        }
        refreshMicrophones()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            }
            deviceObservers.append(observer)
        }
    }

    /// The menu item: record, cancel the countdown, stop, or cancel the translation, depending on the phase.
    func toggle() {
        switch phase {
        case .idle, .saved, .translated, .failed: choose()
        case .countdown: cancel()
        case .recording: stop()
        case .translating: cancelTranslation()
        case .choosing, .saving: break
        }
    }

    func showRecordings() {
        let folder = RecordingFile.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Quitting: a recording in progress is saved, and a countdown cancelled, before the app goes.
    func finishBeforeQuit() async {
        if #available(macOS 15, *), let recorder = recorder as? ScreenRecorder {
            switch phase {
            case .countdown:
                clearRecording()
                await recorder.cancel()
            case .recording:
                stop()
                await stopTask?.value
            default:
                await stopTask?.value
            }
        } else {
            await stopTask?.value
        }
        // A translation in progress is dropped; the original recording stays and no half-written video is left.
        await stopTranslation()
    }

    private func refreshMicrophones() {
        guard #available(macOS 14, *) else { return }
        microphones = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.map { RecordingInput(id: $0.uniqueID, name: $0.localizedName) }
    }

    private func choose() {
        guard #available(macOS 15, *) else { return }
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay, .singleWindow, .singleApplication]
        // The app leaves itself out, so the bubble never shows in the video (checked on macOS 26).
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap { $0 }
        configuration.excludedWindowIDs = excludedWindowIDs()
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        let observer = PickerObserver(
            onPick: { [weak self] filter in self?.picked(filter) },
            onCancel: { [weak self] in
                guard let self, self.phase == .choosing else { return }
                self.pickerClosed()
                self.setPhase(.idle)
            },
            onFailure: { [weak self] error in
                guard let self, self.phase == .choosing else { return }
                self.pickerClosed()
                self.fail(.startFailed(ScreenRecordingError.reason(error)))
            }
        )
        picker.add(observer)
        pickerObserver = observer
        picker.isActive = true
        setPhase(.choosing)
        picker.present()
    }

    @available(macOS 15, *)
    private func picked(_ filter: SCContentFilter) {
        guard phase == .choosing, !isStarting else { return }
        isStarting = true
        Task {
            await begin(filter)
            isStarting = false
        }
    }

    /// Starts the stream (the microphone warms up during the countdown), then writes from the end of the countdown.
    @available(macOS 15, *)
    private func begin(_ filter: SCContentFilter) async {
        let folder = RecordingFile.folder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            pickerClosed()
            fail(.folderUnavailable)
            return
        }
        var microphone = RecordingMicrophone(storedValue: microphoneID, connected: microphones.map(\.id))
        var notice: String?
        if microphone != .off, !(await microphoneAllowed()) {
            microphone = .off
            notice = "Sem acesso ao microfone: a gravar sem voz."
        }
        let recorder: ScreenRecorder
        do {
            recorder = try ScreenRecorder(
                filter: filter,
                microphone: microphone,
                systemAudio: recordsSystemAudio,
                url: RecordingFile.url(for: Date(), in: folder)
            )
        } catch {
            pickerClosed()
            fail(.startFailed(ScreenRecordingError.reason(error)))
            return
        }
        recorder.onMicrophone = { [weak self] _, level in
            Task { @MainActor in self?.level = level }
        }
        recorder.onEnded = { [weak self] error in
            Task { @MainActor in self?.ended(error) }
        }
        let translator = makeTranslator(microphone: microphone)
        if translator == nil, !translationLanguage.isEmpty, microphone != .off {
            notice = "Sem API key: a gravar sem tradução."
        }
        if let translator {
            recorder.onVoice = { pcm, time in translator.add(pcm, at: time) }
        }
        do {
            try await recorder.start()
        } catch {
            await recorder.cancel()
            await translator?.cancel()
            pickerClosed()
            fail(.startFailed(ScreenRecordingError.reason(error)))
            return
        }
        self.recorder = recorder
        self.translator = translator
        await translator?.start()
        stopShortcut.setStopRecordingEnabled(true)
        soundCuePlayer.playStartCue()
        countdown = Task { [weak self] in
            for second in [3, 2, 1] {
                self?.setPhase(.countdown(second))
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self?.startWriting(notice: notice)
        }
    }

    private func startWriting(notice: String?) {
        guard #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else { return }
        recorder.beginWriting()
        self.notice = notice
        let since = Date()
        elapsed = 0
        setPhase(.recording(since: since))
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = Date().timeIntervalSince(since) }
        }
        // The common modes keep the time running while the menu is open.
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
    }

    /// Closes the file. `reason` is why the stream ended by itself; `nil` when the person stopped it.
    private func stop(reason: Error? = nil) {
        guard #available(macOS 15, *), stopTask == nil, let recorder = recorder as? ScreenRecorder else { return }
        setPhase(.saving)
        clock?.invalidate()
        stopTask = Task { [weak self] in
            do {
                let url = try await recorder.stop()
                self?.finish(url, failure: reason)
            } catch {
                self?.finish(recorder.url, failure: error)
            }
        }
    }

    /// Cancelled during the countdown: nothing is kept.
    private func cancel() {
        guard #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else { return }
        let translator = translator
        self.translator = nil
        clearRecording()
        setPhase(.idle)
        Task {
            await recorder.cancel()
            await translator?.cancel()
        }
    }

    /// The stream ended by itself (stopped from the system's menu, the recorded window or app closed, or a write
    /// failed). The file is closed here, through `stop(reason:)`, or dropped during the countdown.
    private func ended(_ error: Error?) {
        guard #available(macOS 15, *), stopTask == nil, let recorder = recorder as? ScreenRecorder else { return }
        switch phase {
        case .countdown:
            // Nothing was written yet.
            let translator = translator
            self.translator = nil
            clearRecording()
            Task {
                await recorder.cancel()
                await translator?.cancel()
            }
            if let error {
                fail(.startFailed(ScreenRecordingError.reason(error)))
            } else {
                setPhase(.idle)
            }
        case .recording:
            stop(reason: error)
        default:
            break
        }
    }

    /// The file is closed: translated when asked, or shown in Finder with "Gravação guardada" or why it stopped.
    private func finish(_ url: URL, failure: Error?) {
        if #available(macOS 15, *), let recorder = recorder as? ScreenRecorder {
            DiagnosticLog.write("gravação: \(recorder.voiceBlocks) blocos de voz, perdidos \(recorder.voiceDrops.summary)")
        }
        clearRecording()
        soundCuePlayer.playStopCue()
        if #available(macOS 15, *), let translator, let target = translationTarget,
           FileManager.default.fileExists(atPath: url.path) {
            translate(url, with: translator, into: target, interruption: failure)
            return
        }
        // Nothing to translate (no file): the translator started with the recording, so it stops here.
        if let translator {
            self.translator = nil
            Task { await translator.cancel() }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        if let failure {
            fail(.interrupted(ScreenRecordingError.reason(failure)))
        } else {
            setPhase(.saved(url))
        }
    }

    /// A translator for this recording: when a language is chosen, the microphone is on and there is an API key.
    private func makeTranslator(microphone: RecordingMicrophone) -> RecordingTranslator? {
        guard let target = SupportedLanguage(rawValue: translationLanguage), microphone != .off,
              let context = translationContext()
        else { return nil }
        translationTarget = target
        return RecordingTranslator(steps: .live(
            apiKey: context.apiKey,
            source: context.source,
            target: target,
            dictionary: context.dictionary,
            voice: voiceID,
            tone: tone
        ))
    }

    /// After the original is saved: the last phrases, one more try for what failed, then the translated video next to
    /// the original, shown in Finder. The original stays whatever happens.
    @available(macOS 15, *)
    private func translate(_ original: URL, with translator: RecordingTranslator, into target: SupportedLanguage, interruption: Error?) {
        setPhase(.translating(nil))
        translationOriginal = original
        // A recording that stopped by itself is still translated; the bubble says why it stopped.
        notice = interruption.map { ScreenRecordingError.interrupted(ScreenRecordingError.reason($0)).localizedDescription }
        let subtitles = subtitles
        translationTask = Task { [weak self] in
            let result = await translator.finish()
            guard !Task.isCancelled, let self else { return }
            DiagnosticLog.write(
                "tradução: \(result.phrases.count) frases, \(result.failed) falhadas"
                    + (result.firstError.map { ", primeiro erro: \($0)" } ?? "")
            )
            defer {
                self.translator = nil
                self.translationTask = nil
                self.translationOriginal = nil
                self.notice = nil
            }
            guard !result.phrases.isEmpty else {
                NSWorkspace.shared.activateFileViewerSelecting([original])
                let error = result.firstError.map { ScreenRecordingError.translationFailed(ScreenRecordingError.reason($0)) }
                self.fail(error ?? .nothingToTranslate)
                return
            }
            let output = RecordingFile.translatedURL(for: original, language: target)
            do {
                try await TranslatedVideoExporter.export(original: original, phrases: result.phrases, subtitles: subtitles, to: output) { [weak self] value in
                    Task { @MainActor in
                        if case .translating = self?.phase { self?.phase = .translating(value) }
                    }
                }
                guard !Task.isCancelled else { return }
                NSWorkspace.shared.activateFileViewerSelecting([output])
                self.setPhase(.translated(output, missing: result.failed))
            } catch {
                guard !Task.isCancelled else { return }
                NSWorkspace.shared.activateFileViewerSelecting([original])
                self.fail(.exportFailed(ScreenRecordingError.reason(error)))
            }
        }
    }

    /// Stops a translation in progress and waits until it has: its task is cancelled first (its own calls stop), then
    /// the translator (its worker and the GPT-Live session), then the task is awaited so the exporter cleans up.
    private func stopTranslation() async {
        let task = translationTask
        let translator = translator
        task?.cancel()
        await translator?.cancel()
        await task?.value
        translationTask = nil
        self.translator = nil
        translationOriginal = nil
    }

    /// "Cancelar tradução": the translation stops, the original stays and Finder shows it. Until the translation has
    /// stopped the phase is "A guardar…", so a new recording can't start on top of it.
    private func cancelTranslation() {
        let original = translationOriginal
        setPhase(.saving)
        notice = nil
        Task { [weak self] in
            await self?.stopTranslation()
            guard let self else { return }
            if let original {
                NSWorkspace.shared.activateFileViewerSelecting([original])
                self.setPhase(.saved(original))
            } else {
                self.setPhase(.idle)
            }
        }
    }

    private func clearRecording() {
        recorder = nil
        stopTask = nil
        countdown?.cancel()
        countdown = nil
        clock?.invalidate()
        clock = nil
        level = 0
        elapsed = 0
        notice = nil
        stopShortcut.setStopRecordingEnabled(false)
        pickerClosed()
    }

    private func pickerClosed() {
        guard #available(macOS 15, *), let observer = pickerObserver as? PickerObserver else { return }
        SCContentSharingPicker.shared.remove(observer)
        SCContentSharingPicker.shared.isActive = false
        pickerObserver = nil
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func fail(_ error: ScreenRecordingError) {
        DiagnosticLog.write("erro: \(error.localizedDescription)")
        setPhase(.failed(error.localizedDescription))
    }

    /// `saved` stays visible for 2 s, `translated` for 3 s (4 s with missing phrases) and `failed` for 4 s, then the
    /// phase returns to idle.
    private func setPhase(_ newPhase: RecordingPhase) {
        phase = newPhase
        resetTask?.cancel()
        let visibleFor: Duration
        switch newPhase {
        case .saved: visibleFor = .seconds(2)
        case .translated(_, let missing): visibleFor = .seconds(missing > 0 ? 4 : 3)
        case .failed: visibleFor = .seconds(4)
        default: return
        }
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: visibleFor)
            guard !Task.isCancelled, let self, self.phase == newPhase else { return }
            self.phase = .idle
        }
    }
}

/// Hands the system picker's answer to the main actor.
@available(macOS 15, *)
private final class PickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let onPick: @MainActor (SCContentFilter) -> Void
    private let onCancel: @MainActor () -> Void
    private let onFailure: @MainActor (Error) -> Void

    init(
        onPick: @escaping @MainActor (SCContentFilter) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.onPick = onPick
        self.onCancel = onCancel
        self.onFailure = onFailure
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in self.onPick(filter) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.onCancel() }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.onFailure(error) }
    }
}
