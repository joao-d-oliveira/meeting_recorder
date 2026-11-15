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
    /// True while a device scan runs in the background (it can take a moment, and a stuck
    /// one is killed after `DeviceScanner.defaultTimeout`).
    @Published private(set) var isScanningDevices = false
    /// True from a Start click until the recording has started or been refused: the
    /// permission prompt and the fresh device scan sit in between.
    @Published private(set) var isStarting = false
    /// Why the device list could not be read (scan stuck or ffmpeg not runnable); nil if fine.
    @Published private(set) var scanProblem: String?

    // MARK: Transcription panel state

    /// The audio file the transcription panel is about. A run is tied to the file it was
    /// started for: this only changes while no run is in progress, so a recording that is
    /// saved mid-run can never take over the panel (it waits in `queuedAudio`).
    @Published private(set) var transcriptionTarget: URL?
    /// Where a run for `transcriptionTarget` would write the transcript. Worked out once per
    /// target (and again when something that decides it may have changed), not per render:
    /// the rule lists the audio's folder, and the panel redraws ~10 times a second while
    /// recording and on every keystroke in the guest field.
    @Published private(set) var transcriptionOutputDirectory: URL?
    /// Guest name typed in the panel (empty = `defaultGuestName` from the settings).
    @Published var guestName = ""
    @Published private(set) var transcriptionStartedAt: Date?
    @Published private(set) var transcriptionFinishedAt: Date?
    /// Recordings saved, and files picked with "Transcribe a file…", while a transcription
    /// was running: offered in this order once it ends. A queue, because several can pile up
    /// during one long run.
    @Published private(set) var queuedAudio: [QueuedAudio] = []
    /// The last successful transcript, kept in view when the panel moves on to another
    /// file so a weak-match warning is not lost.
    @Published private(set) var previousTranscript: PreviousTranscript?

    struct QueuedAudio: Equatable {
        let url: URL
        /// A recording the app saved (it starts by itself after a successful run when
        /// auto-transcribe is on), as opposed to a file the user picked, which waits for a
        /// guest name like any picked file.
        let isRecording: Bool
    }

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
    /// The newest scan wins: an older one is cancelled and its result ignored.
    private var scanGeneration = 0
    private var scanCancellation: DeviceScanCancellation?
    /// Set once the user has agreed to quit: from then on nothing may start a recording or a
    /// pipeline run, because the quit is already waiting on the ones that were running.
    @Published private(set) var isQuitting = false

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

    /// The window must not be closed: it would leave a windowless app with a live recording
    /// (closing quits, and the quit confirmation can be declined). Only `.recording`: once the
    /// recording is stopping, closing the window is a quit that waits for ffmpeg to finish.
    var isCloseLocked: Bool {
        if case .recording = controller.state { return true }
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

    /// Rescans the audio devices in the background; `devices` is updated when it is done.
    func refreshDevices() {
        guard !isQuitting else { return }
        guard let path = ffmpegPath else {
            cancelScan()
            devices = []
            scanProblem = nil
            issues = [.ffmpegNotFound]
            return
        }
        issues.removeAll { $0 == .ffmpegNotFound }
        Task { _ = await scanDevices(path: path) }
    }

    /// Runs ffmpeg's device listing off the main thread, so a stalled audio driver cannot
    /// freeze the window (or Cmd-Q). Starting a scan cancels the one before it. The result
    /// is applied to `devices` / `scanProblem` unless a newer scan or a quit replaced it.
    private func scanDevices(path: String) async -> DeviceScanResult {
        cancelScan()
        let cancellation = DeviceScanCancellation()
        scanCancellation = cancellation
        let generation = scanGeneration
        isScanningDevices = true
        let result: DeviceScanResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(
                    returning: DeviceScanner.scan(ffmpegPath: path, cancellation: cancellation))
            }
        }
        guard generation == scanGeneration else { return result }
        scanCancellation = nil
        isScanningDevices = false
        if case .devices(let found) = result { devices = found }
        scanProblem = Self.scanProblem(for: result)
        return result
    }

    /// What to tell the user when a scan did not produce a device list; nil for a good one.
    private static func scanProblem(for result: DeviceScanResult) -> String? {
        switch result {
        case .devices:
            return nil
        case .timedOut:
            return "Listing the audio devices took longer than "
                + "\(Int(DeviceScanner.defaultTimeout)) seconds and was stopped. "
                + "Check the audio drivers, then use Rescan."
        case .failedToLaunch(let message):
            return "Could not run ffmpeg to list the audio devices: \(message)"
        case .cancelled:
            return "Listing the audio devices was interrupted. Try again."
        }
    }

    /// Stops the scan in flight, if any, and makes its result count for nothing.
    private func cancelScan() {
        scanCancellation?.cancel()
        scanCancellation = nil
        scanGeneration += 1
        isScanningDevices = false
    }

    func startRecording() {
        // A double click (or a click while the first-run permission prompt is up or the
        // devices are being scanned) must not start twice.
        // While quitting the app only waits for the recording it stops: a new one would be
        // left running when the quit completes.
        guard !isQuitting, !isRecording, !isStarting else { return }
        isStarting = true
        issues = []
        notices = []
        scanProblem = nil
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in await self.beginRecording(micAuthorized: granted) }
            }
        case .authorized:
            Task { await beginRecording(micAuthorized: true) }
        default:
            Task { await beginRecording(micAuthorized: false) }
        }
    }

    private func beginRecording(micAuthorized: Bool) async {
        defer { isStarting = false }
        // The permission answer can arrive after the user has agreed to quit.
        guard !isQuitting, !isRecording else { return }
        let path = ffmpegPath
        var available: [AudioDevice] = []
        if let path {
            // Scan here, not in startRecording: the permission prompt can sit open for a long
            // time, and a device plugged in (or removed) meanwhile would shift the indexes.
            let scan = await scanDevices(path: path)
            // Things happen during the await: the user may have agreed to quit meanwhile.
            guard !isQuitting, !isRecording else { return }
            // A scan that failed or was cut short says nothing about the devices: starting
            // on a stale list could record the wrong inputs.
            guard case .devices(let found) = scan else {
                scanProblem = Self.scanProblem(for: scan)
                return
            }
            available = found
        } else {
            devices = []
        }
        let result = PreflightValidator.validate(
            settings: settings, availableDevices: available,
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
        guard let directory = transcriptionOutputDirectory else { return nil }
        let guest = TranscriptionRequest.sanitizedName(
            guestName, fallback: settings.transcription.defaultGuestName)
        let url = directory.appendingPathComponent("\(guest)_Transcript.md")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Set when the transcript will not be written in the audio file's own folder.
    var transcriptOutputNote: String? {
        guard let audio = transcriptionTarget,
              let output = transcriptionOutputDirectory?.standardizedFileURL else { return nil }
        guard output != audio.deletingLastPathComponent().standardizedFileURL else { return nil }
        return "The transcript is written to \"\(output.lastPathComponent)\" next to the audio file."
    }

    /// Recomputes `transcriptionOutputDirectory`. Called when the target changes and when a
    /// run ends or is reset; the folder's contents can have changed since (another recording
    /// saved next to this one moves the transcript into a subfolder).
    private func refreshTranscriptionOutputDirectory() {
        let directory = transcriptionTarget.map { TranscriptionRequest.defaultOutputDirectory(for: $0) }
        if transcriptionOutputDirectory != directory { transcriptionOutputDirectory = directory }
    }

    /// Runs the pipeline for the panel's file.
    func startTranscription() {
        guard !isQuitting, !isTranscribing, let audio = transcriptionTarget else { return }
        // Built now, not taken from the shown note: the request decides where the transcript
        // goes from the folder as it is at click time.
        let request = TranscriptionRequest(audioURL: audio, guestName: guestName)
        if transcriptionOutputDirectory != request.outputDirectory {
            transcriptionOutputDirectory = request.outputDirectory
        }
        transcriptionStartedAt = Date()
        transcriptionFinishedAt = nil
        transcription.start(request: request, settings: settings.transcription)
    }

    func cancelTranscription() {
        transcription.cancel()
    }

    /// Called once the user has agreed to quit: nothing may start a new pipeline run now
    /// (stopping a recording saves it, which would otherwise auto-start a transcription).
    func prepareForQuit() {
        isQuitting = true
        // A stuck scan would otherwise outlive the app as an orphaned ffmpeg.
        cancelScan()
    }

    /// Back to the guest-name form for the same file (to re-run with another name).
    func prepareTranscriptionRerun() {
        guard !isTranscribing else { return }
        transcription.reset()
        refreshTranscriptionOutputDirectory()
    }

    /// "Transcribe a file…": any flac/wav/m4a/mp3, not only a fresh recording.
    func chooseAudioFile() {
        guard !isQuitting, !isTranscribing else { return }
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
        // The picker is modal but the app keeps running behind it: a recording can have been
        // saved and auto-started a run meanwhile, and the panel cannot move off that run.
        if isTranscribing {
            enqueue(url, isRecording: false)
        } else {
            adoptAudio(url, autostart: false)
        }
    }

    /// Moves the oldest queued file into the panel (after the run has ended).
    func transcribeNextQueued() {
        guard !isTranscribing, let next = queuedAudio.first else { return }
        adoptAudio(next.url, autostart: false)
    }

    /// Adds a file to the end of the queue unless it is already waiting or is the file of
    /// the run in progress.
    private func enqueue(_ url: URL, isRecording: Bool) {
        let url = url.standardizedFileURL
        guard url != transcriptionTarget, !queuedAudio.contains(where: { $0.url == url }) else { return }
        queuedAudio.append(QueuedAudio(url: url, isRecording: isRecording))
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
            enqueue(url, isRecording: true)
        } else {
            // The newest recording takes the panel. Older queued files stay queued.
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
            refreshTranscriptionOutputDirectory()
        }
        // The recording saved first during the run is transcribed next when auto-transcribe is
        // on, and so on down the queue as each run succeeds; after a cancel or a failure the
        // user decides. A picked file at the front also stops the chain: it needs a guest name.
        // `state` can be stale after the hop; the controller has the current one.
        if case .finished = state, case .finished = transcription.state, !isQuitting,
           settings.transcription.autoTranscribe,
           let next = queuedAudio.first, next.isRecording {
            adoptAudio(next.url, autostart: true)
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
        refreshTranscriptionOutputDirectory()
        transcriptionStartedAt = nil
        transcriptionFinishedAt = nil
        guestName = ""
        queuedAudio.removeAll { $0.url == audio }
        if autostart { startTranscription() }
    }
}

