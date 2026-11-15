import Foundation
import RecorderCore

let sampleSummaryJSON = """
{"version":1,"transcript_path":"/x/Alice_Transcript.md","guest":"Alice","interviewer":"Joao",
"turn_count":42,"word_count":900,"duration_seconds":601.25,"interviewer_speaking_seconds":120.5,
"guest_speaking_seconds":400.75,"identification_method":"voiceprint",
"identification":"voiceprint similarity [0.128 0.926]","interviewer_cluster":1,
"similarity_scores":[0.128,0.926],"interviewer_similarity":0.926,"guest_similarity":0.128,
"weak_match":false,"uncertain_turns":3}
"""

func runTranscriptionTests() {
    runTranscriptionModelTests()
    runPipelineLocatorTests()
    runTranscriptionControllerTests()
    runTranscriptionProcessTests()
    runPipelineScriptTests()
}

private func runTranscriptionModelTests() {
    test("sanitizedName keeps ordinary names, including non-ASCII") {
        try expectEqual(TranscriptionRequest.sanitizedName("Alice"), "Alice")
        try expectEqual(TranscriptionRequest.sanitizedName("Maria José"), "Maria José")
        try expectEqual(TranscriptionRequest.sanitizedName("  Bob  "), "Bob")
    }

    test("sanitizedName removes path separators and colons") {
        try expectEqual(TranscriptionRequest.sanitizedName("a/b:c"), "a-b-c")
        try expectEqual(TranscriptionRequest.sanitizedName("a\\b"), "a-b")
        let hostile = TranscriptionRequest.sanitizedName("../../etc/passwd")
        try expect(!hostile.contains("/") && !hostile.contains(":") && !hostile.hasPrefix("."),
                   "unsafe result: \(hostile)")
    }

    test("sanitizedName drops leading dots and dashes, control characters and excess length") {
        try expectEqual(TranscriptionRequest.sanitizedName(".hidden"), "hidden")
        try expectEqual(TranscriptionRequest.sanitizedName("-rf"), "rf")
        try expectEqual(TranscriptionRequest.sanitizedName("line\nbreak\ttab"), "line break tab")
        try expectEqual(TranscriptionRequest.sanitizedName(String(repeating: "x", count: 200)).count, 64)
        try expectEqual(TranscriptionRequest.sanitizedName("   "), "")
        try expectEqual(TranscriptionRequest.sanitizedName("..."), "")
    }

    test("sanitizedName fallback chain") {
        try expectEqual(TranscriptionRequest.sanitizedName("", fallback: "Guest"), "Guest")
        try expectEqual(TranscriptionRequest.sanitizedName(" / ", fallback: "Sam"), "Sam")
        try expectEqual(TranscriptionRequest.sanitizedName("", fallback: "", lastResort: "Zed"), "Zed")
        try expectEqual(TranscriptionRequest.sanitizedName("Al", fallback: "Guest"), "Al")
    }

    test("request defaults the output directory to the recording's folder") {
        let audio = URL(fileURLWithPath: "/Recordings/2026-11-15 10.00/meeting.flac")
        let request = TranscriptionRequest(audioURL: audio, guestName: "Al")
        try expectEqual(request.outputDirectory.path, "/Recordings/2026-11-15 10.00")
        try expectEqual(request.interviewerName, "")
    }

    test("result decodes every summary field") {
        let transcript = URL(fileURLWithPath: "/out/Alice_Transcript.md")
        let summary = URL(fileURLWithPath: "/out/Alice_Transcript.summary.json")
        let result = try TranscriptionResult.decode(
            summary: Data(sampleSummaryJSON.utf8), transcriptURL: transcript, summaryURL: summary)
        try expectEqual(result.transcriptURL, transcript)
        try expectEqual(result.summaryURL, summary)
        try expectEqual(result.guest, "Alice")
        try expectEqual(result.interviewer, "Joao")
        try expectEqual(result.turnCount, 42)
        try expectEqual(result.durationSeconds, 601.25)
        try expectEqual(result.interviewerSpeakingSeconds, 120.5)
        try expectEqual(result.guestSpeakingSeconds, 400.75)
        try expectEqual(result.identificationMethod, "voiceprint")
        try expectEqual(result.identificationDetail, "voiceprint similarity [0.128 0.926]")
        try expectEqual(result.similarityScores, [0.128, 0.926])
        try expectEqual(result.interviewerSimilarity, 0.926)
        try expectEqual(result.guestSimilarity, 0.128)
        try expectEqual(result.weakMatch, false)
        try expectEqual(result.uncertainTurns, 3)
    }

    test("result decoding tolerates missing optional fields but not missing counts") {
        let url = URL(fileURLWithPath: "/x")
        let minimal = try TranscriptionResult.decode(
            summary: Data(#"{"turn_count": 2, "duration_seconds": 10}"#.utf8), transcriptURL: url, summaryURL: url)
        try expectEqual(minimal.turnCount, 2)
        try expectEqual(minimal.uncertainTurns, 0)
        try expectEqual(minimal.weakMatch, false)
        try expectEqual(minimal.similarityScores, [])

        for bad in [#"{"duration_seconds": 10}"#, #"{"turn_count": "x", "duration_seconds": 1}"#, "not json", ""] {
            var threw = false
            do { _ = try TranscriptionResult.decode(summary: Data(bad.utf8), transcriptURL: url, summaryURL: url) }
            catch { threw = true }
            try expect(threw, "expected decode to throw for \(bad)")
        }
    }

    test("stage titles are non-empty and raw values match the STAGE: names") {
        try expectEqual(TranscriptionStage.allCases.map(\.rawValue), ["setup", "convert", "transcribe", "diarize"])
        try expect(TranscriptionStage.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

private func runPipelineLocatorTests() {
    func locator(
        existing: Set<String>,
        bundle: String? = nil,
        executable: String? = nil,
        source: String = "/nowhere/Sources/RecorderCore/X.swift"
    ) -> PipelineLocator {
        PipelineLocator(
            fileExists: { existing.contains($0) },
            bundleResourceURL: bundle.map { URL(fileURLWithPath: $0) },
            executableURL: executable.map { URL(fileURLWithPath: $0) },
            sourceFilePath: source)
    }

    test("locator prefers a valid override over the bundle") {
        let l = locator(existing: ["/custom/run.sh", "/App/Resources/Pipeline/run.sh"], bundle: "/App/Resources")
        try expectEqual(l.locate(override: "/custom")?.path, "/custom")
    }

    test("locator ignores an override without run.sh and uses the bundle") {
        let l = locator(existing: ["/App/Resources/Pipeline/run.sh"], bundle: "/App/Resources")
        try expectEqual(l.locate(override: "/custom")?.path, "/App/Resources/Pipeline")
        try expectEqual(l.locate(override: "   ")?.path, "/App/Resources/Pipeline")
        try expectEqual(l.locate(override: nil)?.path, "/App/Resources/Pipeline")
    }

    test("locator expands ~ in the override") {
        let expanded = NSHomeDirectory() + "/my-pipeline/run.sh"
        let l = locator(existing: [expanded])
        try expectEqual(l.locate(override: "~/my-pipeline")?.path, NSHomeDirectory() + "/my-pipeline")
    }

    test("locator settings overload reads pipelineDirectoryOverride") {
        let l = locator(existing: ["/custom/run.sh"])
        try expectEqual(l.locate(settings: TranscriptionSettings(pipelineDirectoryOverride: "/custom"))?.path, "/custom")
        try expectEqual(l.locate(settings: TranscriptionSettings())?.path, nil)
    }

    test("locator finds the repo Pipeline by walking up from the executable") {
        let l = locator(
            existing: ["/repo/Package.swift", "/repo/Pipeline/run.sh"],
            bundle: "/repo/.build/debug",  // a bare build directory has no Pipeline
            executable: "/repo/.build/arm64-apple-macosx/debug/MeetingRecorder")
        try expectEqual(l.locate(override: nil)?.path, "/repo/Pipeline")
    }

    test("locator only trusts a Pipeline folder that sits next to Package.swift") {
        let l = locator(
            existing: ["/Users/me/Pipeline/run.sh"],  // unrelated folder above the app
            executable: "/Users/me/Applications/MeetingRecorder.app/Contents/MacOS/MeetingRecorder")
        try expectEqual(l.locate(override: nil)?.path, nil)
    }

    test("locator falls back to the source file location") {
        let l = locator(
            existing: ["/src/Package.swift", "/src/Pipeline/run.sh"],
            executable: "/elsewhere/bin/MeetingRecorder",
            source: "/src/Sources/RecorderCore/TranscriptionPipelineLocator.swift")
        try expectEqual(l.locate(override: nil)?.path, "/src/Pipeline")
    }

    test("locator returns nil when nothing matches") {
        try expectEqual(locator(existing: []).locate(override: "/custom")?.path, nil)
    }

    test("default locator finds this repository's Pipeline during development") {
        let found = PipelineLocator().locate(override: nil)
        try expect(found != nil, "no Pipeline directory found")
        try expect(FileManager.default.fileExists(atPath: found!.appendingPathComponent("run.sh").path))
        try expectEqual(found!.lastPathComponent, "Pipeline")
    }
}
