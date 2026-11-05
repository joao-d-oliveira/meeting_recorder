import RecorderCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            deviceSection
            Divider()
            volumeSection
            meterSection
            Divider()
            outputSection
            Divider()
            controlSection
            statusSection
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $model.showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.settings.outputFolder = url
            }
        }
        .sheet(isPresented: $model.showSettingsSheet) {
            SettingsSheet()
                .environmentObject(model)
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Sources").font(.headline)
                Spacer()
                Button {
                    model.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan audio devices")
                .disabled(model.isRecording)
                Button {
                    model.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            Picker("Remote audio", selection: $model.settings.remoteDeviceName) {
                Text("Select…").tag(String?.none)
                ForEach(model.devices) { device in
                    Text(device.name).tag(Optional(device.name))
                }
            }
            .disabled(model.isRecording)
            Picker("Microphone", selection: $model.settings.micDeviceName) {
                Text("Select…").tag(String?.none)
                ForEach(model.devices) { device in
                    Text(device.name).tag(Optional(device.name))
                }
            }
            .disabled(model.isRecording)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Levels").font(.headline)
            HStack {
                Text("Remote").frame(width: 56, alignment: .leading).font(.caption)
                Slider(value: $model.settings.remoteVolume, in: 0...1.5)
                Text("\(Int(model.settings.remoteVolume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("Mic").frame(width: 56, alignment: .leading).font(.caption)
                Slider(value: $model.settings.micVolume, in: 0...1.5)
                Text("\(Int(model.settings.micVolume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var meterSection: some View {
        if model.isRecording {
            VStack(alignment: .leading, spacing: 6) {
                LevelMeterView(label: "Remote", levelDB: model.controller.remoteLevelDB)
                LevelMeterView(label: "Mic", levelDB: model.controller.micLevelDB)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output").font(.headline)
            HStack {
                Text(model.settings.outputFolder.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { model.showFolderPicker = true }
                    .disabled(model.isRecording)
            }
            Picker("Format", selection: $model.settings.format) {
                ForEach(AudioFormat.allCases) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRecording)
        }
    }

    private var controlSection: some View {
        HStack {
            if model.isRecording {
                Button(role: .destructive) {
                    model.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button {
                    model.startRecording()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            if case .recording(let startedAt) = model.controller.state {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedString(from: startedAt, to: context.date))
                        .font(.title3.monospacedDigit())
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.controller.state {
        case .idle:
            EmptyView()
        case .recording:
            Label("Recording…", systemImage: "circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .stopping:
            Label("Finishing up…", systemImage: "hourglass").font(.caption)
        case .saved(let url):
            HStack {
                Label("Saved: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Button("Reveal in Finder") { model.revealInFinder(url) }
                    .font(.caption)
            }
        case .failed(let message, let stderrTail):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                if !stderrTail.isEmpty {
                    DisclosureGroup("ffmpeg output") {
                        ScrollView {
                            Text(stderrTail.joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.caption)
                }
            }
        }
        ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
            Label(issue.description, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
