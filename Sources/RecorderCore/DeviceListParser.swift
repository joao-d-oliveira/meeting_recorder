import Foundation

public enum DeviceListParser {
    private static let deviceRegex = try! NSRegularExpression(pattern: #"\] \[(\d+)\] (.+)$"#)

    public static func parseAudioDevices(from stderr: String) -> [AudioDevice] {
        var inAudioSection = false
        var devices: [AudioDevice] = []
        for rawLine in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.contains("AVFoundation audio devices:") { inAudioSection = true; continue }
            if line.contains("AVFoundation video devices:") { inAudioSection = false; continue }
            guard inAudioSection, line.contains("AVFoundation indev") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = deviceRegex.firstMatch(in: line, range: range),
                  let indexRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let index = Int(line[indexRange]) else { continue }
            devices.append(AudioDevice(index: index, name: String(line[nameRange])))
        }
        return devices
    }
}
