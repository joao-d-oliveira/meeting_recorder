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
            }

            HStack {
                Text(model.ffmpegPath.map { "Using ffmpeg at \($0)" } ?? "ffmpeg not found")
                    .font(.caption)
                    .foregroundStyle(model.ffmpegPath == nil ? .red : .secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
