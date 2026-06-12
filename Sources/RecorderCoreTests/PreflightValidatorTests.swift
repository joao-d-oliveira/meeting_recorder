import Foundation
import RecorderCore

func runPreflightValidatorTests() {
    let devices = [
        AudioDevice(index: 0, name: "BlackHole 2ch"),
        AudioDevice(index: 1, name: "MacBook Air Microphone"),
    ]

    func validSettings() -> RecordingSettings {
        var settings = RecordingSettings(outputFolder: FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-\(UUID().uuidString)", isDirectory: true))
        settings.remoteDeviceName = "BlackHole 2ch"
        settings.micDeviceName = "MacBook Air Microphone"
        return settings
    }

    test("all good yields no issues and creates the output folder") {
        let settings = validSettings()
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: "/opt/homebrew/bin/ffmpeg", micAuthorized: true)
        try expectEqual(issues, [])
        try expect(FileManager.default.fileExists(atPath: settings.outputFolder.path),
                   "output folder was not created")
        try? FileManager.default.removeItem(at: settings.outputFolder)
    }

    test("missing selections are reported") {
        var settings = validSettings()
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        settings.remoteDeviceName = nil
        settings.micDeviceName = nil
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: "/ff", micAuthorized: true)
        try expect(issues.contains(.noRemoteSelected), "noRemoteSelected missing")
        try expect(issues.contains(.noMicSelected), "noMicSelected missing")
    }

    test("selected device that disappeared is reported by name") {
        var settings = validSettings()
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        settings.remoteDeviceName = "Jabra Elite 8 Active"
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: "/ff", micAuthorized: true)
        try expect(issues.contains(.deviceMissing(name: "Jabra Elite 8 Active")),
                   "deviceMissing not reported: \(issues)")
    }

    test("missing ffmpeg and denied mic access are reported") {
        let settings = validSettings()
        defer { try? FileManager.default.removeItem(at: settings.outputFolder) }
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: nil, micAuthorized: false)
        try expect(issues.contains(.ffmpegNotFound), "ffmpegNotFound missing")
        try expect(issues.contains(.microphoneAccessDenied), "microphoneAccessDenied missing")
    }

    test("issues have user-readable descriptions") {
        try expect(PreflightIssue.ffmpegNotFound.description.contains("brew install ffmpeg"),
                   "ffmpeg issue should tell the user how to install it")
        try expect(PreflightIssue.deviceMissing(name: "Jabra").description.contains("Jabra"),
                   "device issue should name the device")
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

        var settings = validSettings()
        settings.outputFolder = readonlyBase.appendingPathComponent("sub", isDirectory: true)
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: "/ff", micAuthorized: true)
        try expect(issues.contains { issue in
            if case .outputFolderNotWritable = issue { return true }
            return false
        }, "outputFolderNotWritable not reported: \(issues)")
    }
}
