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
        try expectEqual(settings.remoteVolume, 0.55)
        try expectEqual(settings.micVolume, 1.0)
        try expectEqual(settings.format, .flac)
        try expectEqual(settings.remoteDeviceName, nil)
    }

    test("save then load round-trips all fields") {
        let store = SettingsStore(defaults: freshDefaults())
        var settings = RecordingSettings()
        settings.remoteDeviceName = "BlackHole 2ch"
        settings.micDeviceName = "MacBook Air Microphone"
        settings.remoteVolume = 0.7
        settings.micVolume = 0.9
        settings.format = .m4a
        settings.outputFolder = URL(fileURLWithPath: "/tmp/elsewhere")
        settings.filenamePrefix = "standup"
        settings.folderPerRecording = false
        settings.ffmpegPathOverride = "/custom/ffmpeg"
        store.save(settings)
        try expectEqual(store.load(), settings)
    }

    test("corrupt stored data falls back to defaults") {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        try expectEqual(store.load(), RecordingSettings())
    }
}
