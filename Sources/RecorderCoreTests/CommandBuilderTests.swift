import Foundation
import RecorderCore

/// Canonical form of a filtergraph for comparing graphs that differ only in
/// whitespace and pad label names. Stream specifiers like `[0:a]` are kept; every other
/// label is renamed by order of first appearance, so the wiring is still compared.
private func canonicalGraph(_ graph: String) -> String {
    let compact = graph.filter { !$0.isWhitespace }
    let regex = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
    let ns = compact as NSString
    var names: [String: Int] = [:]
    var result = ""
    var cursor = 0
    for match in regex.matches(in: compact, range: NSRange(location: 0, length: ns.length)) {
        result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        let label = ns.substring(with: match.range(at: 1))
        if label.hasSuffix(":a") {
            result += "[\(label)]"
        } else {
            if names[label] == nil { names[label] = names.count }
            result += "[L\(names[label]!)]"
        }
        cursor = match.range.location + match.range.length
    }
    return result + ns.substring(from: cursor)
}

private func filterComplex(of args: [String]) -> String {
    args[args.firstIndex(of: "-filter_complex")! + 1]
}

private let meterFilters = ",astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level"

/// The filter_complex string record-meeting.sh passes to ffmpeg, with its gain variables
/// substituted. Nil when the skill isn't installed on this machine.
private func filterGraphFromRecordMeetingScript() -> String? {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills/interview-transcribe/scripts/record-meeting.sh").path
    guard let script = try? String(contentsOfFile: path, encoding: .utf8),
          let open = script.range(of: "-filter_complex \"") else { return nil }
    let rest = script[open.upperBound...]
    guard let close = rest.firstIndex(of: "\"") else { return nil }
    // Inside double quotes a backslash-newline is a line continuation: it vanishes.
    var graph = String(rest[..<close]).replacingOccurrences(of: "\\\n", with: "")

    let assignment = try! NSRegularExpression(pattern: #"^(GAIN_[A-Z_]+)=(\S+)\s*$"#, options: .anchorsMatchLines)
    let ns = script as NSString
    for match in assignment.matches(in: script, range: NSRange(location: 0, length: ns.length)) {
        let name = ns.substring(with: match.range(at: 1))
        let value = ns.substring(with: match.range(at: 2))
        graph = graph.replacingOccurrences(of: "$\(name)", with: value)
    }
    return graph
}

func runCommandBuilderTests() {
    let outputURL = URL(fileURLWithPath: "/tmp/out/meeting.flac")
    let defaultGains = [0.55, 0.55, 1.0]
    func resolved(_ gains: [Double], firstIndex: Int = 0) -> [ResolvedInput] {
        gains.enumerated().map { ResolvedInput(deviceIndex: firstIndex + $0.offset, gain: $0.element) }
    }

    let expectedGraph = "[0:a]aresample=48000,aformat=channel_layouts=mono,volume=0.55,"
        + "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[in0];"
        + "[1:a]aresample=48000,aformat=channel_layouts=mono,volume=0.55,"
        + "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[in1];"
        + "[2:a]aresample=48000,aformat=channel_layouts=mono,volume=1.00,"
        + "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[in2];"
        + "[in0][in1][in2]amix=inputs=3:duration=longest:dropout_transition=0:normalize=0,"
        + "alimiter=limit=0.95[mixed]"

    test("builds the full three-input flac command") {
        let inputs = [
            ResolvedInput(deviceIndex: 4, gain: 0.55),
            ResolvedInput(deviceIndex: 0, gain: 0.55),
            ResolvedInput(deviceIndex: 2, gain: 1.0),
        ]
        let args = CommandBuilder.arguments(
            inputs: inputs, settings: RecordingSettings(), outputURL: outputURL)
        try expectEqual(args, [
            "-hide_banner", "-nostats",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":4",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":0",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":2",
            "-filter_complex", expectedGraph,
            "-map", "[mixed]",
            "-c:a", "flac",
            "-flush_packets", "1",
            "-n",
            "/tmp/out/meeting.flac",
        ])
    }

    test("one input per resolved device, in order, and amix sized to match") {
        for count in 1...5 {
            let args = CommandBuilder.arguments(
                inputs: resolved(Array(repeating: 1.0, count: count), firstIndex: 7),
                settings: RecordingSettings(), outputURL: outputURL)
            let devices = args.indices.filter { args[$0] == "-i" }.map { args[$0 + 1] }
            try expectEqual(devices, (0..<count).map { ":\(7 + $0)" })
            let queueSizes = args.indices.filter { args[$0] == "-thread_queue_size" }.map { args[$0 + 1] }
            try expectEqual(queueSizes, Array(repeating: "1024", count: count))
            let graph = filterComplex(of: args)
            try expect(graph.contains("amix=inputs=\(count):"), "amix count wrong: \(graph)")
            try expect(graph.contains("volume=1.00,"), "volume missing: \(graph)")
            try expectEqual(graph.components(separatedBy: "[in").count - 1, count * 2)
        }
    }

    test("gains are formatted with two decimals and a dot") {
        let args = CommandBuilder.arguments(
            inputs: resolved([0.8, 1.25, 0]), settings: RecordingSettings(), outputURL: outputURL)
        let graph = filterComplex(of: args)
        try expect(graph.contains("volume=0.80,"), "0.8 missing: \(graph)")
        try expect(graph.contains("volume=1.25,"), "1.25 missing: \(graph)")
        try expect(graph.contains("volume=0.00,"), "zero missing: \(graph)")
        try expect(!graph.contains("volume=0,"), "unformatted gain leaked: \(graph)")
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
                inputs: resolved(defaultGains), settings: settings,
                outputURL: URL(fileURLWithPath: "/tmp/x.\(format.rawValue)"))
            let codecStart = args.firstIndex(of: "-c:a")!
            try expectEqual(Array(args[codecStart..<(codecStart + expected.count)]), expected)
        }
    }

    test("fragments m4a so a killed recording stays playable") {
        var settings = RecordingSettings()
        settings.format = .m4a
        let args = CommandBuilder.arguments(
            inputs: resolved(defaultGains), settings: settings,
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
                inputs: resolved(defaultGains), settings: settings,
                outputURL: URL(fileURLWithPath: "/tmp/x.\(format.rawValue)"))
            try expectEqual(args.contains("-movflags"), format == .m4a)
            let flush = args.firstIndex(of: "-flush_packets")
            try expect(flush != nil && args[flush! + 1] == "1", "\(format): -flush_packets 1 missing")
            try expect(flush! < args.firstIndex(of: "-n")!, "\(format): -flush_packets must precede -n")
        }
    }

    test("ametadata instance ids follow 5 filters per input branch") {
        try expectEqual(CommandBuilder.ametadataInstanceID(forInput: 0), 4)
        try expectEqual(CommandBuilder.ametadataInstanceID(forInput: 1), 9)
        try expectEqual(CommandBuilder.ametadataInstanceID(forInput: 2), 14)
        try expectEqual(CommandBuilder.ametadataInstanceID(forInput: 7), 39)
    }

    test("instance ids map back to input positions; other filters map to nil") {
        for index in 0..<10 {
            try expectEqual(
                CommandBuilder.inputIndex(forAmetadataInstanceID: CommandBuilder.ametadataInstanceID(forInput: index)),
                index)
        }
        for id in [0, 1, 2, 3, 5, 8, 10, 13, 15, -1, -6] {
            try expect(CommandBuilder.inputIndex(forAmetadataInstanceID: id) == nil, "id \(id) should not map")
        }
    }

    test("each branch's ametadata filter sits at the advertised instance id") {
        // Count filters left to right in the generated graph: the ametadata ones must land
        // on 5*i+4, otherwise the level parser would read the wrong input.
        let graph = filterComplex(of: CommandBuilder.arguments(
            inputs: resolved(defaultGains), settings: RecordingSettings(), outputURL: outputURL))
        var position = 0
        var ametadataPositions: [Int] = []
        for branch in graph.components(separatedBy: ";").dropLast() {
            for filter in branch.components(separatedBy: ",") {
                if filter.contains("ametadata=") { ametadataPositions.append(position) }
                position += 1
            }
        }
        try expectEqual(ametadataPositions, (0..<3).map { CommandBuilder.ametadataInstanceID(forInput: $0) })
    }

    test("filtergraph without meters equals record-meeting.sh's graph") {
        // Hard-coded copy of the script's graph (gains substituted), so parity is checked
        // even where the skill isn't installed.
        let scriptGraph = """
            [0:a]aresample=48000,aformat=channel_layouts=mono,volume=0.55[r1]; \
            [1:a]aresample=48000,aformat=channel_layouts=mono,volume=0.55[r2]; \
            [2:a]aresample=48000,aformat=channel_layouts=mono,volume=1.00[mic]; \
            [r1][r2][mic]amix=inputs=3:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95[mixed]
            """
        let args = CommandBuilder.arguments(
            inputs: resolved(defaultGains), settings: RecordingSettings(), outputURL: outputURL)
        let stripped = filterComplex(of: args).replacingOccurrences(of: meterFilters, with: "")
        try expect(!stripped.contains("astats") && !stripped.contains("ametadata"), "meter filters remain")
        try expectEqual(canonicalGraph(stripped), canonicalGraph(scriptGraph))
        try expectEqual(
            canonicalGraph(CommandBuilder.filterGraph(gains: defaultGains, includeMeters: false)),
            canonicalGraph(scriptGraph))
    }

    test("default inputs yield the same graph as the installed record-meeting.sh") {
        guard let live = filterGraphFromRecordMeetingScript() else {
            print("  (skipped: record-meeting.sh not found on this machine)")
            return
        }
        try expect(!live.contains("$"), "unsubstituted variable in script graph: \(live)")
        let defaults = InputConfig.defaultInputs.map(\.gain)
        try expectEqual(
            canonicalGraph(CommandBuilder.filterGraph(gains: defaults, includeMeters: false)),
            canonicalGraph(live))
    }

    test("canonicalGraph tells different wiring apart") {
        let a = "[0:a]volume=1[x];[1:a]volume=1[y];[x][y]amix=inputs=2[m]"
        let b = "[0:a]volume=1[x];[1:a]volume=1[y];[y][x]amix=inputs=2[m]"
        try expect(canonicalGraph(a) != canonicalGraph(b), "swapped inputs should differ")
        try expectEqual(canonicalGraph(a), canonicalGraph("[0:a]volume=1[p]; [1:a]volume=1[q]; [p][q]amix=inputs=2[z]"))
    }
}

private func runProcess(_ path: String, _ arguments: [String]) throws -> (status: Int32, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardError = pipe
    process.standardOutput = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Runs the real ffmpeg on the graph the app generates, with synthetic `sine` sources
/// standing in for the avfoundation inputs. No audio hardware is touched.
func runFFmpegGraphValidationTests() {
    let ffmpeg = "/opt/homebrew/bin/ffmpeg"
    let allGains = [0.55, 0.55, 1.0]

    for count in 1...3 {
        test("real ffmpeg accepts the \(count)-input graph and meters every input") {
            guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
                print("  (skipped: \(ffmpeg) not found)")
                return
            }
            let inputs = allGains.prefix(count).enumerated().map {
                ResolvedInput(deviceIndex: $0.offset, gain: $0.element)
            }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("graph-check-\(UUID().uuidString).flac")
            defer { try? FileManager.default.removeItem(at: output) }

            // The app's own arguments: only the avfoundation inputs are replaced.
            let appArguments = CommandBuilder.arguments(
                inputs: inputs, settings: RecordingSettings(), outputURL: output)
            var arguments = ["-hide_banner", "-nostats"]
            for index in 0..<count {
                arguments += ["-f", "lavfi", "-i", "sine=frequency=\(220 * (index + 1)):duration=2"]
            }
            arguments += [
                "-filter_complex", filterComplex(of: appArguments),
                "-map", "[mixed]", "-c:a", "flac", "-y", output.path,
            ]

            let result = try runProcess(ffmpeg, arguments)
            try expectEqual(result.status, 0)
            for index in 0..<count {
                let id = CommandBuilder.ametadataInstanceID(forInput: index)
                try expect(result.stderr.contains("Parsed_ametadata_\(id) "),
                           "no Parsed_ametadata_\(id) line for input \(index)")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            try expect(size > 0, "ffmpeg wrote no output")

            // Same stderr, through the parser the controller uses.
            let parser = LevelLineParser(inputCount: count)
            let seen = Set(result.stderr.split(separator: "\n").compactMap { parser.parse(line: String($0))?.inputIndex })
            try expectEqual(seen, Set(0..<count))
        }
    }
}
