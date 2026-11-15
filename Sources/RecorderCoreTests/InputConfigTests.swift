import Foundation
import RecorderCore

func runInputConfigTests() {
    let earbuds = AudioDevice(index: 3, name: "WF-1000XM6")
    let blackHole = AudioDevice(index: 0, name: "BlackHole 2ch")
    let mic = AudioDevice(index: 1, name: "MacBook Air Microphone")
    let devices = [blackHole, mic]
    let allDevices = [blackHole, mic, earbuds]

    func decode(_ json: String) throws -> InputConfig {
        try JSONDecoder().decode(InputConfig.self, from: Data(json.utf8))
    }

    // MARK: decoding

    test("input decoding is per-field tolerant") {
        let partial = try decode(#"{"deviceName":"BlackHole 2ch"}"#)
        try expectEqual(partial.deviceName, "BlackHole 2ch")
        try expectEqual(partial.gain, 1.0)
        try expectEqual(partial.skipIfMissing, false)

        let wrongTypes = try decode(#"{"deviceName":"X","gain":"loud","skipIfMissing":"yes"}"#)
        try expectEqual(wrongTypes.deviceName, "X")
        try expectEqual(wrongTypes.gain, 1.0)
        try expectEqual(wrongTypes.skipIfMissing, false)

        let empty = try decode("{}")
        try expectEqual(empty.deviceName, "")
    }

    test("input encode/decode round-trips, keeping the id") {
        let input = InputConfig(deviceName: "WF-1000XM6", gain: 0.55, skipIfMissing: true)
        let data = try JSONEncoder().encode(input)
        try expectEqual(try JSONDecoder().decode(InputConfig.self, from: data), input)
    }

    test("default inputs mirror record-meeting.sh") {
        try expectEqual(InputConfig.defaultInputs.map(\.deviceName),
                        ["WF-1000XM6", "BlackHole 2ch", "MacBook Air Microphone"])
        try expectEqual(InputConfig.defaultInputs.map(\.gain), [0.55, 0.55, 1.0])
        try expectEqual(InputConfig.defaultInputs.map(\.skipIfMissing), [true, false, false])
    }

    // MARK: resolver

    test("resolver keeps configured order and carries each device index and gain") {
        let inputs = InputConfig.defaultInputs
        let resolution = InputResolver.resolve(inputs: inputs, devices: allDevices)
        try expectEqual(resolution.resolvedInputs, [
            ResolvedInput(deviceIndex: 3, gain: 0.55),
            ResolvedInput(deviceIndex: 0, gain: 0.55),
            ResolvedInput(deviceIndex: 1, gain: 1.0),
        ])
        try expectEqual(resolution.recorded.map(\.config), inputs)
        try expectEqual(resolution.skipped, [])
        try expectEqual(resolution.missing, [])
        try expectEqual(resolution.unnamedPositions, [])
    }

    test("resolver drops a disconnected skipIfMissing input but keeps the others' order") {
        let resolution = InputResolver.resolve(inputs: InputConfig.defaultInputs, devices: devices)
        try expectEqual(resolution.resolvedInputs, [
            ResolvedInput(deviceIndex: 0, gain: 0.55),
            ResolvedInput(deviceIndex: 1, gain: 1.0),
        ])
        try expectEqual(resolution.skipped.map(\.deviceName), ["WF-1000XM6"])
        try expectEqual(resolution.missing, [])
    }

    test("resolver separates blocking missing devices and unnamed inputs") {
        let inputs = [
            InputConfig(deviceName: "Jabra", gain: 1),
            InputConfig(deviceName: "", gain: 1),
            InputConfig(deviceName: "   ", gain: 1),
            InputConfig(deviceName: "BlackHole 2ch", gain: 0.3),
        ]
        let resolution = InputResolver.resolve(inputs: inputs, devices: devices)
        try expectEqual(resolution.missing.map(\.deviceName), ["Jabra"])
        try expectEqual(resolution.unnamedPositions, [1, 2])
        try expectEqual(resolution.resolvedInputs, [ResolvedInput(deviceIndex: 0, gain: 0.3)])
    }

    test("resolver matches device names exactly, first match wins") {
        let twins = [AudioDevice(index: 5, name: "USB Mic"), AudioDevice(index: 6, name: "USB Mic")]
        let inputs = [
            InputConfig(deviceName: "USB Mic", gain: 1),
            InputConfig(deviceName: "usb mic", gain: 1),
        ]
        let resolution = InputResolver.resolve(inputs: inputs, devices: twins)
        try expectEqual(resolution.resolvedInputs, [ResolvedInput(deviceIndex: 5, gain: 1)])
        try expectEqual(resolution.missing.map(\.deviceName), ["usb mic"])
    }

    test("resolvedInputs(for:devices:) matches resolve(...).resolvedInputs") {
        let inputs = InputConfig.defaultInputs
        try expectEqual(
            InputResolver.resolvedInputs(for: inputs, devices: allDevices),
            InputResolver.resolve(inputs: inputs, devices: allDevices).resolvedInputs)
    }
}
