import Foundation
import RecorderCore

let deviceListFixture = """
[AVFoundation indev @ 0x9f6c20140] AVFoundation video devices:
[AVFoundation indev @ 0x9f6c20140] [0] FaceTime HD Camera
[AVFoundation indev @ 0x9f6c20140] AVFoundation audio devices:
[AVFoundation indev @ 0x9f6c20140] [0] BlackHole 2ch
[AVFoundation indev @ 0x9f6c20140] [1] MacBook Air Microphone
[AVFoundation indev @ 0x9f6c20140] [2] Microsoft Teams Audio
[AVFoundation indev @ 0x9f6c20140] [3] BlackHole 16ch
[in#0 @ 0x9f6c20000] Error opening input: Input/output error
Error opening input file .
Error opening input files: Input/output error
"""

func runDeviceListParserTests() {
    test("parses audio devices with indices and names") {
        let devices = DeviceListParser.parseAudioDevices(from: deviceListFixture)
        try expectEqual(devices, [
            AudioDevice(index: 0, name: "BlackHole 2ch"),
            AudioDevice(index: 1, name: "MacBook Air Microphone"),
            AudioDevice(index: 2, name: "Microsoft Teams Audio"),
            AudioDevice(index: 3, name: "BlackHole 16ch"),
        ])
    }

    test("ignores video devices") {
        let devices = DeviceListParser.parseAudioDevices(from: deviceListFixture)
        try expect(!devices.contains { $0.name.contains("FaceTime") }, "video device leaked into audio list")
    }

    test("returns empty for output with no audio section") {
        try expectEqual(DeviceListParser.parseAudioDevices(from: "garbage\nmore garbage"), [])
    }
}
