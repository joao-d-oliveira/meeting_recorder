import RecorderCore
import SwiftUI

/// "H:MM:SS" or "MM:SS".
func formatClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

/// The "Transcription" section of the main window. It always describes one audio file (shown
/// by name), the one the run was started for, whatever recording is made or saved meanwhile.
struct TranscriptionPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcription").font(.headline)
                Spacer()
                Button("Transcribe a file…") { model.chooseAudioFile() }
                    .disabled(model.isTranscribing)
                    .help("Transcribe an existing flac, wav, m4a or mp3 file")
            }
            if let audio = model.transcriptionTarget {
                Label(model.displayName(for: audio), systemImage: "waveform")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(audio.path)
                stateBody
            } else {
                Text("A saved recording appears here, ready to transcribe. Or pick an existing audio file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            pendingRecordingRow
            previousTranscriptRow
        }
    }

    // MARK: States

    @ViewBuilder
    private var stateBody: some View {
        switch model.transcription.state {
        case .idle:
            guestForm(buttonTitle: "Transcribe")
            Text("Runs on this Mac. Two speakers: \(model.interviewerDisplayName) and the guest.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .running(let stage, let progress):
            runningBody(stage: stage, progress: progress)
        case .finished(let result):
            finishedBody(result)
        case .failed(let message, let logTail):
            failedBody(message: message, logTail: logTail)
        case .cancelled:
            Label("Transcription cancelled.", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            guestForm(buttonTitle: "Transcribe again")
        }
    }

    private func guestForm(buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField(model.guestPlaceholder, text: $model.guestName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Guest name")
                    .onSubmit { model.startTranscription() }
                Button(buttonTitle) { model.startTranscription() }
                    .buttonStyle(.borderedProminent)
            }
            if let existing = model.transcriptThatWouldBeReplaced {
                Label("\(existing.lastPathComponent) already exists in this folder and will be replaced.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func runningBody(stage: TranscriptionStage, progress: Double?) -> some View {
        let cancelling = model.transcription.isCancelling
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(stage.title).font(.subheadline)
                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let started = model.transcriptionStartedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(formatClock(context.date.timeIntervalSince(started)))
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Button(cancelling ? "Cancelling…" : "Cancel") { model.cancelTranscription() }
                    .disabled(cancelling)
            }
            if let progress {
                ProgressView(value: min(max(progress, 0), 1), total: 1)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            if stage == .setup {
                Text("First run: creating the Python environment and downloading models. This can take several minutes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            let guest = model.guestName.isEmpty ? model.guestPlaceholder : model.guestName
            Text("Guest: \(guest)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func finishedBody(_ result: TranscriptionResult) -> some View {
        let interviewerName = result.interviewer.isEmpty ? model.interviewerDisplayName : result.interviewer
        let guestName = result.guest.isEmpty ? model.guestPlaceholder : result.guest
        return VStack(alignment: .leading, spacing: 6) {
            Label("Transcript ready: \(result.transcriptURL.lastPathComponent)",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
            if result.weakMatch {
                Label("Weak voice match — check the labels by reading the first turns",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                statRow("Turns", "\(result.turnCount)")
                statRow("Duration", formatClock(result.durationSeconds))
                statRow("Speaking time",
                        "\(interviewerName) (Interviewer): \(minutes(result.interviewerSpeakingSeconds))")
                statRow("", "\(guestName) (Interviewee): \(minutes(result.guestSpeakingSeconds))")
                statRow("Identified by",
                        identification(result, interviewer: interviewerName, guest: guestName))
                statRow("Uncertain turns (?)", "\(result.uncertainTurns)")
                if let started = model.transcriptionStartedAt, let finished = model.transcriptionFinishedAt {
                    statRow("Took", formatClock(finished.timeIntervalSince(started)))
                }
            }
            if result.uncertainTurns > 0 {
                Text("Turns marked (?) in the transcript had a weak voice match; check them by ear.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Open transcript") { model.openTranscript(result.transcriptURL) }
                    .buttonStyle(.borderedProminent)
                Button("Show in Finder") { model.revealInFinder(result.transcriptURL) }
                Spacer()
                Button("Transcribe again…") { model.prepareTranscriptionRerun() }
                    .help("Run again, for example with a different guest name")
            }
            Text("Raw Whisper output: proper names are often misspelled, and words at a speaker change can land in the neighbouring turn.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func failedBody(message: String, logTail: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
            if !logTail.isEmpty {
                DisclosureGroup("Pipeline output") {
                    ScrollView {
                        Text(logTail.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
                .font(.caption)
            }
            guestForm(buttonTitle: "Retry")
        }
    }

    // MARK: Pieces

    private func statRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }

    /// Speaking time in minutes with one decimal, like the transcript's own header.
    private func minutes(_ seconds: Double) -> String {
        String(format: "%.1f min", seconds / 60)
    }

    /// For a voiceprint match the two scores by role (the interviewer's should be high, the
    /// guest's low); otherwise the pipeline's own description.
    private func identification(_ result: TranscriptionResult, interviewer: String, guest: String) -> String {
        guard result.identificationMethod == "voiceprint" else {
            return result.identificationDetail.isEmpty ? "unknown" : result.identificationDetail
        }
        return String(
            format: "saved voiceprint (%@ %.2f, %@ %.2f)",
            interviewer, result.interviewerSimilarity, guest, result.guestSimilarity)
    }

    @ViewBuilder
    private var pendingRecordingRow: some View {
        if let pending = model.pendingRecording, pending != model.transcriptionTarget {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
                Text("New recording saved: \(model.displayName(for: pending))")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Transcribe…") { model.transcribePendingRecording() }
                    .font(.caption)
                    .disabled(model.isTranscribing)
                    .help(model.isTranscribing
                        ? "Available when the current transcription ends"
                        : "Show this recording in the panel above")
            }
        }
    }

    @ViewBuilder
    private var previousTranscriptRow: some View {
        if let previous = model.previousTranscript, previous.audioURL != model.transcriptionTarget {
            HStack(spacing: 6) {
                Image(systemName: previous.result.weakMatch ? "exclamationmark.triangle.fill" : "doc.text")
                    .foregroundStyle(previous.result.weakMatch ? Color.orange : Color.secondary)
                Text("Earlier: \(previous.result.transcriptURL.lastPathComponent) (\(model.displayName(for: previous.audioURL)))"
                    + (previous.result.weakMatch ? " — weak voice match" : ""))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Open") { model.openTranscript(previous.result.transcriptURL) }
                    .font(.caption)
                Button("Show") { model.revealInFinder(previous.result.transcriptURL) }
                    .font(.caption)
            }
        }
    }
}
