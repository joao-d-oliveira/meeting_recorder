import Foundation

/// One audio input mixed into the recording (an avfoundation audio device, looked up by name).
public struct InputConfig: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Device name exactly as ffmpeg's avfoundation device list prints it.
    public var deviceName: String
    /// Linear gain applied before mixing (ffmpeg `volume=`).
    public var gain: Double
    /// When true and the device is not connected, the recording starts without it
    /// (a non-blocking notice) instead of failing preflight.
    public var skipIfMissing: Bool

    public init(id: UUID = UUID(), deviceName: String, gain: Double, skipIfMissing: Bool = false) {
        self.id = id
        self.deviceName = deviceName
        self.gain = gain
        self.skipIfMissing = skipIfMissing
    }

    private enum CodingKeys: String, CodingKey {
        case id, deviceName, gain, skipIfMissing
    }

    /// Per-field tolerant: a missing or malformed field takes its default instead of failing
    /// the whole input (an empty device name is then reported by preflight).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        deviceName = (try? container.decodeIfPresent(String.self, forKey: .deviceName)) ?? ""
        gain = (try? container.decodeIfPresent(Double.self, forKey: .gain)) ?? 1.0
        skipIfMissing = (try? container.decodeIfPresent(Bool.self, forKey: .skipIfMissing)) ?? false
    }

    /// Mirrors ~/.claude/skills/interview-transcribe/scripts/record-meeting.sh:
    /// earbuds + BlackHole 2ch at 0.55, MacBook Air mic at 1.00.
    public static let defaultInputs: [InputConfig] = [
        InputConfig(deviceName: "WF-1000XM6", gain: 0.55, skipIfMissing: true),
        InputConfig(deviceName: "BlackHole 2ch", gain: 0.55),
        InputConfig(deviceName: "MacBook Air Microphone", gain: 1.0),
    ]
}

/// An input whose device was found at record time: the avfoundation index plus its gain.
public struct ResolvedInput: Equatable {
    public let deviceIndex: Int
    public let gain: Double

    public init(deviceIndex: Int, gain: Double) {
        self.deviceIndex = deviceIndex
        self.gain = gain
    }
}
