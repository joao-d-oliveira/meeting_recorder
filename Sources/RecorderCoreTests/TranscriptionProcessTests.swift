import Combine
import Foundation
import RecorderCore

// Tests that run real child processes: FFmpegProcess's stdout/environment/cwd support,
// TranscriptionController against stub pipelines, and Pipeline/run.sh itself against a stub
// Python and ffmpeg in a throwaway HOME (so no model is loaded and ~/.cache is never touched).

private func waitOnMain(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
}

private struct RunResult {
    var stdout: [String] = []
    var stderr: [String] = []
    var status: Int32 = -1
}

private func runProcess(
    _ executable: String, _ arguments: [String],
    environment: [String: String]? = nil, currentDirectory: String? = nil,
    timeout: TimeInterval = 30
) throws -> RunResult {
    let process = FFmpegProcess()
    var result = RunResult()
    var done = false
    process.onStdoutLine = { result.stdout.append($0) }
    process.onStderrLine = { result.stderr.append($0) }
    process.onTermination = { result.status = $0; done = true }
    try process.start(
        executable: executable, arguments: arguments,
        environment: environment, currentDirectory: currentDirectory)
    try expect(waitOnMain(timeout: timeout) { done }, "timed out waiting for \(executable) \(arguments)")
    return result
}

/// realpath(3): /var/folders/... is /private/var/folders/... (URL.resolvingSymlinksInPath would drop the /private).
private func physicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

private func makeTempDirectory(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeExecutable(_ url: URL, _ script: String) {
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(script.utf8).write(to: url)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

func runTranscriptionProcessTests() {
    test("process delivers stdout lines when a handler is set") {
        let result = try runProcess("/bin/sh", ["-c", #"printf 'a\nb\rc\n'; printf 'e\n' >&2"#])
        try expectEqual(result.stdout, ["a", "b", "c"])
        try expectEqual(result.stderr, ["e"])
        try expectEqual(result.status, 0)
    }

    test("lines on both streams are delivered while the process is still running") {
        // The recording's level meters depend on live stderr lines, not output at exit.
        let process = FFmpegProcess()
        var out: [String] = [], err: [String] = []
        var terminated = false
        process.onStdoutLine = { out.append($0) }
        process.onStderrLine = { err.append($0) }
        process.onTermination = { _ in terminated = true }
        try process.start(executable: "/bin/sh", arguments: ["-c", "echo out1; echo err1 >&2; sleep 30"])
        try expect(waitOnMain(timeout: 10) { !out.isEmpty && !err.isEmpty }, "no live output: \(out) \(err)")
        try expect(process.isRunning && !terminated)
        try expectEqual(out, ["out1"])
        try expectEqual(err, ["err1"])
        process.forceKill()
        try expect(waitOnMain(timeout: 10) { terminated }, "process did not terminate")
    }

    test("merging stderr into stdout keeps the exact order of the output") {
        let process = FFmpegProcess()
        process.mergesStderrIntoStdout = true
        var out: [String] = [], err: [String] = []
        var terminated = false
        process.onStdoutLine = { out.append($0) }
        process.onStderrLine = { err.append($0) }
        process.onTermination = { _ in terminated = true }
        let script = "i=1; while [ $i -le 300 ]; do echo o$i; echo e$i >&2; i=$((i+1)); done"
        try process.start(executable: "/bin/sh", arguments: ["-c", script])
        try expect(waitOnMain(timeout: 20) { terminated }, "timed out")
        let expected = (1...300).flatMap { ["o\($0)", "e\($0)"] }
        try expect(out == expected, "lines were reordered or lost (\(out.count) of \(expected.count))")
        try expectEqual(err, [])
    }

    test("process drains large stdout and stderr completely and in order before terminating") {
        let count = 20_000
        let result = try runProcess("/bin/sh", ["-c", "seq 1 \(count); seq 1 \(count) >&2; exit 4"])
        let expected = (1...count).map(String.init)
        try expect(result.stdout == expected, "stdout lines were dropped or reordered (\(result.stdout.count))")
        try expect(result.stderr == expected, "stderr lines were dropped or reordered (\(result.stderr.count))")
        try expectEqual(result.status, 4)
    }

    test("multi-byte characters survive being split across reads") {
        let count = 100_000
        let result = try runProcess("/bin/sh", ["-c", "yes 'é' | head -n \(count) | tr -d '\\n'; echo"])
        try expectEqual(result.stdout.count, 1)
        try expect(result.stdout.first == String(repeating: "é", count: count), "line was corrupted")
    }

    test("an explicit environment replaces the inherited one") {
        let result = try runProcess("/usr/bin/env", [], environment: ["ONLY_THIS": "yes"])
        try expect(result.stdout.contains("ONLY_THIS=yes"), "variable missing: \(result.stdout)")
        try expect(!result.stdout.contains { $0.hasPrefix("HOME=") }, "inherited HOME leaked: \(result.stdout)")
    }

    test("without an explicit environment the child inherits ours") {
        let result = try runProcess("/bin/sh", ["-c", "echo $HOME"])
        try expectEqual(result.stdout, [ProcessInfo.processInfo.environment["HOME"] ?? ""])
    }

    test("the working directory is honoured") {
        let dir = makeTempDirectory("cwd"); defer { try? FileManager.default.removeItem(at: dir) }
        let result = try runProcess("/bin/sh", ["-c", "pwd -P"], currentDirectory: dir.path)
        try expectEqual(result.stdout, [physicalPath(dir.path)])
    }

    test("forceKill with killsDescendants also kills what the script spawned") {
        let process = FFmpegProcess()
        process.killsDescendants = true
        var lines: [String] = []
        var terminated = false
        process.onStdoutLine = { lines.append($0) }
        process.onTermination = { _ in terminated = true }
        try process.start(executable: "/bin/sh", arguments: ["-c", "sleep 60 & echo $!; wait"])
        try expect(waitOnMain(timeout: 10) { !lines.isEmpty }, "child pid never printed")
        guard let child = pid_t(lines[0]) else { throw TestFailure(description: "bad pid line \(lines[0])") }
        try expect(processIsAlive(child))
        process.forceKill()
        try expect(waitOnMain(timeout: 10) { terminated }, "process did not terminate")
        try expect(waitOnMain(timeout: 5) { !processIsAlive(child) }, "grandchild \(child) survived forceKill")
    }

    runControllerWithStubPipelineTests()
}

// MARK: - TranscriptionController with real processes

private func runControllerWithStubPipelineTests() {
    /// A pipeline directory whose run.sh is `body`.
    func stubPipeline(_ body: String) -> (TranscriptionSettings, URL) {
        let dir = makeTempDirectory("stub-pipeline")
        writeExecutable(dir.appendingPathComponent("run.sh"), "#!/bin/bash\n" + body)
        return (TranscriptionSettings(pipelineDirectoryOverride: dir.path), dir)
    }

    func recording() -> (audio: URL, root: URL) {
        let root = makeTempDirectory("stub-recording")
        let audio = root.appendingPathComponent("meeting.flac")
        try! Data("x".utf8).write(to: audio)
        return (audio, root)
    }

    func finishedOrFailed(_ state: TranscriptionState) -> Bool {
        switch state {
        case .finished, .failed, .cancelled: return true
        default: return false
        }
    }

    test("controller runs a stub pipeline end to end and reports stages, progress and the result") {
        let (settings, pipeline) = stubPipeline("""
            echo "STAGE: convert"
            echo "STAGE: transcribe"
            echo "PROGRESS: 50"
            echo "STAGE: diarize"
            echo "some warning" >&2
            mkdir -p "$1"
            guest="${2%%:*}"
            printf '{"turn_count":7,"duration_seconds":12.5,"guest":"%s","interviewer":"%s"}' "$guest" "$INTERVIEWER" \\
              > "$1/${guest}_Transcript.summary.json"
            echo "# t" > "$1/${guest}_Transcript.md"
            echo "STAGE: done"
            """)
        let (audio, root) = recording()
        defer { try? FileManager.default.removeItem(at: pipeline); try? FileManager.default.removeItem(at: root) }

        let controller = TranscriptionController()
        var seen: [TranscriptionState] = []
        let cancellable = controller.$state.sink { seen.append($0) }
        defer { cancellable.cancel() }

        controller.start(
            request: TranscriptionRequest(audioURL: audio, guestName: "Dana", interviewerName: "Maria"),
            settings: settings)
        try expect(waitOnMain(timeout: 20) { finishedOrFailed(controller.state) }, "never finished")

        guard case .finished(let result) = controller.state else {
            throw TestFailure(description: "expected .finished, got \(controller.state)")
        }
        try expectEqual(result.turnCount, 7)
        try expectEqual(result.durationSeconds, 12.5)
        try expectEqual(result.guest, "Dana")
        try expectEqual(result.interviewer, "Maria")
        try expectEqual(result.transcriptURL.deletingLastPathComponent().path, root.standardizedFileURL.path)
        try expect(seen.contains(.running(stage: .transcribe, progress: 0.5)), "progress 0.5 never published: \(seen)")
        try expect(seen.contains(.running(stage: .diarize, progress: nil)), "diarize never published: \(seen)")
        try expect(controller.recentLog.contains("some warning"), "stderr should reach the log")
    }

    test("controller reports a failing stub pipeline with its output") {
        let (settings, pipeline) = stubPipeline("""
            echo "STAGE: convert"
            echo "stdout detail"
            echo "boom: something broke" >&2
            exit 3
            """)
        let (audio, root) = recording()
        defer { try? FileManager.default.removeItem(at: pipeline); try? FileManager.default.removeItem(at: root) }

        let controller = TranscriptionController()
        controller.start(request: TranscriptionRequest(audioURL: audio, guestName: "Dana"), settings: settings)
        try expect(waitOnMain(timeout: 20) { finishedOrFailed(controller.state) }, "never finished")

        guard case .failed(let message, let tail) = controller.state else {
            throw TestFailure(description: "expected .failed, got \(controller.state)")
        }
        try expect(message.contains("exit status 3"), message)
        try expect(message.contains("boom: something broke"), message)
        try expect(tail.contains("stdout detail") && tail.contains("boom: something broke"), "\(tail)")
    }

    test("controller cancel stops a pipeline that handles SIGINT like run.sh does") {
        // Same cancel handling as run.sh: terminate the running jobs (repeatedly, a fresh fork can
        // swallow the first TERM), then exit.
        let (settings, pipeline) = stubPipeline("""
            trap 'trap "" INT TERM; while P="$(jobs -rp)"; [ -n "$P" ]; do kill $P 2>/dev/null; sleep 0.05; done; exit 130' INT TERM
            echo "STAGE: transcribe"
            sleep 60 &
            echo "child $!"
            wait
            """)
        let (audio, root) = recording()
        defer { try? FileManager.default.removeItem(at: pipeline); try? FileManager.default.removeItem(at: root) }

        let controller = TranscriptionController()
        controller.start(request: TranscriptionRequest(audioURL: audio, guestName: "Dana"), settings: settings)
        try expect(waitOnMain(timeout: 10) { controller.recentLog.contains { $0.hasPrefix("child ") } }, "stub did not start")
        let childLine = controller.recentLog.first { $0.hasPrefix("child ") }!
        let child = pid_t(childLine.dropFirst("child ".count))!

        controller.cancel()
        try expect(waitOnMain(timeout: 10) { finishedOrFailed(controller.state) },
                   "cancel never completed: state \(controller.state), cancelling \(controller.isCancelling), log \(controller.recentLog), child alive \(processIsAlive(child))")
        try expectEqual(controller.state, .cancelled)
        try expect(waitOnMain(timeout: 5) { !processIsAlive(child) }, "child \(child) survived the cancel")
    }

    test("controller cancel kills a pipeline that ignores SIGINT, children included") {
        let (settings, pipeline) = stubPipeline("""
            trap '' INT
            echo "STAGE: transcribe"
            sleep 60 &
            echo "child $!"
            wait
            """)
        let (audio, root) = recording()
        defer { try? FileManager.default.removeItem(at: pipeline); try? FileManager.default.removeItem(at: root) }

        let controller = TranscriptionController(killAfter: 0.3)
        controller.start(request: TranscriptionRequest(audioURL: audio, guestName: "Dana"), settings: settings)
        try expect(waitOnMain(timeout: 10) { controller.recentLog.contains { $0.hasPrefix("child ") } }, "stub did not start")
        let childLine = controller.recentLog.first { $0.hasPrefix("child ") }!
        let child = pid_t(childLine.dropFirst("child ".count))!

        controller.cancel()
        try expect(waitOnMain(timeout: 15) { finishedOrFailed(controller.state) }, "cancel never completed")
        try expectEqual(controller.state, .cancelled)
        try expect(waitOnMain(timeout: 5) { !processIsAlive(child) }, "child \(child) survived the kill")
    }
}

// MARK: - Pipeline/run.sh against a stub Python and ffmpeg

/// A throwaway HOME with ~/.cache/diarize/.venv/bin/python and an `ffmpeg` on PATH that are
/// shell stubs, so run.sh's own logic (stages, cache keys, fail-fast, cancel) runs for real.
private struct StubHome {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var cache: URL { home.appendingPathComponent(".cache/diarize") }
    var bin: URL { root.appendingPathComponent("bin") }
    var state: URL { root.appendingPathComponent("state") }

    init(voiceprint: Bool = true) {
        root = makeTempDirectory("stub-home")
        try! FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        writeExecutable(cache.appendingPathComponent(".venv/bin/python"), """
            #!/bin/sh
            if [ "$1" = "-c" ]; then printf '%s\\n' "$3" | tr 'A-Z' 'a-z'; exit 0; fi
            case "$(basename "$1")" in
              transcribe.py)
                echo $$ > "$STUB_STATE/transcribe.pid"
                echo "PROGRESS: 40"
                if [ -n "${STUB_SLEEP:-}" ]; then exec sleep "$STUB_SLEEP"; fi
                echo '{}' > "$3.part"; mv "$3.part" "$3"
                echo "PROGRESS: 100"
                ;;
              diarize.py)
                out="$2"; spec="$3"; guest="${spec%%:*}"
                mkdir -p "$out"
                echo "# stub" > "$out/${guest}_Transcript.md"
                echo '{"turn_count":1,"duration_seconds":1.0}' > "$out/${guest}_Transcript.summary.json"
                echo "wrote $out/${guest}_Transcript.md"
                ;;
            esac
            """)
        writeExecutable(bin.appendingPathComponent("ffmpeg"), """
            #!/bin/sh
            for a in "$@"; do last="$a"; done
            echo "$last" >> "$STUB_STATE/ffmpeg.log"
            echo wav > "$last"
            """)
        if voiceprint {
            try! Data("vp".utf8).write(to: cache.appendingPathComponent("voiceprint-joao.npy"))
        }
    }

    var environment: [String: String] {
        ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "STUB_STATE": state.path]
    }

    func audio(folder: String, content: String = "audio") -> URL {
        let dir = root.appendingPathComponent("recordings/\(folder)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("meeting.flac")
        try! Data(content.utf8).write(to: url)
        return url
    }

    var ffmpegCalls: Int {
        let log = (try? String(contentsOf: state.appendingPathComponent("ffmpeg.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").count
    }

    func cacheFiles(withSuffix suffix: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).filter { $0.hasSuffix(suffix) }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func pipelineDirectory() throws -> URL {
    guard let dir = PipelineLocator().locate(override: nil) else {
        throw TestFailure(description: "Pipeline directory not found")
    }
    return dir
}

private func runScript(
    _ stub: StubHome, _ arguments: [String], extraEnvironment: [String: String] = [:]
) throws -> RunResult {
    let script = try pipelineDirectory().appendingPathComponent("run.sh").path
    var env = stub.environment
    for (key, value) in extraEnvironment { env[key] = value }
    return try runProcess("/bin/bash", [script] + arguments, environment: env)
}

func runPipelineScriptTests() {
    func stageLines(_ result: RunResult) -> [String] { result.stdout.filter { $0.hasPrefix("STAGE:") } }

    test("run.sh prints STAGE and PROGRESS lines in order and writes the outputs") {
        let stub = StubHome(); defer { stub.remove() }
        let audio = stub.audio(folder: "a")
        let out = stub.root.appendingPathComponent("out")
        let result = try runScript(stub, [out.path, "Dana:\(audio.path)"])
        try expectEqual(result.status, 0)
        try expectEqual(stageLines(result), ["STAGE: convert", "STAGE: transcribe", "STAGE: diarize", "STAGE: done"])
        try expect(result.stdout.contains("PROGRESS: 40"), "no progress line in \(result.stdout)")
        try expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Dana_Transcript.md").path))
        try expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Dana_Transcript.summary.json").path))
        try expectEqual(stub.cacheFiles(withSuffix: ".wav").count, 1)
        try expectEqual(stub.cacheFiles(withSuffix: ".json").count, 1)
        try expect(stub.cacheFiles(withSuffix: ".part").isEmpty, "partial files left behind")
        try expectEqual(result.stderr, [])
    }

    test("run.sh reuses the cache for the same file") {
        let stub = StubHome(); defer { stub.remove() }
        let audio = stub.audio(folder: "a")
        let out = stub.root.appendingPathComponent("out").path
        _ = try runScript(stub, [out, "Dana:\(audio.path)"])
        let second = try runScript(stub, [out, "Dana:\(audio.path)"])
        try expectEqual(second.status, 0)
        try expectEqual(stub.ffmpegCalls, 1)
        try expect(second.stdout.contains("Using cached transcription"), "\(second.stdout)")
        try expectEqual(stageLines(second), ["STAGE: convert", "STAGE: transcribe", "STAGE: diarize", "STAGE: done"])
    }

    test("two different recordings that are both called meeting.flac never share a cache entry") {
        let stub = StubHome(); defer { stub.remove() }
        let first = stub.audio(folder: "2026-11-15 10.00", content: "same bytes")
        let second = stub.audio(folder: "2026-11-15 11.00", content: "same bytes")
        let out = stub.root.appendingPathComponent("out").path
        _ = try runScript(stub, [out, "Dana:\(first.path)"])
        let result = try runScript(stub, [out, "Dana:\(second.path)"])
        try expect(!result.stdout.contains("Using cached transcription"), "second recording reused the first's transcript")
        try expect(!result.stdout.contains("Using cached 16 kHz conversion"), "second recording reused the first's WAV")
        try expectEqual(stub.ffmpegCalls, 2)
        try expectEqual(stub.cacheFiles(withSuffix: ".wav").count, 2)
        try expectEqual(stub.cacheFiles(withSuffix: ".json").count, 2)
    }

    test("cache key: stable per file, different per path, content and guest") {
        let stub = StubHome(); defer { stub.remove() }
        let a = stub.audio(folder: "a", content: "one")
        let b = stub.audio(folder: "b", content: "one")
        func key(_ guest: String, _ url: URL) throws -> String {
            let result = try runScript(stub, ["--print-cache-key", "\(guest):\(url.path)"])
            try expectEqual(result.status, 0)
            try expectEqual(result.stdout.count, 1)
            return result.stdout[0]
        }
        let keyA = try key("Dana", a)
        try expectEqual(try key("Dana", a), keyA)
        try expect(keyA.hasPrefix("dana-meeting-"), keyA)
        try expect(try key("Dana", b) != keyA, "same basename in another folder must not collide")
        try expect(try key("Eve", a) != keyA, "guest is part of the key")

        try Data("longer content".utf8).write(to: a)
        let changed = try key("Dana", a)
        try expect(changed != keyA, "an edited file (size changed) must get a new key")

        let sameSizeKey = try key("Dana", a)
        try Data("LONGER CONTENT".utf8).write(to: a)  // same size, newer mtime
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 3600)], ofItemAtPath: a.path)
        try expect(try key("Dana", a) != sameSizeKey, "an edited file (mtime changed) must get a new key")
    }

    test("cache key is safe for odd guest names") {
        let stub = StubHome(); defer { stub.remove() }
        let audio = stub.audio(folder: "a")
        let result = try runScript(stub, ["--print-cache-key", "Maria José (2):\(audio.path)"])
        try expectEqual(result.status, 0)
        try expect(result.stdout[0].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }, result.stdout[0])
    }

    test("run.sh fails fast without a voiceprint and only one recording") {
        let stub = StubHome(voiceprint: false); defer { stub.remove() }
        let audio = stub.audio(folder: "a")
        let result = try runScript(stub, [stub.root.appendingPathComponent("out").path, "Dana:\(audio.path)"])
        try expectEqual(result.status, 1)
        try expect(result.stderr.joined().contains("No voiceprint"), "\(result.stderr)")
        try expect(!stageLines(result).contains("STAGE: transcribe"), "ran the slow steps before failing")
        try expectEqual(stub.ffmpegCalls, 0)
    }

    test("REFRESH_VOICEPRINT with a single recording also fails fast") {
        let stub = StubHome(); defer { stub.remove() }
        let audio = stub.audio(folder: "a")
        let result = try runScript(
            stub, [stub.root.appendingPathComponent("out").path, "Dana:\(audio.path)"],
            extraEnvironment: ["REFRESH_VOICEPRINT": "1"])
        try expectEqual(result.status, 1)
        try expect(result.stderr.joined().contains("only one recording"), "\(result.stderr)")
        try expectEqual(stub.ffmpegCalls, 0)
    }

    test("run.sh rejects missing audio and malformed specs with a clear message") {
        let stub = StubHome(); defer { stub.remove() }
        let out = stub.root.appendingPathComponent("out").path
        let missing = try runScript(stub, [out, "Dana:/nonexistent/\(UUID().uuidString).flac"])
        try expectEqual(missing.status, 1)
        try expect(missing.stderr.joined().contains("Audio not found"), "\(missing.stderr)")

        let audio = stub.audio(folder: "a")
        let noColon = try runScript(stub, [out, audio.path.replacingOccurrences(of: ":", with: "_")])
        try expectEqual(noColon.status, 1)
        let slashGuest = try runScript(stub, [out, "a/b:\(audio.path)"])
        try expectEqual(slashGuest.status, 1)
        try expect(slashGuest.stderr.joined().contains("must not contain '/'"), "\(slashGuest.stderr)")
        let noArgs = try runScript(stub, [])
        try expectEqual(noArgs.status, 1)
    }

    test("run.sh adds Homebrew and ~/.local/bin to a minimal PATH") {
        // ffmpeg only resolves if run.sh adds the stub's directory; put it where run.sh looks.
        let stub = StubHome(); defer { stub.remove() }
        let localBin = stub.home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: stub.bin.appendingPathComponent("ffmpeg"), to: localBin.appendingPathComponent("ffmpeg"))
        let audio = stub.audio(folder: "a")
        let script = try pipelineDirectory().appendingPathComponent("run.sh").path
        var env = stub.environment
        env["PATH"] = "/usr/bin:/bin"  // what a Finder-launched app gets
        let result = try runProcess(
            "/bin/bash", [script, stub.root.appendingPathComponent("out").path, "Dana:\(audio.path)"], environment: env)
        try expectEqual(result.status, 0)
        try expectEqual(stub.ffmpegCalls, 1)
    }

    test("run.sh cancelled the moment a step starts never leaves that step running") {
        // The signal lands anywhere from just before the step's fork to just after it; a child
        // that is between fork and exec swallows a single TERM, so run.sh has to repeat it.
        let stub = StubHome(); defer { stub.remove() }
        let audio = stub.audio(folder: "a")
        let script = try pipelineDirectory().appendingPathComponent("run.sh").path
        var env = stub.environment
        env["STUB_SLEEP"] = "60"
        let pidFile = stub.state.appendingPathComponent("transcribe.pid")

        for round in 1...12 {
            try? FileManager.default.removeItem(at: pidFile)
            let process = FFmpegProcess()
            var result = RunResult()
            var done = false
            process.onStdoutLine = { result.stdout.append($0) }
            process.onStderrLine = { result.stderr.append($0) }
            process.onTermination = { result.status = $0; done = true }
            try process.start(
                executable: "/bin/bash",
                arguments: [script, stub.root.appendingPathComponent("out").path, "Dana:\(audio.path)"],
                environment: env, currentDirectory: nil)
            try expect(waitOnMain(timeout: 15) { result.stdout.contains("STAGE: transcribe") }, "round \(round): never reached transcribe")
            process.interrupt()
            try expect(waitOnMain(timeout: 15) { done }, "round \(round): run.sh did not exit after SIGINT")
            try expectEqual(result.status, 130)
            _ = waitOnMain(timeout: 0.3) { false }  // a leaked step would write its pid file by now
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let child = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                try expect(waitOnMain(timeout: 3) { !processIsAlive(child) }, "round \(round): step \(child) survived the cancel")
            }
            try expect(stub.cacheFiles(withSuffix: ".part").isEmpty, "round \(round): partial files left behind")
        }
    }

    test("run.sh cancels on SIGINT: stops its child, removes partial files, exits 130") {
        let stub = StubHome(); defer { stub.remove() }
        let audio = stub.audio(folder: "a")
        let script = try pipelineDirectory().appendingPathComponent("run.sh").path
        var env = stub.environment
        env["STUB_SLEEP"] = "60"

        let process = FFmpegProcess()
        var result = RunResult()
        var done = false
        process.onStdoutLine = { result.stdout.append($0) }
        process.onStderrLine = { result.stderr.append($0) }
        process.onTermination = { result.status = $0; done = true }
        try process.start(
            executable: "/bin/bash",
            arguments: [script, stub.root.appendingPathComponent("out").path, "Dana:\(audio.path)"],
            environment: env, currentDirectory: nil)

        let pidFile = stub.state.appendingPathComponent("transcribe.pid")
        try expect(waitOnMain(timeout: 15) { FileManager.default.fileExists(atPath: pidFile.path) }, "transcribe never started")
        _ = waitOnMain(timeout: 0.2) { false }
        let child = pid_t((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        try expect(processIsAlive(child))

        process.interrupt()
        try expect(waitOnMain(timeout: 15) { done }, "run.sh did not exit after SIGINT")
        try expectEqual(result.status, 130)
        try expect(result.stderr.contains("Cancelled"), "\(result.stderr)")
        try expect(waitOnMain(timeout: 5) { !processIsAlive(child) }, "transcribe child survived the cancel")
        try expect(stub.cacheFiles(withSuffix: ".part").isEmpty, "partial files left behind")
        try expect(stub.cacheFiles(withSuffix: ".json").isEmpty, "a half-done transcription was cached")
        try expect(!stageLines(result).contains("STAGE: diarize"), "kept going after the cancel")
    }
}
