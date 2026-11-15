import Foundation

/// An input that will be recorded: the user's config plus where it was found.
public struct RecordedInput: Equatable {
    public let config: InputConfig
    public let resolved: ResolvedInput

    public init(config: InputConfig, resolved: ResolvedInput) {
        self.config = config
        self.resolved = resolved
    }
}

/// The outcome of matching configured inputs against the currently connected devices.
public struct InputResolution: Equatable {
    /// Inputs that will be recorded, in configured order. Position here is the ffmpeg input
    /// number, and so also the level-meter index.
    public let recorded: [RecordedInput]
    /// Disconnected inputs with `skipIfMissing`: dropped from the recording (a notice).
    public let skipped: [InputConfig]
    /// Disconnected inputs without `skipIfMissing`: these block the recording.
    public let missing: [InputConfig]
    /// Positions (0-based, in the configured list) of inputs with a blank device name: blocking.
    public let unnamedPositions: [Int]
    /// Device names chosen by more than one named input, each listed once in order of first
    /// appearance: blocking, because ffmpeg would open the device twice and mix it in twice.
    public let duplicateDeviceNames: [String]

    public init(
        recorded: [RecordedInput], skipped: [InputConfig],
        missing: [InputConfig], unnamedPositions: [Int],
        duplicateDeviceNames: [String] = []
    ) {
        self.recorded = recorded
        self.skipped = skipped
        self.missing = missing
        self.unnamedPositions = unnamedPositions
        self.duplicateDeviceNames = duplicateDeviceNames
    }

    /// What `CommandBuilder.arguments(inputs:settings:outputURL:)` takes.
    public var resolvedInputs: [ResolvedInput] { recorded.map(\.resolved) }
}

public enum InputResolver {
    /// Turns configured inputs plus the scanned devices into the inputs to record.
    /// Devices match by exact name (like record-meeting.sh); the first device with that name wins.
    public static func resolve(inputs: [InputConfig], devices: [AudioDevice]) -> InputResolution {
        var recorded: [RecordedInput] = []
        var skipped: [InputConfig] = []
        var missing: [InputConfig] = []
        var unnamedPositions: [Int] = []
        var seenNames: Set<String> = []
        var duplicateDeviceNames: [String] = []

        for (position, input) in inputs.enumerated() {
            if input.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                unnamedPositions.append(position)
                continue
            }
            // Same exact-name comparison as the device lookup below.
            if !seenNames.insert(input.deviceName).inserted,
               !duplicateDeviceNames.contains(input.deviceName) {
                duplicateDeviceNames.append(input.deviceName)
            }
            if let device = devices.first(where: { $0.name == input.deviceName }) {
                recorded.append(RecordedInput(
                    config: input,
                    resolved: ResolvedInput(deviceIndex: device.index, gain: input.gain)))
            } else if input.skipIfMissing {
                skipped.append(input)
            } else {
                missing.append(input)
            }
        }
        return InputResolution(
            recorded: recorded, skipped: skipped, missing: missing,
            unnamedPositions: unnamedPositions, duplicateDeviceNames: duplicateDeviceNames)
    }

    /// Names offered by an input's device picker: every scanned device name once (two devices
    /// can share a name, and the picker needs unique tags), in scan order, plus `current` when
    /// it isn't connected right now so the saved selection stays visible.
    public static func deviceChoices(devices: [AudioDevice], current: String) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        for device in devices where seen.insert(device.name).inserted {
            names.append(device.name)
        }
        if !current.isEmpty, !seen.contains(current) { names.append(current) }
        return names
    }

    /// Convenience: just the inputs to hand to the command builder.
    public static func resolvedInputs(for inputs: [InputConfig], devices: [AudioDevice]) -> [ResolvedInput] {
        resolve(inputs: inputs, devices: devices).resolvedInputs
    }
}
