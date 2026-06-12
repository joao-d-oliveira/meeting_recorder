import Foundation

public enum PreflightIssue: Equatable, CustomStringConvertible {
    case noRemoteSelected
    case noMicSelected
    case deviceMissing(name: String)
    case ffmpegNotFound
    case microphoneAccessDenied
    case outputFolderNotWritable(path: String)

    public var description: String {
        switch self {
        case .noRemoteSelected:
            return "Select a remote/system audio source (e.g. BlackHole 2ch)."
        case .noMicSelected:
            return "Select a microphone."
        case .deviceMissing(let name):
            return "Device \"\(name)\" is not available. Refresh devices and pick another."
        case .ffmpegNotFound:
            return "ffmpeg was not found. Install it with: brew install ffmpeg"
        case .microphoneAccessDenied:
            return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .outputFolderNotWritable(let path):
            return "Cannot write to output folder: \(path). Choose another folder."
        }
    }
}

public enum PreflightValidator {
    public static func validate(
        settings: RecordingSettings,
        availableDevices: [AudioDevice],
        ffmpegPath: String?,
        micAuthorized: Bool,
        fileManager: FileManager = .default
    ) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        let names = Set(availableDevices.map(\.name))

        if let remote = settings.remoteDeviceName, !remote.isEmpty {
            if !names.contains(remote) { issues.append(.deviceMissing(name: remote)) }
        } else {
            issues.append(.noRemoteSelected)
        }

        if let mic = settings.micDeviceName, !mic.isEmpty {
            if !names.contains(mic) { issues.append(.deviceMissing(name: mic)) }
        } else {
            issues.append(.noMicSelected)
        }

        if ffmpegPath == nil { issues.append(.ffmpegNotFound) }
        if !micAuthorized { issues.append(.microphoneAccessDenied) }

        do {
            try fileManager.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
            if !fileManager.isWritableFile(atPath: settings.outputFolder.path) {
                issues.append(.outputFolderNotWritable(path: settings.outputFolder.path))
            }
        } catch {
            issues.append(.outputFolderNotWritable(path: settings.outputFolder.path))
        }

        return issues
    }
}
