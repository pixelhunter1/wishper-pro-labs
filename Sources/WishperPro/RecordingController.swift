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
    case failed(String)

    var menuTitle: String {
        switch self {
        case .countdown: return "Cancelar gravação"
        case .recording: return "Parar gravação"
        case .saving: return "A guardar…"
        case .idle, .choosing, .saved, .failed: return "Gravar ecrã…"
        }
    }

    /// The menu item does nothing while the picker is open or the file is being saved.
    var acceptsMenuAction: Bool {
        switch self {
        case .choosing, .saving: return false
        case .idle, .countdown, .recording, .saved, .failed: return true
        }
    }

    /// A recording is being prepared, made or saved: the microphone and sound settings wait for the next one.
    var isBusy: Bool {
        switch self {
        case .choosing, .countdown, .recording, .saving: return true
        case .idle, .saved, .failed: return false
        }
    }

    /// The bubble shows every phase except idle and choosing (the system picker is up then).
    var showsBubble: Bool {
        switch self {
        case .idle, .choosing: return false
        case .countdown, .recording, .saving, .saved, .failed: return true
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

    /// Windows the picker leaves out besides the app's own: the bubble. Set by the AppDelegate.
    var excludedWindowIDs: @MainActor () -> [Int] = { [] }

    /// The menu's choice: a saved microphone that is not connected shows as the system default.
    var menuMicrophone: String {
        RecordingMicrophone(storedValue: microphoneID, connected: microphones.map(\.id)).storedValue
    }

    private let soundCuePlayer = SoundCuePlayer()
    private var recorder: AnyObject?
    private var pickerObserver: AnyObject?
    private var countdown: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var clock: Timer?
    private var resetTask: Task<Void, Never>?
    private var deviceObservers: [NSObjectProtocol] = []

    init() {
        guard Self.isSupported else { return }
        refreshMicrophones()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            }
            deviceObservers.append(observer)
        }
    }

    /// The menu item: record, cancel the countdown or stop, depending on the phase.
    func toggle() {
        switch phase {
        case .idle, .saved, .failed: choose()
        case .countdown: cancel()
        case .recording: stop()
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
        guard #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else {
            await stopTask?.value
            return
        }
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
                self?.pickerClosed()
                self?.setPhase(.idle)
            },
            onFailure: { [weak self] error in
                self?.pickerClosed()
                self?.fail(.startFailed(ScreenRecordingError.reason(error)))
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
        guard phase == .choosing else { return }
        Task { await begin(filter) }
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
        do {
            try await recorder.start()
        } catch {
            await recorder.cancel()
            pickerClosed()
            fail(.startFailed(ScreenRecordingError.reason(error)))
            return
        }
        self.recorder = recorder
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

    private func stop() {
        guard #available(macOS 15, *), stopTask == nil, let recorder = recorder as? ScreenRecorder else { return }
        setPhase(.saving)
        clock?.invalidate()
        stopTask = Task { [weak self] in
            do {
                let url = try await recorder.stop()
                self?.finish(url, failure: nil)
            } catch {
                self?.finish(recorder.url, failure: error)
            }
        }
    }

    /// Cancelled during the countdown: nothing is kept.
    private func cancel() {
        guard #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else { return }
        clearRecording()
        setPhase(.idle)
        Task { await recorder.cancel() }
    }

    /// The stream ended by itself (the person stopped it from the system's menu, or it failed).
    private func ended(_ error: Error?) {
        guard #available(macOS 15, *), stopTask == nil, let recorder = recorder as? ScreenRecorder else { return }
        switch phase {
        case .countdown:
            // Nothing was written yet.
            clearRecording()
            if let error {
                fail(.startFailed(ScreenRecordingError.reason(error)))
            } else {
                setPhase(.idle)
            }
        case .recording:
            finish(recorder.url, failure: error)
        default:
            break
        }
    }

    /// The file is closed: shown in Finder, then "Gravação guardada" or why the recording stopped.
    private func finish(_ url: URL, failure: Error?) {
        clearRecording()
        soundCuePlayer.playStopCue()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        if let failure {
            fail(.interrupted(ScreenRecordingError.reason(failure)))
        } else {
            setPhase(.saved(url))
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
        setPhase(.failed(error.localizedDescription))
    }

    /// `saved` stays visible for 2 s and `failed` for 4 s, then the phase returns to idle.
    private func setPhase(_ newPhase: RecordingPhase) {
        phase = newPhase
        resetTask?.cancel()
        let visibleFor: Duration
        switch newPhase {
        case .saved: visibleFor = .seconds(2)
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
