import Foundation
import RecorderCore

func runSettingsStoreTests() {
    let suiteName = "MeetingRecorderTests"

    func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    test("load returns defaults when nothing saved") {
        let store = SettingsStore(defaults: freshDefaults())
        let settings = store.load()
        try expectEqual(settings.inputs, InputConfig.defaultInputs)
        try expectEqual(settings.format, .flac)
        try expectEqual(settings.transcription, TranscriptionSettings())
    }

    test("save then load round-trips all fields") {
        let store = SettingsStore(defaults: freshDefaults())
        var settings = RecordingSettings()
        settings.inputs = [
            InputConfig(deviceName: "BlackHole 2ch", gain: 0.7),
            InputConfig(deviceName: "MacBook Air Microphone", gain: 0.9, skipIfMissing: true),
            InputConfig(deviceName: "USB Mic", gain: 1.25),
        ]
        settings.format = .m4a
        settings.outputFolder = URL(fileURLWithPath: "/tmp/elsewhere")
        settings.filenamePrefix = "standup"
        settings.folderPerRecording = false
        settings.ffmpegPathOverride = "/custom/ffmpeg"
        settings.transcription = TranscriptionSettings(
            autoTranscribe: true, interviewerName: "Ana", defaultGuestName: "Visitor",
            pipelineDirectoryOverride: "/custom/pipeline")
        store.save(settings)
        try expectEqual(store.load(), settings)
    }

    test("corrupt stored data falls back to defaults") {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        try expectEqual(store.load(), RecordingSettings())
    }

    test("settings saved by the two-input build migrate on load") {
        let defaults = freshDefaults()
        let legacy = """
            {"remoteDeviceName":"BlackHole 2ch","micDeviceName":"MacBook Air Microphone",
             "remoteVolume":0.7,"micVolume":0.9,"format":"wav","filenamePrefix":"standup",
             "folderPerRecording":false,"outputFolder":"file:///tmp/elsewhere/"}
            """
        defaults.set(Data(legacy.utf8), forKey: "settings.v1")
        let settings = SettingsStore(defaults: defaults).load()
        try expectEqual(settings.inputs.map(\.deviceName), ["BlackHole 2ch", "MacBook Air Microphone"])
        try expectEqual(settings.inputs.map(\.gain), [0.7, 0.9])
        try expectEqual(settings.format, .wav)
        try expectEqual(settings.filenamePrefix, "standup")
        try expectEqual(settings.folderPerRecording, false)
    }

    test("a migrated setting is saved in the new shape and loads back identically") {
        let defaults = freshDefaults()
        let legacy = #"{"remoteDeviceName":"BlackHole 2ch","remoteVolume":0.4,"micVolume":1}"#
        defaults.set(Data(legacy.utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        let migrated = store.load()
        store.save(migrated)
        try expectEqual(store.load(), migrated)
    }
}
