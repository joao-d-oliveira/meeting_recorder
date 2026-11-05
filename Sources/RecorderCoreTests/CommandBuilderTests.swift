import Foundation
import RecorderCore

func runCommandBuilderTests() {
    let expectedGraph = "[0:a]aresample=48000,aformat=channel_layouts=mono,volume=0.55,"
        + "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[remote];"
        + "[1:a]aresample=48000,aformat=channel_layouts=mono,volume=1.00,"
        + "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[mic];"
        + "[remote][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,"
        + "alimiter=limit=0.95[mixed]"

    test("builds full default flac command") {
        let args = CommandBuilder.arguments(
            remoteIndex: 0, micIndex: 1,
            settings: RecordingSettings(),
            outputURL: URL(fileURLWithPath: "/tmp/out/meeting.flac"))
        try expectEqual(args, [
            "-hide_banner", "-nostats",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":0",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":1",
            "-filter_complex", expectedGraph,
            "-map", "[mixed]",
            "-c:a", "flac",
            "-flush_packets", "1",
            "-n",
            "/tmp/out/meeting.flac",
        ])
    }

    test("applies custom volumes with two decimals") {
        var settings = RecordingSettings()
        settings.remoteVolume = 0.8
        settings.micVolume = 1.25
        let args = CommandBuilder.arguments(
            remoteIndex: 0, micIndex: 1, settings: settings,
            outputURL: URL(fileURLWithPath: "/tmp/x.flac"))
        let graph = args[args.firstIndex(of: "-filter_complex")! + 1]
        try expect(graph.contains("volume=0.80"), "remote volume missing: \(graph)")
        try expect(graph.contains("volume=1.25"), "mic volume missing: \(graph)")
    }

    test("uses selected device indices") {
        let args = CommandBuilder.arguments(
            remoteIndex: 2, micIndex: 3, settings: RecordingSettings(),
            outputURL: URL(fileURLWithPath: "/tmp/x.flac"))
        let inputs = args.indices.filter { args[$0] == "-i" }.map { args[$0 + 1] }
        try expectEqual(inputs, [":2", ":3"])
    }

    test("maps formats to codec args") {
        for (format, expected) in [
            (AudioFormat.flac, ["-c:a", "flac"]),
            (.wav, ["-c:a", "pcm_s16le"]),
            (.mp3, ["-c:a", "libmp3lame", "-q:a", "2"]),
            (.m4a, ["-c:a", "aac", "-b:a", "192k"]),
        ] {
            var settings = RecordingSettings()
            settings.format = format
            let args = CommandBuilder.arguments(
                remoteIndex: 0, micIndex: 1, settings: settings,
                outputURL: URL(fileURLWithPath: "/tmp/x.\(format.rawValue)"))
            let codecStart = args.firstIndex(of: "-c:a")!
            try expectEqual(Array(args[codecStart..<(codecStart + expected.count)]), expected)
        }
    }

    test("fragments m4a so a killed recording stays playable") {
        var settings = RecordingSettings()
        settings.format = .m4a
        let args = CommandBuilder.arguments(
            remoteIndex: 0, micIndex: 1, settings: settings,
            outputURL: URL(fileURLWithPath: "/tmp/out/meeting.m4a"))
        try expectEqual(Array(args.suffix(8)), [
            "-movflags", "+frag_keyframe+empty_moov", "-frag_duration", "1000000",
            "-flush_packets", "1",
            "-n", "/tmp/out/meeting.m4a",
        ])
    }

    test("only m4a gets movflags; every format flushes packets") {
        for format in AudioFormat.allCases {
            var settings = RecordingSettings()
            settings.format = format
            let args = CommandBuilder.arguments(
                remoteIndex: 0, micIndex: 1, settings: settings,
                outputURL: URL(fileURLWithPath: "/tmp/x.\(format.rawValue)"))
            try expectEqual(args.contains("-movflags"), format == .m4a)
            let flush = args.firstIndex(of: "-flush_packets")
            try expect(flush != nil && args[flush! + 1] == "1", "\(format): -flush_packets 1 missing")
            try expect(flush! < args.firstIndex(of: "-n")!, "\(format): -flush_packets must precede -n")
        }
    }

    test("exposes ametadata instance ids for the level parser") {
        try expectEqual(CommandBuilder.remoteAmetadataInstanceID, 4)
        try expectEqual(CommandBuilder.micAmetadataInstanceID, 9)
    }
}
