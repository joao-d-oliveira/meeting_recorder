import RecorderCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            inputsSection
            Divider()
            outputSection
            Divider()
            controlSection
            statusSection
        }
        .padding(20)
        .frame(width: 500)
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

    private var inputsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Inputs").font(.headline)
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
            if model.settings.inputs.isEmpty {
                Text("No inputs. Add one to record.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.settings.inputs) { input in
                inputRow(input)
            }
            HStack {
                Button {
                    model.addInput()
                } label: {
                    Label("Add input", systemImage: "plus")
                }
                .disabled(!model.canEditInputs)
                Spacer()
                Button("Reset to defaults") { model.resetInputsToDefaults() }
                    .disabled(!model.canEditInputs)
                    .help("Earbuds + BlackHole 2ch + MacBook microphone, like record-meeting.sh")
            }
        }
    }

    private func inputRow(_ input: InputConfig) -> some View {
        let id = input.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Device", selection: model.deviceNameBinding(for: id)) {
                    if input.deviceName.isEmpty {
                        Text("Select…").tag("")
                    }
                    ForEach(model.deviceChoices(for: input.deviceName), id: \.self) { name in
                        Text(model.isDeviceConnected(name) ? name : "\(name) (not connected)").tag(name)
                    }
                }
                .labelsHidden()
                .disabled(!model.canEditInputs)
                Button {
                    model.removeInput(id: id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this input")
                .disabled(!model.canEditInputs)
            }
            HStack {
                Text("Gain").font(.caption).frame(width: 56, alignment: .leading)
                Slider(value: model.gainBinding(for: id), in: 0...1.5)
                Text(String(format: "%.2f", input.gain))
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            .disabled(!model.canEditInputs)
            HStack {
                Toggle("Skip if missing", isOn: model.skipIfMissingBinding(for: id))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .disabled(!model.canEditInputs)
                Spacer()
            }
            inputMeter(for: id)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.1)))
    }

    @ViewBuilder
    private func inputMeter(for id: UUID) -> some View {
        if model.isRecording {
            if let level = model.levelDB(forInput: id) {
                LevelMeterView(levelDB: level)
            } else {
                Text("Skipped: device not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
            Label(notice.description, systemImage: "info.circle")
                .foregroundStyle(.secondary)
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
