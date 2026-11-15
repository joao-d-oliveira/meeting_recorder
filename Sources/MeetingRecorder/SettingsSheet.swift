import RecorderCore
import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title3.bold())

            Form {
                TextField("Filename prefix", text: $model.settings.filenamePrefix)
                Toggle("Create one folder per recording", isOn: $model.settings.folderPerRecording)
                TextField(
                    "ffmpeg path (blank = auto-detect)",
                    text: Binding(
                        get: { model.settings.ffmpegPathOverride ?? "" },
                        set: { model.settings.ffmpegPathOverride = $0.isEmpty ? nil : $0 }
                    ))

                Section("Transcription") {
                    Toggle(
                        "Transcribe automatically after recording",
                        isOn: $model.settings.transcription.autoTranscribe)
                    TextField("Interviewer name", text: $model.settings.transcription.interviewerName)
                    TextField("Default guest name", text: $model.settings.transcription.defaultGuestName)
                    LabeledContent("Pipeline folder") {
                        HStack {
                            TextField(
                                "Pipeline folder", text: pipelineOverride,
                                prompt: Text("Blank = bundled with the app"))
                                .labelsHidden()
                            Button("Choose…") { model.choosePipelineFolder() }
                            Button("Clear") { model.settings.transcription.pipelineDirectoryOverride = nil }
                                .disabled(pipelineOverride.wrappedValue.isEmpty)
                        }
                    }
                }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.ffmpegPath.map { "Using ffmpeg at \($0)" } ?? "ffmpeg not found")
                        .font(.caption)
                        .foregroundStyle(model.ffmpegPath == nil ? .red : .secondary)
                    pipelineStatus
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var pipelineOverride: Binding<String> {
        Binding(
            get: { model.settings.transcription.pipelineDirectoryOverride ?? "" },
            set: { model.settings.transcription.pipelineDirectoryOverride = $0.isEmpty ? nil : $0 })
    }

    /// Which pipeline a transcription would run, or a red note when there is none.
    @ViewBuilder
    private var pipelineStatus: some View {
        if model.pipelineOverrideIsInvalid {
            Text("No run.sh in the chosen pipeline folder.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if let pipeline = model.pipelineURL {
            Text("Using pipeline at \(pipeline.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        } else {
            Text("Pipeline not found. Reinstall the app, or choose a folder that contains run.sh.")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
