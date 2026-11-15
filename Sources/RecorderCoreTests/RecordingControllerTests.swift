import Combine
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
        var now = Date(timeIntervalSince1970: 1_000)
        let (controller, fake) = makeController(clock: { now })
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 3)
        fake.emitStderr(levelLine(0, -20.0))
        now.addTimeInterval(0.2)                    // past the shared publish window each time
        fake.emitStderr(levelLine(2, -7.5))
        try expectEqual(controller.levelsDB, [-20.0, -120, -7.5])
        now.addTimeInterval(0.2)
        fake.emitStderr("[Parsed_ametadata_9 @ 0x2] lavfi.astats.Overall.RMS_level=-33.0")
        try expectEqual(controller.levelsDB, [-20.0, -33.0, -7.5])
    }

    test("level lines from inputs that were not started are ignored") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 2)
        fake.emitStderr(levelLine(2, -5.0))
        fake.emitStderr(levelLine(7, -5.0))
        try expectEqual(controller.levelsDB, [-120, -120])
    }

    test("inputs share one 100 ms publish window; the latest value per input wins") {
        let base = Date(timeIntervalSince1970: 1_000)
        var now = base
        let (controller, fake) = makeController(clock: { now })
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 3)
        var published: [[Double]] = []
        let subscription = controller.$levelsDB.dropFirst().sink { published.append($0) }
        defer { subscription.cancel() }

        fake.emitStderr(levelLine(0, -30.0))        // first line opens the window: shown at once
        try expectEqual(published, [[-30.0, -120, -120]])

        now = base.addingTimeInterval(0.02)
        fake.emitStderr(levelLine(1, -25.0))        // inside the window, whichever input: held back
        fake.emitStderr(levelLine(2, -20.0))
        now = base.addingTimeInterval(0.04)
        fake.emitStderr(levelLine(1, -24.0))        // replaces the held -25
        try expectEqual(published.count, 1)
        try expectEqual(controller.levelsDB, [-30.0, -120, -120])

        now = base.addingTimeInterval(0.11)
        fake.emitStderr(levelLine(0, -10.0))        // window over: every input lands in ONE write
        try expectEqual(published.count, 2)
        try expectEqual(published.last, [-10.0, -24.0, -20.0])

        now = base.addingTimeInterval(0.15)
        fake.emitStderr(levelLine(2, -5.0))         // new window runs from the last publish
        try expectEqual(published.count, 2)
        now = base.addingTimeInterval(0.22)
        fake.emitStderr(levelLine(1, -1.0))
        try expectEqual(published.count, 3)
        try expectEqual(published.last, [-10.0, -1.0, -5.0])
    }

    test("a level held back by the window is published by the next line after it, from any input") {
        let base = Date(timeIntervalSince1970: 1_000)
        var now = base
        let (controller, fake) = makeController(clock: { now })
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 3)
        fake.emitStderr(levelLine(0, -30.0))
        now = base.addingTimeInterval(0.05)
        fake.emitStderr(levelLine(1, -25.0))
        try expectEqual(controller.levelsDB[1], -120)

        now = base.addingTimeInterval(0.12)
        fake.emitStderr(levelLine(2, -9.0))         // not input 1's line, but it flushes input 1's value
        try expectEqual(controller.levelsDB, [-30.0, -25.0, -9.0])
    }

    test("levels still pending when ffmpeg exits are published") {
        let base = Date(timeIntervalSince1970: 1_000)
        var now = base
        let (controller, fake) = makeController(clock: { now })
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 2)
        fake.emitStderr(levelLine(0, -30.0))
        now = base.addingTimeInterval(0.05)
        fake.emitStderr(levelLine(1, -25.0))
        fake.terminate(status: 1)
        try expectEqual(controller.levelsDB, [-30.0, -25.0])
    }

    test("a level inside the window does not count as a publish for the other inputs") {
        // Regression guard for the old per-input windows: a quiet input must not be starved
        // by a chatty one, nor the other way round.
        let base = Date(timeIntervalSince1970: 1_000)
        var now = base
        let (controller, fake) = makeController(clock: { now })
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 2)
        var published = 0
        let subscription = controller.$levelsDB.dropFirst().sink { _ in published += 1 }
        defer { subscription.cancel() }
        for step in 0..<10 {                        // 10 ms apart, both inputs, for 100 ms
            now = base.addingTimeInterval(Double(step) * 0.01)
            fake.emitStderr(levelLine(0, -30.0 + Double(step)))
            fake.emitStderr(levelLine(1, -50.0 + Double(step)))
        }
        try expectEqual(published, 1)               // one write for 20 lines across two inputs
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

    test("meter lines and their frame headers stay out of the failure tail") {
        func header(_ input: Int, _ frame: Int) -> String {
            "[Parsed_ametadata_\(CommandBuilder.ametadataInstanceID(forInput: input)) @ 0x6000] "
                + "frame:\(frame)    pts:\(frame * 1024)   pts_time:\(Double(frame) * 0.0213)"
        }
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"),
                         inputCount: 3)
        fake.emitStderr("[avfoundation @ 0x1] Selected sample rate (48000) is not supported")
        for frame in 0..<300 {                      // far more than 20 lines, and more than the 200-line cap
            for input in 0..<3 {
                fake.emitStderr(header(input, frame))
                fake.emitStderr(levelLine(input, -20.0))
            }
        }
        fake.emitStderr("[Parsed_astats_3 @ 0x2] some other filter message")
        fake.emitStderr("Error writing trailer: No space left on device")
        fake.terminate(status: 1)
        guard case .failed(_, let tail) = controller.state else {
            throw TestFailure(description: "expected .failed, got \(controller.state)")
        }
        try expectEqual(tail, [
            "[avfoundation @ 0x1] Selected sample rate (48000) is not supported",
            "[Parsed_astats_3 @ 0x2] some other filter message",
            "Error writing trailer: No space left on device",
        ])
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
