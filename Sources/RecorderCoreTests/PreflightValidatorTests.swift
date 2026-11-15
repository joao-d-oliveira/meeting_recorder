import Foundation
import RecorderCore

func runPreflightValidatorTests() {
    let earbuds = AudioDevice(index: 3, name: "WF-1000XM6")
    let blackHole = AudioDevice(index: 0, name: "BlackHole 2ch")
    let mic = AudioDevice(index: 1, name: "MacBook Air Microphone")
    let devices = [blackHole, mic]
    let allDevices = [blackHole, mic, earbuds]

    func makeSettings(inputs: [InputConfig] = InputConfig.defaultInputs) -> RecordingSettings {
        RecordingSettings(
            inputs: inputs,
            outputFolder: FileManager.default.temporaryDirectory
                .appendingPathComponent("preflight-\(UUID().uuidString)", isDirectory: true))
    }

    func validate(
        _ settings: RecordingSettings, devices: [AudioDevice],
        ffmpegPath: String? = "/opt/homebrew/bin/ffmpeg", micAuthorized: Bool = true
    ) -> PreflightResult {
        PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: ffmpegPath, micAuthorized: micAuthorized)
    }

    // MARK: validator

    test("all inputs connected: no issues, no notices, folder created, inputs resolved") {
        let settings = makeSettings()
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: allDevices)
        try expectEqual(result.issues, [])
        try expectEqual(result.notices, [])
        try expect(result.canStart, "should be able to start")
        try expectEqual(result.resolvedInputs.count, 3)
        try expect(FileManager.default.fileExists(atPath: settings.outputFolder.path),
                   "output folder was not created")
    }

    test("disconnected skipIfMissing device is a notice, not an issue") {
        let settings = makeSettings()
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        try expectEqual(result.issues, [])
        try expectEqual(result.notices, [.inputSkipped(deviceName: "WF-1000XM6")])
        try expect(result.canStart, "skipping must not block Start")
        try expectEqual(result.resolvedInputs, [
            ResolvedInput(deviceIndex: 0, gain: 0.55),
            ResolvedInput(deviceIndex: 1, gain: 1.0),
        ])
    }

    test("no inputs is an issue") {
        let settings = makeSettings(inputs: [])
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        try expectEqual(result.issues, [.noInputs])
        try expect(!result.canStart, "empty input list must block Start")
    }

    test("an input without a device name is an issue naming its position") {
        let settings = makeSettings(inputs: [
            InputConfig(deviceName: "BlackHole 2ch", gain: 1),
            InputConfig(deviceName: "", gain: 1),
            InputConfig(deviceName: "  ", gain: 1),
        ])
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        try expectEqual(result.issues, [.inputHasNoDevice(position: 2), .inputHasNoDevice(position: 3)])
    }

    test("missing device without skipIfMissing is an issue, reported once per name") {
        let settings = makeSettings(inputs: [
            InputConfig(deviceName: "Jabra Elite 8 Active", gain: 1),
            InputConfig(deviceName: "Jabra Elite 8 Active", gain: 0.5),
            InputConfig(deviceName: "MacBook Air Microphone", gain: 1),
        ])
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        // The two Jabra rows also trip the duplicate check; the point here is one missing line.
        try expectEqual(
            result.issues.filter { $0 == .deviceMissing(name: "Jabra Elite 8 Active") }.count, 1)
    }

    test("the same device on two inputs blocks Start, reported once per name") {
        let settings = makeSettings(inputs: [
            InputConfig(deviceName: "BlackHole 2ch", gain: 0.55),
            InputConfig(deviceName: "MacBook Air Microphone", gain: 1),
            InputConfig(deviceName: "BlackHole 2ch", gain: 0.55),
            InputConfig(deviceName: "MacBook Air Microphone", gain: 1),
            InputConfig(deviceName: "BlackHole 2ch", gain: 0.55),
        ])
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        try expectEqual(result.issues, [
            .duplicateDevice(name: "BlackHole 2ch"), .duplicateDevice(name: "MacBook Air Microphone"),
        ])
        try expect(!result.canStart, "a duplicated device must block Start")
    }

    test("distinct devices and several blank inputs are not duplicates") {
        let settings = makeSettings(inputs: [
            InputConfig(deviceName: "BlackHole 2ch", gain: 1),
            InputConfig(deviceName: "MacBook Air Microphone", gain: 1),
            InputConfig(deviceName: "", gain: 1),
            InputConfig(deviceName: "", gain: 1),
        ])
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        try expectEqual(result.issues, [.inputHasNoDevice(position: 3), .inputHasNoDevice(position: 4)])
    }

    test("a duplicated device that is also missing reports both problems; skipped twins say only duplicate") {
        let missingTwice = makeSettings(inputs: [
            InputConfig(deviceName: "Jabra", gain: 1),
            InputConfig(deviceName: "Jabra", gain: 1),
        ])
        defer { try? FileManager.default.removeItem(at: missingTwice.outputFolder) }
        try expectEqual(validate(missingTwice, devices: devices).issues, [
            .duplicateDevice(name: "Jabra"), .deviceMissing(name: "Jabra"),
        ])

        let skippedTwice = makeSettings(inputs: [
            InputConfig(deviceName: "Jabra", gain: 1, skipIfMissing: true),
            InputConfig(deviceName: "Jabra", gain: 1, skipIfMissing: true),
        ])
        defer { try? FileManager.default.removeItem(at: skippedTwice.outputFolder) }
        try expectEqual(validate(skippedTwice, devices: devices).issues, [.duplicateDevice(name: "Jabra")])
    }

    test("every input skipped is an issue, and the skipped devices are still listed") {
        let settings = makeSettings(inputs: [
            InputConfig(deviceName: "WF-1000XM6", gain: 0.55, skipIfMissing: true),
            InputConfig(deviceName: "Jabra", gain: 1, skipIfMissing: true),
        ])
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        try expectEqual(result.issues, [.allInputsSkipped])
        try expectEqual(result.notices, [
            .inputSkipped(deviceName: "WF-1000XM6"), .inputSkipped(deviceName: "Jabra"),
        ])
        try expectEqual(result.resolvedInputs, [])
    }

    test("all-skipped is not added on top of a more specific input problem") {
        let settings = makeSettings(inputs: [
            InputConfig(deviceName: "WF-1000XM6", gain: 0.55, skipIfMissing: true),
            InputConfig(deviceName: "Jabra", gain: 1),
        ])
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: devices)
        try expectEqual(result.issues, [.deviceMissing(name: "Jabra")])
    }

    test("missing ffmpeg and denied mic access are reported") {
        let settings = makeSettings()
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let result = validate(settings, devices: allDevices, ffmpegPath: nil, micAuthorized: false)
        try expect(result.issues.contains(.ffmpegNotFound), "ffmpegNotFound missing")
        try expect(result.issues.contains(.microphoneAccessDenied), "microphoneAccessDenied missing")
        try expect(!result.canStart, "must not start")
    }

    test("issues and notices have user-readable descriptions") {
        try expect(PreflightIssue.ffmpegNotFound.description.contains("brew install ffmpeg"),
                   "ffmpeg issue should tell the user how to install it")
        try expect(PreflightIssue.deviceMissing(name: "Jabra").description.contains("Jabra"),
                   "device issue should name the device")
        try expect(PreflightIssue.inputHasNoDevice(position: 3).description.contains("3"),
                   "input issue should name the position")
        let duplicate = PreflightIssue.duplicateDevice(name: "BlackHole 2ch").description
        try expect(duplicate.contains("BlackHole 2ch") && duplicate.contains("more than one input"),
                   "duplicate issue should name the device and the problem: \(duplicate)")
        try expect(PreflightNotice.inputSkipped(deviceName: "WF-1000XM6").description.contains("WF-1000XM6"),
                   "notice should name the skipped device")
    }

    test("uncreateable output folder is reported") {
        let readonlyBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-ro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: readonlyBase, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readonlyBase.path)
            try? FileManager.default.removeItem(at: readonlyBase)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonlyBase.path)

        var settings = makeSettings()
        settings.outputFolder = readonlyBase.appendingPathComponent("sub", isDirectory: true)
        let result = validate(settings, devices: allDevices, ffmpegPath: "/ff")
        try expect(result.issues.contains { issue in
            if case .outputFolderNotWritable = issue { return true }
            return false
        }, "outputFolderNotWritable not reported: \(result.issues)")
    }
}
