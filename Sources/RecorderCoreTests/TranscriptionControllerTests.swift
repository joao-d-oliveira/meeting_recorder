import Foundation
import RecorderCore

final class FakePipelineProcess: ProcessRunning {
    var onStdoutLine: ((String) -> Void)?
    var onStderrLine: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?
    var isRunning = false
    var startError: Error?
    var started: (executable: String, arguments: [String], environment: [String: String]?, currentDirectory: String?)?
    var interruptCount = 0
    var killed = false

    func start(executable: String, arguments: [String]) throws {
        try start(executable: executable, arguments: arguments, environment: nil, currentDirectory: nil)
    }

    func start(
        executable: String, arguments: [String],
        environment: [String: String]?, currentDirectory: String?
    ) throws {
        if let startError { throw startError }
        started = (executable, arguments, environment, currentDirectory)
        isRunning = true
    }

    func writeStdin(_ string: String) {}
    func interrupt() { interruptCount += 1 }
    func forceKill() { killed = true }

    func emitStdout(_ line: String) { onStdoutLine?(line) }
    func emitStderr(_ line: String) { onStderrLine?(line) }
    func terminate(status: Int32) {
        isRunning = false
        onTermination?(status)
    }
}

private struct LaunchFailure: Error, LocalizedError {
    var errorDescription: String? { "boom" }
}

private func waitOnMain(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
}

/// A temp folder with a recording, the output folder the pipeline would write to, and a HOME
/// whose ~/.cache/diarize holds voiceprints for the interviewers the tests use (the controller
/// refuses to start without one).
private struct Fixture {
    let root: URL
    let audio: URL
    let outputDirectory: URL
    let home: URL

    init(voiceprints: [String] = ["joao", "maria", "ana"]) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tc-test-\(UUID().uuidString)")
        outputDirectory = root.appendingPathComponent("rec")
        audio = outputDirectory.appendingPathComponent("meeting.flac")
        home = root.appendingPathComponent("home")
        try! FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try! Data("x".utf8).write(to: audio)
        for name in voiceprints { addVoiceprint(name) }
    }

    /// `name` is the lower-cased interviewer name, as in the file name.
    func addVoiceprint(_ name: String) {
        let url = TranscriptionController.voiceprintURL(interviewer: name, home: home.path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data("vp".utf8).write(to: url)
    }

    func writeOutputs(guest: String, summary: String? = sampleSummaryJSON, transcript: Bool = true) {
        if let summary {
            try! Data(summary.utf8).write(
                to: outputDirectory.appendingPathComponent("\(guest)_Transcript.summary.json"))
        }
        if transcript {
            try! Data("# Interview\n".utf8).write(
                to: outputDirectory.appendingPathComponent("\(guest)_Transcript.md"))
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private let fakePipelineLocator = PipelineLocator(
    fileExists: { $0 == "/fake/Pipeline/run.sh" },
    bundleResourceURL: URL(fileURLWithPath: "/fake"),
    executableURL: nil,
    sourceFilePath: "/nowhere/Sources/RecorderCore/X.swift")

private func testEnvironment(home: URL) -> [String: String] {
    [
        "HOME": home.path, "PATH": "/usr/bin:/custom/bin:/opt/homebrew/bin",
        "REFRESH_VOICEPRINT": "1", "OTHER": "kept",
    ]
}

func runTranscriptionControllerTests() {
    func makeController(
        _ fixture: Fixture, locator: PipelineLocator = fakePipelineLocator, killAfter: TimeInterval = 4
    ) -> (TranscriptionController, FakePipelineProcess) {
        let fake = FakePipelineProcess()
        let controller = TranscriptionController(
            makeProcess: { fake }, locator: locator, baseEnvironment: testEnvironment(home: fixture.home),
            killAfter: killAfter)
        return (controller, fake)
    }

    func start(
        _ controller: TranscriptionController, _ fixture: Fixture,
        guest: String = "Alice", interviewer: String = "", settings: TranscriptionSettings = TranscriptionSettings()
    ) {
        controller.start(
            request: TranscriptionRequest(
                audioURL: fixture.audio, guestName: guest,
                outputDirectory: fixture.outputDirectory, interviewerName: interviewer),
            settings: settings)
    }

    func expectFailed(_ state: TranscriptionState) throws -> (message: String, logTail: [String]) {
        guard case .failed(let message, let tail) = state else {
            throw TestFailure(description: "expected .failed, got \(state)")
        }
        return (message, tail)
    }

    test("start launches run.sh through bash with the guest spec") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        try expectEqual(fake.started?.executable, "/bin/bash")
        try expectEqual(fake.started?.arguments, [
            "/fake/Pipeline/run.sh", fixture.outputDirectory.standardizedFileURL.path,
            "Alice:\(fixture.audio.standardizedFileURL.path)",
        ])
        try expectEqual(fake.started?.currentDirectory, "/fake/Pipeline")
        try expectEqual(controller.state, .running(stage: .convert, progress: nil))
    }

    test("child environment has INTERVIEWER, HOME and a Homebrew PATH, and drops REFRESH_VOICEPRINT") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, interviewer: "Maria", settings: TranscriptionSettings(interviewerName: "Ignored"))
        guard let env = fake.started?.environment else { throw TestFailure(description: "no environment passed") }
        try expectEqual(env["INTERVIEWER"], "Maria")
        try expectEqual(env["HOME"], fixture.home.path)
        try expectEqual(env["OTHER"], "kept")
        try expectEqual(env["REFRESH_VOICEPRINT"], nil)
        try expectEqual(env["PIPELINE_PROGRESS"], "1")
        // Preferred dirs first, the caller's extra dirs after them, no duplicates.
        try expectEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/custom/bin")
    }

    test("interviewer falls back to the settings, then to Joao") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, interviewer: "", settings: TranscriptionSettings(interviewerName: "Ana"))
        try expectEqual(fake.started?.environment?["INTERVIEWER"], "Ana")
        let (second, fake2) = makeController(fixture)
        start(second, fixture, interviewer: "", settings: TranscriptionSettings(interviewerName: " / "))
        try expectEqual(fake2.started?.environment?["INTERVIEWER"], "Joao")
    }

    test("empty guest name uses the default guest name from the settings") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, guest: "  ", settings: TranscriptionSettings(defaultGuestName: "Visitor"))
        try expect(fake.started?.arguments.last?.hasPrefix("Visitor:") == true,
                   "spec was \(String(describing: fake.started?.arguments.last))")
    }

    test("guest name is sanitized in the spec and in the files looked for afterwards") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, guest: "Al/ice:X")
        try expect(fake.started?.arguments.last?.hasPrefix("Al-ice-X:/") == true,
                   "spec was \(String(describing: fake.started?.arguments.last))")
        fixture.writeOutputs(guest: "Al-ice-X")
        fake.terminate(status: 0)
        guard case .finished(let result) = controller.state else {
            throw TestFailure(description: "expected .finished, got \(controller.state)")
        }
        try expectEqual(result.transcriptURL.lastPathComponent, "Al-ice-X_Transcript.md")
    }

    test("STAGE lines move through the stages and reset progress") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fake.emitStdout("STAGE: setup")
        try expectEqual(controller.state, .running(stage: .setup, progress: nil))
        fake.emitStdout("STAGE: transcribe")
        fake.emitStdout("PROGRESS: 40")
        try expectEqual(controller.state, .running(stage: .transcribe, progress: 0.4))
        fake.emitStdout("STAGE: diarize")
        try expectEqual(controller.state, .running(stage: .diarize, progress: nil))
        fake.emitStdout("STAGE: done")
        fake.emitStdout("STAGE: bogus")
        try expectEqual(controller.state, .running(stage: .diarize, progress: nil))
    }

    test("PROGRESS is clamped, parsed from stderr too, and ignored outside the transcribe stage") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fake.emitStdout("PROGRESS: 50")  // still converting
        try expectEqual(controller.state, .running(stage: .convert, progress: nil))
        fake.emitStdout("STAGE: transcribe")
        fake.emitStderr("PROGRESS: 12.5")
        try expectEqual(controller.state, .running(stage: .transcribe, progress: 0.125))
        fake.emitStdout("PROGRESS: 250")
        try expectEqual(controller.state, .running(stage: .transcribe, progress: 1.0))
        fake.emitStdout("PROGRESS: -3")
        try expectEqual(controller.state, .running(stage: .transcribe, progress: 0.0))
        fake.emitStdout("PROGRESS: abc")
        fake.emitStdout("PROGRESS:")
        fake.emitStdout("PROGRESS: nan")
        try expectEqual(controller.state, .running(stage: .transcribe, progress: 0.0))
        fake.emitStdout("  STAGE:   transcribe  ")  // whitespace tolerant; restarting resets progress
        try expectEqual(controller.state, .running(stage: .transcribe, progress: nil))
    }

    test("exit 0 with a valid summary finishes with the decoded result") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fixture.writeOutputs(guest: "Alice")
        fake.terminate(status: 0)
        guard case .finished(let result) = controller.state else {
            throw TestFailure(description: "expected .finished, got \(controller.state)")
        }
        try expectEqual(result.turnCount, 42)
        try expectEqual(result.uncertainTurns, 3)
        try expectEqual(result.transcriptURL.lastPathComponent, "Alice_Transcript.md")
        try expectEqual(result.transcriptURL.deletingLastPathComponent().path,
                        fixture.outputDirectory.standardizedFileURL.path)
        try expectEqual(result.summaryURL.lastPathComponent, "Alice_Transcript.summary.json")
    }

    test("exit 0 without a summary file fails with a clear message") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fake.emitStdout("some output")
        fake.terminate(status: 0)
        let failure = try expectFailed(controller.state)
        try expect(failure.message.contains("summary file is missing"), failure.message)
        try expectEqual(failure.logTail, ["some output"])
    }

    test("exit 0 with an unreadable summary fails") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fixture.writeOutputs(guest: "Alice", summary: "{ nope")
        fake.terminate(status: 0)
        let failure = try expectFailed(controller.state)
        try expect(failure.message.contains("could not be read"), failure.message)
    }

    test("exit 0 with a summary but no transcript fails") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fixture.writeOutputs(guest: "Alice", transcript: false)
        fake.terminate(status: 0)
        let failure = try expectFailed(controller.state)
        try expect(failure.message.contains("transcript file is missing"), failure.message)
    }

    test("non-zero exit fails with the last 20 log lines and the last line in the message") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fake.emitStdout("STAGE: convert")
        for i in 1...30 { fake.emitStderr("line \(i)") }
        fake.emitStdout("STAGE: transcribe")
        fake.emitStdout("PROGRESS: 10")
        fake.emitStderr(" 45%|████▌     | 1234/2700 [00:12<00:20, 70.1frames/s]")
        fake.emitStderr("RuntimeError: out of memory")
        fake.terminate(status: 1)
        let failure = try expectFailed(controller.state)
        try expect(failure.message.contains("exit status 1"), failure.message)
        try expect(failure.message.contains("RuntimeError: out of memory"), failure.message)
        try expectEqual(failure.logTail.count, 20)
        try expectEqual(failure.logTail.last, "RuntimeError: out of memory")
        try expectEqual(failure.logTail.first, "line 13")
        try expect(failure.logTail.contains("STAGE: transcribe"), "stage lines help locate the failure")
        try expect(!failure.logTail.contains { $0.contains("PROGRESS") || $0.contains("%|") }, "progress noise in tail")
    }

    test("the log buffer is bounded") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        for i in 1...1000 { fake.emitStderr("l\(i)") }
        try expectEqual(controller.recentLog.count, 20)
        try expectEqual(controller.recentLog.last, "l1000")
        fake.terminate(status: 2)
        let failure = try expectFailed(controller.state)
        try expectEqual(failure.logTail.first, "l981")
    }

    test("cancel interrupts the pipeline and ends in cancelled once it exits") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        controller.cancel()
        try expectEqual(fake.interruptCount, 1)
        try expect(controller.isCancelling)
        guard case .running = controller.state else {
            throw TestFailure(description: "expected to stay .running until exit, got \(controller.state)")
        }
        controller.cancel()  // a second request does nothing
        try expectEqual(fake.interruptCount, 1)
        fake.terminate(status: 130)
        try expectEqual(controller.state, .cancelled)
        try expect(!controller.isCancelling)
        try expect(!fake.killed, "a prompt exit must not be killed")
    }

    test("cancel escalates to a kill when the pipeline ignores the interrupt") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture, killAfter: 0.05)
        start(controller, fixture)
        controller.cancel()
        try expect(waitOnMain(timeout: 2) { fake.killed }, "force kill never happened")
        fake.terminate(status: 9)
        try expectEqual(controller.state, .cancelled)
    }

    test("a late kill timer does nothing after a clean cancellation") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture, killAfter: 0.05)
        start(controller, fixture)
        controller.cancel()
        fake.terminate(status: 130)
        _ = waitOnMain(timeout: 0.3) { false }
        try expect(!fake.killed, "kill scheduled after the process had already exited")
    }

    test("cancel while idle or finished does nothing") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        controller.cancel()
        try expectEqual(controller.state, .idle)
        try expectEqual(fake.interruptCount, 0)
    }

    test("exit 0 racing a cancel still reports cancelled") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fixture.writeOutputs(guest: "Alice")
        controller.cancel()
        fake.terminate(status: 0)
        try expectEqual(controller.state, .cancelled)
    }

    test("start fails cleanly when the pipeline cannot be found") {
        let fixture = Fixture(); defer { fixture.remove() }
        let missing = PipelineLocator(
            fileExists: { _ in false }, bundleResourceURL: nil, executableURL: nil, sourceFilePath: "/x/y/z/w.swift")
        let (controller, fake) = makeController(fixture, locator: missing)
        start(controller, fixture)
        let failure = try expectFailed(controller.state)
        try expect(failure.message.contains("pipeline not found"), failure.message)
        try expect(fake.started == nil)
    }

    test("start fails cleanly when the recording is missing") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        controller.start(
            request: TranscriptionRequest(audioURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).flac")),
            settings: TranscriptionSettings())
        let failure = try expectFailed(controller.state)
        try expect(failure.message.contains("Recording not found"), failure.message)
        try expect(fake.started == nil)
    }

    test("start fails at once, with the voiceprint path, when the interviewer has no voiceprint") {
        let fixture = Fixture(voiceprints: []); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, interviewer: "Zed")
        let failure = try expectFailed(controller.state)
        let path = fixture.home.appendingPathComponent(".cache/diarize/voiceprint-zed.npy").path
        try expectEqual(
            failure.message,
            "No voiceprint for Zed at \(path). Create it once with the interview-transcribe skill from "
                + "2 or more recordings (e.g. run.sh with two interviews), then try again.")
        try expect(fake.started == nil, "the pipeline must not be launched")
        try expect(!controller.isCancelling)
    }

    test("the voiceprint is looked up by the lower-cased interviewer name under the child's HOME") {
        let fixture = Fixture(voiceprints: ["maria josé"]); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, interviewer: "Maria José")
        try expectEqual(controller.state, .running(stage: .convert, progress: nil))
        try expect(fake.started != nil)
        try expectEqual(
            TranscriptionController.voiceprintURL(interviewer: "Ana", home: "/h").path,
            "/h/.cache/diarize/voiceprint-ana.npy")
    }

    test("the interviewer from the settings is the one that needs a voiceprint") {
        let fixture = Fixture(voiceprints: ["joao"]); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, interviewer: "", settings: TranscriptionSettings(interviewerName: "Ana"))
        let failure = try expectFailed(controller.state)
        try expect(failure.message.hasPrefix("No voiceprint for Ana at "), failure.message)
        try expect(fake.started == nil)
        fixture.addVoiceprint("ana")
        start(controller, fixture, interviewer: "", settings: TranscriptionSettings(interviewerName: "Ana"))
        try expectEqual(controller.state, .running(stage: .convert, progress: nil))
        try expectEqual(fake.started?.environment?["INTERVIEWER"], "Ana")
    }

    test("a pipeline folder chosen in Settings is not held to the voiceprint check") {
        let fixture = Fixture(voiceprints: []); defer { fixture.remove() }
        let custom = PipelineLocator(
            fileExists: { $0 == "/custom/run.sh" }, bundleResourceURL: nil, executableURL: nil,
            sourceFilePath: "/x/y/z/w.swift")
        let (controller, fake) = makeController(fixture, locator: custom)
        start(controller, fixture, settings: TranscriptionSettings(pipelineDirectoryOverride: "/custom"))
        try expectEqual(controller.state, .running(stage: .convert, progress: nil))
        try expectEqual(fake.started?.arguments.first, "/custom/run.sh")

        // An override that doesn't contain run.sh falls back to the bundled pipeline: checked again.
        let (second, fake2) = makeController(fixture, locator: PipelineLocator(
            fileExists: { $0 == "/fake/Pipeline/run.sh" }, bundleResourceURL: URL(fileURLWithPath: "/fake"),
            executableURL: nil, sourceFilePath: "/x/y/z/w.swift"))
        start(second, fixture, settings: TranscriptionSettings(pipelineDirectoryOverride: "/nowhere"))
        let failure = try expectFailed(second.state)
        try expect(failure.message.hasPrefix("No voiceprint for Joao"), failure.message)
        try expect(fake2.started == nil)
    }

    test("a launch error becomes a failure and allows another attempt") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        fake.startError = LaunchFailure()
        start(controller, fixture)
        let failure = try expectFailed(controller.state)
        try expect(failure.message.contains("boom"), failure.message)
        fake.startError = nil
        start(controller, fixture)
        try expectEqual(controller.state, .running(stage: .convert, progress: nil))
    }

    test("start is ignored while a run is in progress, and allowed again afterwards") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture, guest: "First")
        fake.emitStdout("STAGE: diarize")
        start(controller, fixture, guest: "Second")
        try expectEqual(controller.state, .running(stage: .diarize, progress: nil))
        try expect(fake.started?.arguments.last?.hasPrefix("First:") == true)

        fake.terminate(status: 1)
        _ = try expectFailed(controller.state)
        start(controller, fixture, guest: "Second")
        try expectEqual(controller.state, .running(stage: .convert, progress: nil))
        try expect(fake.started?.arguments.last?.hasPrefix("Second:") == true)
        try expect(controller.recentLog.isEmpty, "log should reset between runs")
    }

    test("lines arriving after the run ended are ignored") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        fake.terminate(status: 1)
        let before = controller.state
        fake.emitStdout("STAGE: diarize")
        fake.emitStderr("late")
        try expectEqual(controller.state, before)
    }

    test("reset returns to idle after a run, but not while running") {
        let fixture = Fixture(); defer { fixture.remove() }
        let (controller, fake) = makeController(fixture)
        start(controller, fixture)
        controller.reset()
        guard case .running = controller.state else {
            throw TestFailure(description: "reset must not interrupt a run, got \(controller.state)")
        }
        fake.terminate(status: 1)
        controller.reset()
        try expectEqual(controller.state, .idle)
    }
}
