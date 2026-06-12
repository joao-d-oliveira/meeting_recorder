import Foundation

public enum AudioFormat: String, Codable, CaseIterable, Identifiable {
    case flac, wav, mp3, m4a
    public var id: String { rawValue }

    /// ffmpeg codec arguments for this container.
    public var codecArguments: [String] {
        switch self {
        case .flac: return ["-c:a", "flac"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .mp3: return ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }
}

public struct RecordingSettings: Codable, Equatable {
    public var remoteDeviceName: String?
    public var micDeviceName: String?
    public var remoteVolume: Double
    public var micVolume: Double
    public var format: AudioFormat
    public var outputFolder: URL
    public var filenamePrefix: String
    public var folderPerRecording: Bool
    public var ffmpegPathOverride: String?

    public init(
        remoteDeviceName: String? = nil,
        micDeviceName: String? = nil,
        remoteVolume: Double = 0.55,
        micVolume: Double = 1.0,
        format: AudioFormat = .flac,
        outputFolder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Recordings/meetings", isDirectory: true),
        filenamePrefix: String = "meeting",
        folderPerRecording: Bool = true,
        ffmpegPathOverride: String? = nil
    ) {
        self.remoteDeviceName = remoteDeviceName
        self.micDeviceName = micDeviceName
        self.remoteVolume = remoteVolume
        self.micVolume = micVolume
        self.format = format
        self.outputFolder = outputFolder
        self.filenamePrefix = filenamePrefix
        self.folderPerRecording = folderPerRecording
        self.ffmpegPathOverride = ffmpegPathOverride
    }
}
