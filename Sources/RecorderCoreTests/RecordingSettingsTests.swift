import Foundation
import RecorderCore

func runRecordingSettingsTests() {
    func decode(_ json: String) throws -> RecordingSettings {
        try JSONDecoder().decode(RecordingSettings.self, from: Data(json.utf8))
    }

    let defaults = RecordingSettings()

    // MARK: legacy migration

    test("legacy remote+mic settings migrate to two inputs with their volumes") {
        let settings = try decode("""
            {"remoteDeviceName":"BlackHole 2ch","micDeviceName":"MacBook Air Microphone",
             "remoteVolume":0.7,"micVolume":0.9,"format":"m4a","outputFolder":"file:///tmp/x/",
             "filenamePrefix":"standup","folderPerRecording":false,"ffmpegPathOverride":"/custom/ffmpeg"}
            """)
        try expectEqual(settings.inputs.map(\.deviceName), ["BlackHole 2ch", "MacBook Air Microphone"])
        try expectEqual(settings.inputs.map(\.gain), [0.7, 0.9])
        try expectEqual(settings.inputs.map(\.skipIfMissing), [false, false])
        try expectEqual(settings.format, .m4a)
        try expectEqual(settings.outputFolder.path, "/tmp/x")
        try expectEqual(settings.filenamePrefix, "standup")
        try expectEqual(settings.folderPerRecording, false)
        try expectEqual(settings.ffmpegPathOverride, "/custom/ffmpeg")
        try expectEqual(settings.transcription, TranscriptionSettings())
    }

    test("legacy migration skips a side with no device name") {
        // JSONEncoder omits nil optionals, so a never-chosen remote has no key at all.
        let micOnly = try decode(#"{"micDeviceName":"MacBook Air Microphone","remoteVolume":0.55,"micVolume":0.8}"#)
        try expectEqual(micOnly.inputs.map(\.deviceName), ["MacBook Air Microphone"])
        try expectEqual(micOnly.inputs.map(\.gain), [0.8])

        let remoteOnly = try decode(#"{"remoteDeviceName":"BlackHole 2ch","micDeviceName":"","remoteVolume":0.3,"micVolume":1}"#)
        try expectEqual(remoteOnly.inputs.map(\.deviceName), ["BlackHole 2ch"])
        try expectEqual(remoteOnly.inputs.map(\.gain), [0.3])
    }

    test("legacy settings that never chose a device get the default inputs") {
        let settings = try decode(#"{"remoteVolume":0.55,"micVolume":1,"format":"wav"}"#)
        try expectEqual(settings.inputs, InputConfig.defaultInputs)
        try expectEqual(settings.format, .wav)
    }

    test("legacy volumes fall back to the old defaults when absent or malformed") {
        let settings = try decode(#"{"remoteDeviceName":"A","micDeviceName":"B","remoteVolume":"loud"}"#)
        try expectEqual(settings.inputs.map(\.gain), [0.55, 1.0])
    }

    test("legacy keys are ignored when inputs is present") {
        let settings = try decode("""
            {"inputs":[{"deviceName":"New","gain":0.4,"skipIfMissing":true}],
             "remoteDeviceName":"Old","micDeviceName":"Older","remoteVolume":0.9,"micVolume":0.9}
            """)
        try expectEqual(settings.inputs.map(\.deviceName), ["New"])
        try expectEqual(settings.inputs.map(\.gain), [0.4])
        try expectEqual(settings.inputs.map(\.skipIfMissing), [true])
    }

    test("an explicitly empty inputs list stays empty") {
        let settings = try decode(#"{"inputs":[],"remoteDeviceName":"Old"}"#)
        try expectEqual(settings.inputs, [])
    }

    // MARK: partial / malformed JSON

    test("empty object decodes to the defaults") {
        try expectEqual(try decode("{}"), defaults)
    }

    test("one malformed field no longer resets the others") {
        let settings = try decode("""
            {"format":"ogg","filenamePrefix":"standup","folderPerRecording":"yes",
             "inputs":[{"deviceName":"BlackHole 2ch","gain":0.4}]}
            """)
        try expectEqual(settings.format, defaults.format)
        try expectEqual(settings.filenamePrefix, "standup")
        try expectEqual(settings.folderPerRecording, defaults.folderPerRecording)
        try expectEqual(settings.inputs.map(\.deviceName), ["BlackHole 2ch"])
    }

    test("missing fields take their defaults") {
        let settings = try decode(#"{"format":"mp3"}"#)
        try expectEqual(settings.format, .mp3)
        try expectEqual(settings.inputs, defaults.inputs)
        try expectEqual(settings.outputFolder, defaults.outputFolder)
        try expectEqual(settings.filenamePrefix, defaults.filenamePrefix)
        try expectEqual(settings.folderPerRecording, defaults.folderPerRecording)
        try expectEqual(settings.ffmpegPathOverride, nil)
        try expectEqual(settings.transcription, defaults.transcription)
    }

    test("malformed inputs value falls back to the default inputs") {
        let settings = try decode(#"{"inputs":"nope","format":"wav"}"#)
        try expectEqual(settings.inputs, InputConfig.defaultInputs)
        try expectEqual(settings.format, .wav)
    }

    test("a malformed input element is dropped; a partial one keeps its defaults") {
        let settings = try decode("""
            {"inputs":[{"deviceName":"A","gain":0.5,"skipIfMissing":true},"garbage",{"deviceName":"B"},
                       {"gain":0.2}]}
            """)
        try expectEqual(settings.inputs.count, 3)
        try expectEqual(settings.inputs[0].deviceName, "A")
        try expectEqual(settings.inputs[0].gain, 0.5)
        try expectEqual(settings.inputs[0].skipIfMissing, true)
        try expectEqual(settings.inputs[1].deviceName, "B")
        try expectEqual(settings.inputs[1].gain, 1.0)
        try expectEqual(settings.inputs[1].skipIfMissing, false)
        try expectEqual(settings.inputs[2].deviceName, "")
        try expectEqual(settings.inputs[2].gain, 0.2)
    }

    test("transcription settings survive, and a malformed block only resets itself") {
        let good = try decode(#"{"transcription":{"autoTranscribe":true,"interviewerName":"Ana","defaultGuestName":"V"}}"#)
        try expectEqual(good.transcription.autoTranscribe, true)
        try expectEqual(good.transcription.interviewerName, "Ana")

        let bad = try decode(#"{"transcription":{"autoTranscribe":"sure"},"format":"wav"}"#)
        try expectEqual(bad.transcription, TranscriptionSettings())
        try expectEqual(bad.format, .wav)
    }

    test("data that is not a JSON object still throws") {
        var threw = false
        do { _ = try decode("[1,2,3]") } catch { threw = true }
        try expect(threw, "a non-object should not decode")
    }

    test("input ids survive a decode") {
        let id = UUID()
        let settings = try decode(#"{"inputs":[{"id":"\#(id.uuidString)","deviceName":"A","gain":1}]}"#)
        try expectEqual(settings.inputs.first?.id, id)
    }

    // MARK: round trip

    test("encode then decode round-trips, including input ids") {
        var settings = RecordingSettings()
        settings.inputs = [
            InputConfig(deviceName: "BlackHole 2ch", gain: 0.55),
            InputConfig(deviceName: "MacBook Air Microphone", gain: 1.0, skipIfMissing: true),
        ]
        settings.format = .mp3
        settings.outputFolder = URL(fileURLWithPath: "/tmp/round-trip")
        settings.transcription = TranscriptionSettings(autoTranscribe: true, interviewerName: "Ana")
        let data = try JSONEncoder().encode(settings)
        try expectEqual(try JSONDecoder().decode(RecordingSettings.self, from: data), settings)
    }

    test("encoding writes inputs and never the legacy keys") {
        let data = try JSONEncoder().encode(RecordingSettings())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        try expect(object["inputs"] != nil, "inputs key missing")
        try expect(object["transcription"] != nil, "transcription key missing")
        for legacy in ["remoteDeviceName", "micDeviceName", "remoteVolume", "micVolume"] {
            try expect(object[legacy] == nil, "legacy key \(legacy) was written")
        }
    }
}
