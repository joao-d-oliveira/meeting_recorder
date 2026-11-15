import AVFoundation
import Combine
import RecorderCore
import SwiftUI

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

    let controller = RecordingController()
    private let store: SettingsStore
    private let locator = FFmpegLocator()
    private var cancellables: Set<AnyCancellable> = []

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

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
        // Forward nested ObservableObject changes so views observing the model re-render.
        controller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        issues = []
        notices = []
        refreshDevices()
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
}
