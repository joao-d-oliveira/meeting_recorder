import Foundation
import RecorderCore

final class FakeProcess: ProcessRunning {
    var onStderrLine: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?
    var isRunning = false
    var startedWith: (executable: String, arguments: [String])?
    var stdinWrites: [String] = []
    var interrupted = false
    var killed = false

    func start(executable: String, arguments: [String]) throws {
        startedWith = (executable, arguments)
        isRunning = true
    }

    func writeStdin(_ string: String) { stdinWrites.append(string) }
    func interrupt() { interrupted = true }
    func forceKill() { killed = true }

    func emitStderr(_ line: String) { onStderrLine?(line) }
    func terminate(status: Int32) {
        isRunning = false
        onTermination?(status)
    }
}

func runRecordingControllerTests() {
    func makeTempFile(content: String = "x") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-test-\(UUID().uuidString).flac")
        try! Data(content.utf8).write(to: url)
        return url
    }

    func makeController(
        interruptAfter: TimeInterval = 5, killAfter: TimeInterval = 10,
        clock: @escaping () -> Date = Date.init
    ) -> (RecordingController, FakeProcess) {
        let fake = FakeProcess()
        let controller = RecordingController(
            makeProcess: { fake }, clock: clock, interruptAfter: interruptAfter, killAfter: killAfter)
        return (controller, fake)
    }

    func levelLine(_ input: Int, _ value: Double) -> String {
        "[Parsed_ametadata_\(CommandBuilder.ametadataInstanceID(forInput: input)) @ 0x1] "
            + "lavfi.astats.Overall.RMS_level=\(value)"
    }

    test("start launches ffmpeg and enters recording state") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/opt/homebrew/bin/ffmpeg",
                         arguments: ["-i", ":0"],
                         outputURL: URL(fileURLWithPath: "/tmp/never.flac"), inputCount: 3)
        try expectEqual(fake.startedWith?.executable, "/opt/homebrew/bin/ffmpeg")
        try expectEqual(fake.startedWith?.arguments, ["-i", ":0"])
        guard case .recording = controller.state else {
            throw TestFailure(description: "expected .recording, got \(controller.state)")
        }
    }

    test("start sizes levelsDB to the input count at the silence floor") {
        let (controller, _) = makeController()
        try expectEqual(controller.levelsDB, [])
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 3)
        try expectEqual(controller.levelsDB, [-120, -120, -120])
    }

    test("level lines update the matching input's level") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 3)
        fake.emitStderr(levelLine(0, -20.0))
        fake.emitStderr(levelLine(2, -7.5))
        try expectEqual(controller.levelsDB, [-20.0, -120, -7.5])
        fake.emitStderr("[Parsed_ametadata_9 @ 0x2] lavfi.astats.Overall.RMS_level=-33.0")
        try expectEqual(controller.levelsDB[1], -33.0)
    }

    test("level lines from inputs that were not started are ignored") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 2)
        fake.emitStderr(levelLine(2, -5.0))
        fake.emitStderr(levelLine(7, -5.0))
        try expectEqual(controller.levelsDB, [-120, -120])
    }

    test("meter updates are throttled to 10 Hz per input, independently") {
        var now = Date(timeIntervalSince1970: 1_000)
        let (controller, fake) = makeController(clock: { now })
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 2)
        fake.emitStderr(levelLine(0, -30.0))
        try expectEqual(controller.levelsDB[0], -30.0)

        now.addTimeInterval(0.05)
        fake.emitStderr(levelLine(0, -20.0))        // 50 ms later: dropped
        fake.emitStderr(levelLine(1, -25.0))        // other input has its own window
        try expectEqual(controller.levelsDB, [-30.0, -25.0])

        now.addTimeInterval(0.06)
        fake.emitStderr(levelLine(0, -10.0))        // 110 ms after the last publish: shown
        try expectEqual(controller.levelsDB[0], -10.0)
        fake.emitStderr(levelLine(1, -15.0))        // only 60 ms after input 1's publish: dropped
        try expectEqual(controller.levelsDB[1], -25.0)

        now.addTimeInterval(0.05)
        fake.emitStderr(levelLine(1, -15.0))        // 110 ms after it: shown
        try expectEqual(controller.levelsDB[1], -15.0)
    }

    test("a new recording resets the levels") {
        let (controller, fake) = makeController()
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
        fake.emitStderr(levelLine(1, -12.0))
        controller.stop()
        fake.terminate(status: 0)
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 2)
        try expectEqual(controller.levelsDB, [-120, -120])
        fake.emitStderr(levelLine(1, -9.0))         // throttle window restarted too
        try expectEqual(controller.levelsDB, [-120, -9.0])
    }

    test("stop writes q and transitions to stopping") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"), inputCount: 3)
        controller.stop()
        try expectEqual(fake.stdinWrites, ["q"])
        guard case .stopping = controller.state else {
            throw TestFailure(description: "expected .stopping, got \(controller.state)")
        }
    }

    test("clean exit after stop with valid file ends in saved") {
        let (controller, fake) = makeController()
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
        controller.stop()
        fake.terminate(status: 0)
        try expectEqual(controller.state, .saved(file))
    }

    test("exit after stop with missing file ends in failed") {
        let (controller, fake) = makeController()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).flac")
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: missing, inputCount: 3)
        controller.stop()
        fake.terminate(status: 0)
        guard case .failed(let message, _) = controller.state else {
            throw TestFailure(description: "expected .failed, got \(controller.state)")
        }
        try expect(message.contains("missing or empty"), "unexpected message: \(message)")
    }

    test("exit after stop with empty file ends in failed") {
        let (controller, fake) = makeController()
        let file = makeTempFile(content: "")
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
        controller.stop()
        fake.terminate(status: 0)
        guard case .failed(let message, _) = controller.state else {
            throw TestFailure(description: "expected .failed, got \(controller.state)")
        }
        try expect(message.contains("missing or empty"), "unexpected message: \(message)")
    }

    test("non-zero exit after stop is not reported as a clean save") {
        // 255 = SIGINT exit, 9 = SIGKILL, 1 = ffmpeg error
        for status: Int32 in [255, 9, 1] {
            let (controller, fake) = makeController()
            let file = makeTempFile()
            defer { try? FileManager.default.removeItem(at: file) }
            controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
            controller.stop()
            fake.emitStderr("Exiting normally, received signal 2.")
            fake.terminate(status: status)
            guard case .failed(let message, let tail) = controller.state else {
                throw TestFailure(description: "status \(status): expected .failed, got \(controller.state)")
            }
            try expect(message.contains("didn't stop cleanly"), "unexpected message: \(message)")
            try expect(message.contains("status \(status)"), "status missing from: \(message)")
            try expect(message.contains(file.path), "path missing from: \(message)")
            try expectEqual(tail, ["Exiting normally, received signal 2."])
        }
    }

    test("stop escalates to interrupt then kill when ffmpeg does not exit") {
        let (controller, fake) = makeController(interruptAfter: 0.05, killAfter: 0.15)
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
        controller.stop()
        Thread.sleep(forTimeInterval: 0.5)
        try expect(fake.interrupted, "SIGINT escalation did not fire")
        try expect(fake.killed, "SIGKILL escalation did not fire")
        fake.terminate(status: 9)
        guard case .failed(let message, _) = controller.state else {
            throw TestFailure(description: "expected .failed after forced kill, got \(controller.state)")
        }
        try expect(message.contains("didn't stop cleanly"), "unexpected message: \(message)")
    }

    test("exit after stop cancels pending escalation") {
        let (controller, fake) = makeController(interruptAfter: 0.05, killAfter: 0.15)
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
        controller.stop()
        fake.terminate(status: 0)
        Thread.sleep(forTimeInterval: 0.4)
        try expect(!fake.interrupted && !fake.killed, "escalation fired after a clean exit")
        try expectEqual(controller.state, .saved(file))
    }

    test("unexpected exit while recording ends in failed with stderr tail") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"), inputCount: 3)
        for i in 1...30 { fake.emitStderr("line \(i)") }
        fake.terminate(status: 1)
        guard case .failed(let message, let tail) = controller.state else {
            throw TestFailure(description: "expected .failed, got \(controller.state)")
        }
        try expect(message.contains("unexpectedly"), "unexpected message: \(message)")
        try expectEqual(tail.count, 20)
        try expectEqual(tail.last, "line 30")
    }

    test("can start a new recording after saved") {
        let (controller, fake) = makeController()
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
        controller.stop()
        fake.terminate(status: 0)
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file, inputCount: 3)
        guard case .recording = controller.state else {
            throw TestFailure(description: "expected .recording after restart, got \(controller.state)")
        }
    }

    test("start while already recording is ignored") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: ["first"], outputURL: URL(fileURLWithPath: "/tmp/n.flac"), inputCount: 3)
        controller.start(ffmpegPath: "/ff", arguments: ["second"], outputURL: URL(fileURLWithPath: "/tmp/n.flac"), inputCount: 3)
        try expectEqual(fake.startedWith?.arguments, ["first"])
    }
}
