import AVFoundation
import Combine
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var settings: RecordingSettings {
        didSet { store.save(settings) }
    }
    /// Problems that blocked the last Start attempt.
    @Published var issues: [PreflightIssue] = []
    /// Non-blocking messages from the last Start attempt (e.g. skipped devices).
    @Published var notices: [PreflightNotice] = []
    /// Ids of the inputs in the running (or last) recording, in level-meter order:
    /// position here is the index into `controller.levelsDB`.
    @Published private(set) var recordedInputIDs: [UUID] = []
    @Published var showSettingsSheet = false
    @Published var showFolderPicker = false

    // MARK: Transcription panel state

    /// The audio file the transcription panel is about. A run is tied to the file it was
    /// started for: this only changes while no run is in progress, so a recording that is
    /// saved mid-run can never take over the panel (it waits in `pendingRecording`).
    @Published private(set) var transcriptionTarget: URL?
    /// Guest name typed in the panel (empty = `defaultGuestName` from the settings).
    @Published var guestName = ""
    @Published private(set) var transcriptionStartedAt: Date?
    @Published private(set) var transcriptionFinishedAt: Date?
    /// A recording saved while a transcription was running; offered once it ends.
    @Published private(set) var pendingRecording: URL?
    /// The last successful transcript, kept in view when the panel moves on to another
    /// file so a weak-match warning is not lost.
    @Published private(set) var previousTranscript: PreviousTranscript?

    struct PreviousTranscript: Equatable {
        let audioURL: URL
        let result: TranscriptionResult
    }

    let controller = RecordingController()
    let transcription: TranscriptionController
    private let store: SettingsStore
    private let locator = FFmpegLocator()
    private let pipelineLocator = PipelineLocator()
    private var cancellables: Set<AnyCancellable> = []
    private var isQuitting = false

    var ffmpegPath: String? {
        let expandedOverride = settings.ffmpegPathOverride.map {
            ($0 as NSString).expandingTildeInPath
        }
        return locator.locate(override: expandedOverride)
    }

    var isRecording: Bool {
        if case .recording = controller.state { return true }
        if case .stopping = controller.state { return true }
        return false
    }

    var isTranscribing: Bool {
        if case .running = transcription.state { return true }
        return false
    }

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
        self.transcription = TranscriptionController(locator: pipelineLocator)
        // Forward nested ObservableObject changes so views observing the model re-render.
        controller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        transcription.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // $state emits in willSet; the hop lets the controllers finish their change first.
        controller.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if case .saved(let url) = state { self?.recordingSaved(url) }
            }
            .store(in: &cancellables)
        transcription.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.transcriptionStateChanged(state) }
            .store(in: &cancellables)
        refreshDevices()
    }

    func refreshDevices() {
        guard let path = ffmpegPath else {
            devices = []
            issues = [.ffmpegNotFound]
            return
        }
        issues.removeAll { $0 == .ffmpegNotFound }
        devices = DeviceScanner.scan(ffmpegPath: path)
    }

    func startRecording() {
        // A double click (or a click while the first-run permission prompt is up) must not
        // start twice; the controller ignores a second start, but the model would not.
        guard !isRecording else { return }
        issues = []
        notices = []
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in self.beginRecording(micAuthorized: granted) }
            }
        case .authorized:
            beginRecording(micAuthorized: true)
        default:
            beginRecording(micAuthorized: false)
        }
    }

    private func beginRecording(micAuthorized: Bool) {
        // First run: Start was clicked more than once while the permission prompt was open,
        // so this runs once per click. Only the first may start.
        guard !isRecording else { return }
        // Scan here, not in startRecording: the permission prompt can sit open for a long
        // time, and a device plugged in (or removed) meanwhile would shift the indexes.
        refreshDevices()
        let path = ffmpegPath
        let result = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: path, micAuthorized: micAuthorized)
        notices = result.notices
        guard result.canStart, let path else {
            issues = result.issues
            return
        }
        issues = []
        recordedInputIDs = result.inputs.recorded.map(\.config.id)

        let outputURL = OutputLocation.makeURL(settings: settings, date: Date())
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let resolved = result.resolvedInputs
        let arguments = CommandBuilder.arguments(
            inputs: resolved, settings: settings, outputURL: outputURL)
        controller.start(
            ffmpegPath: path, arguments: arguments, outputURL: outputURL, inputCount: resolved.count)
    }

    func stopRecording() {
        controller.stop()
    }

    // MARK: - Inputs

    /// Inputs can't change under a running recording: the ffmpeg command is already fixed.
    var canEditInputs: Bool { !isRecording }

    func isDeviceConnected(_ name: String) -> Bool {
        devices.contains { $0.name == name }
    }

    /// Names offered by an input's device picker (unique, so they can serve as picker ids).
    func deviceChoices(for current: String) -> [String] {
        InputResolver.deviceChoices(devices: devices, current: current)
    }

    func addInput() {
        guard canEditInputs else { return }
        let used = Set(settings.inputs.map(\.deviceName))
        let name = devices.first { !used.contains($0.name) }?.name ?? ""
        settings.inputs.append(InputConfig(deviceName: name, gain: 1.0))
    }

    func removeInput(id: UUID) {
        guard canEditInputs else { return }
        settings.inputs.removeAll { $0.id == id }
    }

    func resetInputsToDefaults() {
        guard canEditInputs else { return }
        settings.inputs = InputConfig.defaultInputs
    }

    func deviceNameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { self.settings.inputs.first { $0.id == id }?.deviceName ?? "" },
            set: { newValue in self.updateInput(id) { $0.deviceName = newValue } })
    }

    func gainBinding(for id: UUID) -> Binding<Double> {
        Binding(
            get: { self.settings.inputs.first { $0.id == id }?.gain ?? 1.0 },
            set: { newValue in self.updateInput(id) { $0.gain = newValue } })
    }

    func skipIfMissingBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { self.settings.inputs.first { $0.id == id }?.skipIfMissing ?? false },
            set: { newValue in self.updateInput(id) { $0.skipIfMissing = newValue } })
    }

    private func updateInput(_ id: UUID, _ change: (inout InputConfig) -> Void) {
        // Looked up by id on every write: rows can be removed while a binding is alive.
        guard canEditInputs, let index = settings.inputs.firstIndex(where: { $0.id == id }) else { return }
        change(&settings.inputs[index])
    }

    /// Live level of an input in the current recording; nil if it isn't being recorded
    /// (not started yet, or skipped because its device is missing).
    func levelDB(forInput id: UUID) -> Double? {
        guard let position = recordedInputIDs.firstIndex(of: id),
              controller.levelsDB.indices.contains(position) else { return nil }
        return controller.levelsDB[position]
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Transcription

    /// "2026-11-15_10-30-00/meeting.flac": every recording is called meeting.flac, so the
    /// folder is what tells two of them apart.
    func displayName(for audio: URL) -> String {
        let folder = audio.deletingLastPathComponent().lastPathComponent
        return folder.isEmpty ? audio.lastPathComponent : "\(folder)/\(audio.lastPathComponent)"
    }

    /// What the guest field shows when empty: the guest label a run would actually use.
    var guestPlaceholder: String {
        TranscriptionRequest.sanitizedName(
            settings.transcription.defaultGuestName, fallback: "", lastResort: "Guest")
    }

    var interviewerDisplayName: String {
        TranscriptionRequest.sanitizedName(
            settings.transcription.interviewerName, fallback: "", lastResort: "Joao")
    }

    /// The transcript a run for the current panel would overwrite, if there already is one.
    var transcriptThatWouldBeReplaced: URL? {
        guard let audio = transcriptionTarget else { return nil }
        let guest = TranscriptionRequest.sanitizedName(
            guestName, fallback: settings.transcription.defaultGuestName)
        let url = audio.deletingLastPathComponent().appendingPathComponent("\(guest)_Transcript.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Runs the pipeline for the panel's file; the transcript lands in that file's folder.
    func startTranscription() {
        guard !isQuitting, !isTranscribing, let audio = transcriptionTarget else { return }
        transcriptionStartedAt = Date()
        transcriptionFinishedAt = nil
        transcription.start(
            request: TranscriptionRequest(audioURL: audio, guestName: guestName),
            settings: settings.transcription)
    }

    func cancelTranscription() {
        transcription.cancel()
    }

    /// Called once the user has agreed to quit: nothing may start a new pipeline run now
    /// (stopping a recording saves it, which would otherwise auto-start a transcription).
    func prepareForQuit() {
        isQuitting = true
    }

    /// Back to the guest-name form for the same file (to re-run with another name).
    func prepareTranscriptionRerun() {
        guard !isTranscribing else { return }
        transcription.reset()
    }

    /// "Transcribe a file…": any flac/wav/m4a/mp3, not only a fresh recording.
    func chooseAudioFile() {
        guard !isTranscribing else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an audio file to transcribe"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["flac", "wav", "m4a", "mp3"].compactMap {
            UTType(filenameExtension: $0)
        }
        panel.directoryURL = settings.outputFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptAudio(url, autostart: false)
    }

    /// Moves a recording that was saved mid-run into the panel (after the run has ended).
    func transcribePendingRecording() {
        guard let url = pendingRecording else { return }
        adoptAudio(url, autostart: false)
    }

    // MARK: Pipeline folder

    /// The pipeline directory a run would use (override, bundled copy, or the repo's during
    /// development), or nil if none is found.
    var pipelineURL: URL? {
        pipelineLocator.locate(settings: settings.transcription)
    }

    /// True when a pipeline folder is set but has no run.sh (the locator then falls back to
    /// the bundled copy, silently).
    var pipelineOverrideIsInvalid: Bool {
        guard let override = settings.transcription.pipelineDirectoryOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty else { return false }
        let directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        return !pipelineLocator.containsRunScript(directory)
    }

    func choosePipelineFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the pipeline folder (the one containing run.sh)"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let current = settings.transcription.pipelineDirectoryOverride, !current.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (current as NSString).expandingTildeInPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.transcription.pipelineDirectoryOverride = url.path
    }

    func openTranscript(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func recordingSaved(_ url: URL) {
        if isTranscribing {
            pendingRecording = url.standardizedFileURL
        } else {
            pendingRecording = nil  // superseded by this newer recording
            adoptAudio(url, autostart: settings.transcription.autoTranscribe)
        }
    }

    private func transcriptionStateChanged(_ state: TranscriptionState) {
        switch state {
        case .running, .idle:
            return
        case .finished, .failed, .cancelled:
            if transcriptionFinishedAt == nil, transcriptionStartedAt != nil {
                transcriptionFinishedAt = Date()
            }
        }
        // A recording that was saved mid-run is transcribed next when auto-transcribe is on,
        // but only after a successful run: after a cancel or a failure the user decides.
        // `state` can be stale after the hop; the controller has the current one.
        if case .finished = state, case .finished = transcription.state,
           let next = pendingRecording, settings.transcription.autoTranscribe {
            adoptAudio(next, autostart: true)
        }
    }

    /// Points the panel at `audio`. Never called while a run is in progress.
    private func adoptAudio(_ audio: URL, autostart: Bool) {
        guard !isTranscribing else { return }
        let audio = audio.standardizedFileURL
        if case .finished(let result) = transcription.state, let old = transcriptionTarget, old != audio {
            previousTranscript = PreviousTranscript(audioURL: old, result: result)
        }
        transcription.reset()
        transcriptionTarget = audio
        transcriptionStartedAt = nil
        transcriptionFinishedAt = nil
        guestName = ""
        if pendingRecording == audio { pendingRecording = nil }
        if autostart { startTranscription() }
    }
}

