import Foundation

/// Post-recording transcription (Whisper + voiceprint diarization) preferences.
public struct TranscriptionSettings: Codable, Equatable {
    /// Start transcription as soon as a recording is saved (uses `defaultGuestName`
    /// when the user hasn't typed one).
    public var autoTranscribe: Bool
    /// Name used for the interviewer's turns; selects ~/.cache/diarize/voiceprint-<name>.npy.
    public var interviewerName: String
    /// Guest label used when none is entered.
    public var defaultGuestName: String
    /// Optional path to a directory containing run.sh; nil = the copy bundled with the app.
    public var pipelineDirectoryOverride: String?

    public init(
        autoTranscribe: Bool = false,
        interviewerName: String = "Joao",
        defaultGuestName: String = "Guest",
        pipelineDirectoryOverride: String? = nil
    ) {
        self.autoTranscribe = autoTranscribe
        self.interviewerName = interviewerName
        self.defaultGuestName = defaultGuestName
        self.pipelineDirectoryOverride = pipelineDirectoryOverride
    }
}
