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
    @Published var issues: [PreflightIssue] = []
    @Published var showSettingsSheet = false

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
        devices = DeviceScanner.scan(ffmpegPath: path)
    }

    func startRecording() {
        issues = []
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
        let found = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: path, micAuthorized: micAuthorized)
        guard found.isEmpty,
              let path,
              let remote = devices.first(where: { $0.name == settings.remoteDeviceName }),
              let mic = devices.first(where: { $0.name == settings.micDeviceName })
        else {
            issues = found
            return
        }

        let outputURL = OutputLocation.makeURL(settings: settings, date: Date())
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let arguments = CommandBuilder.arguments(
            remoteIndex: remote.index, micIndex: mic.index,
            settings: settings, outputURL: outputURL)
        controller.start(ffmpegPath: path, arguments: arguments, outputURL: outputURL)
    }

    func stopRecording() {
        controller.stop()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
