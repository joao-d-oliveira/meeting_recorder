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

/// SIGKILLs the process whose pid a test script wrote to `path` (`echo $! > path`): the
/// lingering `sleep`s these tests create on purpose, which must not outlive the test.
func killRecordedProcess(at path: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8),
          let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1
    else { return }
    kill(pid, SIGKILL)
}

private func recordedPID(at path: String) -> pid_t? {
    (try? String(contentsOfFile: path, encoding: .utf8))
        .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

private func makePIDFilePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ffmpegprocess-test-\(UUID().uuidString).pid").path
}

private enum StreamEvent: Equatable {
    case stdout(String)
    case stderr(String)
    case terminated(Int32)
}

/// Starts `script` with both streams captured and returns the shared event log (callbacks in
/// delivery order) plus a flag that flips when onTermination arrives.
private final class ScriptRun {
    let process = FFmpegProcess()
    private(set) var events: [StreamEvent] = []
    private(set) var terminated = false

    init(_ script: String) throws {
        process.onStdoutLine = { [unowned self] in self.events.append(.stdout($0)) }
        process.onStderrLine = { [unowned self] in self.events.append(.stderr($0)) }
        process.onTermination = { [unowned self] in self.events.append(.terminated($0)); self.terminated = true }
        try process.start(executable: "/bin/sh", arguments: ["-c", script])
    }

    func lines(_ pick: (StreamEvent) -> String?) -> [String] { events.compactMap(pick) }
    var stdout: [String] { lines { if case .stdout(let l) = $0 { return l } else { return nil } } }
    var stderr: [String] { lines { if case .stderr(let l) = $0 { return l } else { return nil } } }
}

/// Number of file descriptors this process has open (the directory stream itself is one,
/// constantly, so differences are meaningful).
private func openDescriptorCount() -> Int {
    guard let dir = opendir("/dev/fd") else { return -1 }
    defer { closedir(dir) }
    var count = 0
    while readdir(dir) != nil { count += 1 }
    return count
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

    // MARK: a descendant that keeps the pipes open after the process has exited

    test("a descendant holding the pipes open delays termination by the grace period, not its lifetime") {
        // The shell exits at once, but its background `sleep` inherited stdout and stderr, so
        // neither pipe reaches EOF for 20 s. Everything the shell wrote must still arrive, in
        // order, before onTermination, which must not wait for the sleep.
        let pidFile = makePIDFilePath()
        defer { killRecordedProcess(at: pidFile); try? FileManager.default.removeItem(atPath: pidFile) }
        let started = Date()
        let run = try ScriptRun(
            "echo a; printf 'partial-out'; echo err >&2; printf 'partial-err' >&2; "
            + "(sleep 20 & echo $! > '\(pidFile)'); exit 3")
        try expect(spinMainRunLoop(timeout: 8) { run.terminated }, "never terminated: \(run.events)")
        let elapsed = Date().timeIntervalSince(started)
        try expect(elapsed < 6, "termination took \(elapsed)s; it waited for the descendant")

        guard let sleeper = recordedPID(at: pidFile) else { throw TestFailure(description: "no pid recorded") }
        try expect(kill(sleeper, 0) == 0, "the sleep should still be holding the pipes at this point")

        try expectEqual(run.events.last, .terminated(3))
        try expectEqual(run.stdout, ["a", "partial-out"])
        try expectEqual(run.stderr, ["err", "partial-err"])
        try expectEqual(run.events.filter { if case .terminated = $0 { true } else { false } }.count, 1)
    }

    test("output from a lingering descendant is delivered during the grace period and never after termination") {
        // A background loop keeps printing after the shell has exited. It was already running
        // when the shell exited, so its early lines may arrive, but nothing may follow onTermination.
        let pidFile = makePIDFilePath()
        defer { killRecordedProcess(at: pidFile); try? FileManager.default.removeItem(atPath: pidFile) }
        let run = try ScriptRun(
            "echo first; (while :; do echo tick; sleep 0.05; done & echo $! > '\(pidFile)'); exit 0")
        try expect(spinMainRunLoop(timeout: 8) { run.terminated }, "never terminated: \(run.events.prefix(5))")
        let countAtTermination = run.events.count
        _ = spinMainRunLoop(timeout: 0.5) { false }  // anything wrongly delivered after the callback lands here
        try expectEqual(run.events.count, countAtTermination)
        try expectEqual(run.events.last, .terminated(0))
        try expectEqual(run.stdout.first, "first")
    }

    test("stopping the readers of a lingering descendant leaks no file descriptors") {
        func runOrphanScenario() throws {
            let pidFile = makePIDFilePath()
            defer { killRecordedProcess(at: pidFile); try? FileManager.default.removeItem(atPath: pidFile) }
            let run = try ScriptRun("echo x; echo y >&2; (sleep 20 & echo $! > '\(pidFile)')")
            try expect(spinMainRunLoop(timeout: 8) { run.terminated }, "never terminated")
        }
        try runOrphanScenario()  // warm-up: lets Foundation open whatever it keeps for good
        _ = spinMainRunLoop(timeout: 0.3) { false }
        let before = openDescriptorCount()
        for _ in 0..<3 { try runOrphanScenario() }
        _ = spinMainRunLoop(timeout: 0.3) { false }
        let after = openDescriptorCount()
        try expect(before > 0 && after == before, "open descriptors went from \(before) to \(after)")
    }

    test("a normal exit does not wait for the grace period") {
        let started = Date()
        let run = try ScriptRun("echo done >&2; exit 0")
        try expect(spinMainRunLoop(timeout: 8) { run.terminated }, "never terminated")
        let elapsed = Date().timeIntervalSince(started)
        try expect(elapsed < 1.0, "a plain exit took \(elapsed)s")
        try expectEqual(run.events, [.stderr("done"), .terminated(0)])
    }
}
