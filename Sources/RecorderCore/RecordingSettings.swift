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
    /// Every input mixed into the recording, in ffmpeg input order.
    public var inputs: [InputConfig]
    public var format: AudioFormat
    public var outputFolder: URL
    public var filenamePrefix: String
    public var folderPerRecording: Bool
    public var ffmpegPathOverride: String?
    public var transcription: TranscriptionSettings

    public init(
        inputs: [InputConfig] = InputConfig.defaultInputs,
        format: AudioFormat = .flac,
        outputFolder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Recordings/meetings", isDirectory: true),
        filenamePrefix: String = "meeting",
        folderPerRecording: Bool = true,
        ffmpegPathOverride: String? = nil,
        transcription: TranscriptionSettings = TranscriptionSettings()
    ) {
        self.inputs = inputs
        self.format = format
        self.outputFolder = outputFolder
        self.filenamePrefix = filenamePrefix
        self.folderPerRecording = folderPerRecording
        self.ffmpegPathOverride = ffmpegPathOverride
        self.transcription = transcription
    }

    private enum CodingKeys: String, CodingKey {
        case inputs, format, outputFolder, filenamePrefix, folderPerRecording
        case ffmpegPathOverride, transcription
    }

    /// Keys written by builds before multi-input support. Read for migration only, never written.
    private enum LegacyCodingKeys: String, CodingKey {
        case remoteDeviceName, micDeviceName, remoteVolume, micVolume
    }

    /// Per-field tolerant: a missing or malformed field takes its default, so one bad value
    /// no longer resets every setting. Settings saved before `inputs` existed migrate to
    /// the remote and mic inputs they described.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let defaults = RecordingSettings()

        if let decoded = Self.decodeInputs(from: container) {
            inputs = decoded
        } else if Self.hasLegacyKeys(legacy) {
            inputs = Self.migrateLegacyInputs(from: legacy, fallback: defaults.inputs)
        } else {
            inputs = defaults.inputs
        }
        format = (try? container.decodeIfPresent(AudioFormat.self, forKey: .format)) ?? defaults.format
        outputFolder = (try? container.decodeIfPresent(URL.self, forKey: .outputFolder)) ?? defaults.outputFolder
        filenamePrefix = (try? container.decodeIfPresent(String.self, forKey: .filenamePrefix))
            ?? defaults.filenamePrefix
        folderPerRecording = (try? container.decodeIfPresent(Bool.self, forKey: .folderPerRecording))
            ?? defaults.folderPerRecording
        ffmpegPathOverride = (try? container.decodeIfPresent(String.self, forKey: .ffmpegPathOverride))
            ?? defaults.ffmpegPathOverride
        transcription = (try? container.decodeIfPresent(TranscriptionSettings.self, forKey: .transcription))
            ?? defaults.transcription
    }

    /// Decodes the `inputs` array, dropping elements that are not objects at all.
    /// Returns nil when the key is absent or is not an array.
    private static func decodeInputs(from container: KeyedDecodingContainer<CodingKeys>) -> [InputConfig]? {
        guard let lossy = try? container.decodeIfPresent([LossyInput].self, forKey: .inputs) else { return nil }
        return lossy.compactMap(\.value)
    }

    private static func hasLegacyKeys(_ legacy: KeyedDecodingContainer<LegacyCodingKeys>) -> Bool {
        legacy.contains(.remoteDeviceName) || legacy.contains(.micDeviceName)
            || legacy.contains(.remoteVolume) || legacy.contains(.micVolume)
    }

    /// Old remote/mic pair -> two inputs (remote first, then mic) with their saved volumes.
    /// An old input with no device is dropped; if that leaves nothing (the user never picked
    /// a device), the defaults apply.
    private static func migrateLegacyInputs(
        from legacy: KeyedDecodingContainer<LegacyCodingKeys>, fallback: [InputConfig]
    ) -> [InputConfig] {
        func name(_ key: LegacyCodingKeys) -> String {
            (try? legacy.decodeIfPresent(String.self, forKey: key)) ?? ""
        }
        func volume(_ key: LegacyCodingKeys, default value: Double) -> Double {
            (try? legacy.decodeIfPresent(Double.self, forKey: key)) ?? value
        }
        var migrated: [InputConfig] = []
        let remote = name(.remoteDeviceName)
        if !remote.isEmpty {
            migrated.append(InputConfig(deviceName: remote, gain: volume(.remoteVolume, default: 0.55)))
        }
        let mic = name(.micDeviceName)
        if !mic.isEmpty {
            migrated.append(InputConfig(deviceName: mic, gain: volume(.micVolume, default: 1.0)))
        }
        return migrated.isEmpty ? fallback : migrated
    }
}

/// Decodes one array element without failing the whole array when the element is malformed.
private struct LossyInput: Decodable {
    let value: InputConfig?
    init(from decoder: Decoder) throws {
        value = try? InputConfig(from: decoder)
    }
}
