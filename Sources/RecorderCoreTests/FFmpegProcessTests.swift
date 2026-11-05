import Foundation
import RecorderCore

/// FFmpegProcess delivers callbacks on the main queue, and the harness runs on the
/// main thread, so waiting means spinning the main run loop.
private func spinMainRunLoop(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
}

private enum Event: Equatable {
    case line(String)
    case terminated(Int32)
}

/// Runs a shell script to completion and returns callbacks in delivery order.
private func runScript(_ script: String) throws -> [Event] {
    let process = FFmpegProcess()
    var events: [Event] = []
    var terminated = false
    process.onStderrLine = { events.append(.line($0)) }
    process.onTermination = { events.append(.terminated($0)); terminated = true }
    try process.start(executable: "/bin/sh", arguments: ["-c", script])
    try expect(spinMainRunLoop(timeout: 10) { terminated }, "timed out waiting for termination")
    // Let anything wrongly queued behind the termination callback arrive too.
    _ = spinMainRunLoop(timeout: 0.1) { false }
    return events
}

private func expectStartThrows(_ path: String, using process: FFmpegProcess = FFmpegProcess()) throws {
    var threw = false
    do { try process.start(executable: path, arguments: []) } catch { threw = true }
    try expect(threw, "expected start to throw for \(path)")
}

private func cpuSeconds() -> Double {
    Double(clock()) / Double(CLOCKS_PER_SEC)
}

func runFFmpegProcessTests() {
    test("stderr lines are split on both newline and carriage return") {
        let events = try runScript(#"printf 'a\nb\rc\n' >&2"#)
        try expectEqual(events, [.line("a"), .line("b"), .line("c"), .terminated(0)])
    }

    test("empty segments are skipped, including CRLF pairs") {
        let events = try runScript(#"printf 'a\r\n\n\rb\n' >&2"#)
        try expectEqual(events, [.line("a"), .line("b"), .terminated(0)])
    }

    test("trailing partial line is flushed before termination") {
        let events = try runScript(#"printf 'a\nb\rc' >&2; exit 3"#)
        try expectEqual(events, [.line("a"), .line("b"), .line("c"), .terminated(3)])
    }

    test("termination status is delivered without any stderr output") {
        let events = try runScript("exit 7")
        try expectEqual(events, [.terminated(7)])
    }

    test("stdout is not treated as stderr output") {
        let events = try runScript(#"printf 'out\n'; printf 'err\n' >&2"#)
        try expectEqual(events, [.line("err"), .terminated(0)])
    }

    test("fast-failing process delivers its final error lines before termination") {
        let events = try runScript(#"printf 'Error opening input\nInput/output error\n' >&2; exit 1"#)
        try expectEqual(events, [
            .line("Error opening input"), .line("Input/output error"), .terminated(1),
        ])
    }

    test("large stderr output arrives complete and in order") {
        let count = 20_000
        let events = try runScript("seq 1 \(count) >&2")
        var expected = (1...count).map { Event.line(String($0)) }
        expected.append(.terminated(0))
        try expectEqual(events.count, expected.count)
        try expect(events == expected, "stderr lines were dropped or reordered")
    }

    test("start throws for a directory path") {
        try expectStartThrows("/tmp")
    }

    test("start throws for a missing executable") {
        try expectStartThrows("/nonexistent/ffmpeg-\(UUID().uuidString)")
    }

    test("failed starts do not busy-loop on the closed stderr pipe") {
        var callbacks = 0
        for _ in 0..<3 {
            let process = FFmpegProcess()
            process.onStderrLine = { _ in callbacks += 1 }
            process.onTermination = { _ in callbacks += 1 }
            try expectStartThrows("/tmp", using: process)
        }

        // A leaked readability handler re-fires on EOF forever, burning CPU.
        let before = cpuSeconds()
        _ = spinMainRunLoop(timeout: 1.0) { false }
        let used = cpuSeconds() - before
        try expect(used < 0.25, "used \(used) CPU-s idling for 1s after failed starts")
        try expectEqual(callbacks, 0)
    }
}
