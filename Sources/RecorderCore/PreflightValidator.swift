import Foundation

/// A problem that blocks starting a recording.
public enum PreflightIssue: Equatable, CustomStringConvertible {
    case noInputs
    /// `position` is 1-based, as shown to the user.
    case inputHasNoDevice(position: Int)
    /// The same device is selected for more than one input.
    case duplicateDevice(name: String)
    case deviceMissing(name: String)
    case allInputsSkipped
    case ffmpegNotFound
    case microphoneAccessDenied
    case outputFolderNotWritable(path: String)

    public var description: String {
        switch self {
        case .noInputs:
            return "Add at least one audio input."
        case .inputHasNoDevice(let position):
            return "Input \(position) has no device selected."
        case .duplicateDevice(let name):
            return "Device \"\(name)\" is selected for more than one input, so it would be recorded twice. "
                + "Pick a different device for each input, or remove the extra one."
        case .deviceMissing(let name):
            return "Device \"\(name)\" is not available. Reconnect it, pick another, or turn on \"Skip if missing\"."
        case .allInputsSkipped:
            return "None of the selected devices are connected, so there is nothing to record."
        case .ffmpegNotFound:
            return "ffmpeg was not found. Install it with: brew install ffmpeg"
        case .microphoneAccessDenied:
            return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .outputFolderNotWritable(let path):
            return "Cannot write to output folder: \(path). Choose another folder."
        }
    }
}

/// Something worth telling the user that does not block the recording.
public enum PreflightNotice: Equatable, CustomStringConvertible {
    case inputSkipped(deviceName: String)

    public var description: String {
        switch self {
        case .inputSkipped(let name):
            return "\"\(name)\" is not connected and was skipped."
        }
    }
}

public struct PreflightResult: Equatable {
    /// Blocking problems. Recording may start only when this is empty.
    public let issues: [PreflightIssue]
    /// Non-blocking messages (e.g. skipped devices).
    public let notices: [PreflightNotice]
    /// How the configured inputs matched the connected devices.
    public let inputs: InputResolution

    public init(issues: [PreflightIssue], notices: [PreflightNotice], inputs: InputResolution) {
        self.issues = issues
        self.notices = notices
        self.inputs = inputs
    }

    public var canStart: Bool { issues.isEmpty }

    /// The inputs to record, ready for `CommandBuilder.arguments(inputs:settings:outputURL:)`.
    /// Only meaningful when `canStart`.
    public var resolvedInputs: [ResolvedInput] { inputs.resolvedInputs }
}

public enum PreflightValidator {
    public static func validate(
        settings: RecordingSettings,
        availableDevices: [AudioDevice],
        ffmpegPath: String?,
        micAuthorized: Bool,
        fileManager: FileManager = .default
    ) -> PreflightResult {
        var issues: [PreflightIssue] = []
        var notices: [PreflightNotice] = []

        let resolution = InputResolver.resolve(inputs: settings.inputs, devices: availableDevices)

        if settings.inputs.isEmpty {
            issues.append(.noInputs)
        }
        for position in resolution.unnamedPositions {
            issues.append(.inputHasNoDevice(position: position + 1))
        }
        for name in resolution.duplicateDeviceNames {
            issues.append(.duplicateDevice(name: name))
        }
        for input in resolution.missing {
            let issue = PreflightIssue.deviceMissing(name: input.deviceName)
            if !issues.contains(issue) { issues.append(issue) }
        }
        for input in resolution.skipped {
            let notice = PreflightNotice.inputSkipped(deviceName: input.deviceName)
            if !notices.contains(notice) { notices.append(notice) }
        }
        // Only when every other input problem is absent: otherwise the root cause is above.
        if resolution.recorded.isEmpty, !resolution.skipped.isEmpty,
           resolution.missing.isEmpty, resolution.unnamedPositions.isEmpty,
           resolution.duplicateDeviceNames.isEmpty {
            issues.append(.allInputsSkipped)
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

        return PreflightResult(issues: issues, notices: notices, inputs: resolution)
    }
}
