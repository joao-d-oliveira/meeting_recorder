import Foundation
import RecorderCore

// Pipeline/run.sh and setup.sh against stub `uv`, `ffmpeg` and Python in a throwaway HOME:
// cancelling during setup, convert and transcribe, the "environment is ready" marker, runs
// that overlap on one recording, INTERVIEWER validation, and what is left in the cache after
// a run. No model is loaded and the real ~/.cache/diarize and its venv are never touched.
//
// Every "leftover file" assertion is preceded by a check that the file did exist at the moment
// of the cancel, so a stub that never got as far cannot make a test pass by accident.

private func waitOnMain(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
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

private func processIsAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

// MARK: - Stubs

/// What `$VENV/bin/python` is. `-c` is the import check; it succeeds only once the stub `uv pip
/// install` has run (the `installed` file beside bin/) and STUB_IMPORTS_OK is not 0.
private let pythonStub = #"""
#!/bin/sh
here="$(cd "$(dirname "$0")" && pwd)"
if [ "$1" = "-c" ]; then
  echo "$2" >> "$STUB_STATE/import-check.log"
  [ -f "$here/../installed" ] && [ "${STUB_IMPORTS_OK:-1}" = 1 ]
  exit $?
fi
case "$(basename "$1")" in
  transcribe.py)
    # transcribe.py WAV JSON [PART]; the part file defaults to JSON.part, as in the real script
    part="${4:-$3.part}"
    echo "$part" >> "$STUB_STATE/transcribe.parts"
    [ -f "$2" ] || { echo "transcribe: cannot read $2" >&2; exit 1; }
    echo "PROGRESS: 40"
    echo '{"partial' > "$part"
    if [ -n "${STUB_TRANSCRIBE_HANG:-}" ]; then echo $$ > "$STUB_STATE/transcribe.pid"; exec sleep 60; fi
    if [ -n "${STUB_TRANSCRIBE_SLEEP:-}" ]; then sleep "$STUB_TRANSCRIBE_SLEEP"; fi
    echo '{}' > "$part"
    mv "$part" "$3"
    echo "PROGRESS: 100"
    ;;
  diarize.py)
    # diarize.py OUT Guest:WAV:JSON ... --interviewer NAME
    out="$2"; shift 2
    echo "$*" >> "$STUB_STATE/diarize.args"
    touch "$STUB_STATE/diarize.started"
    if [ -n "${STUB_DIARIZE_SLEEP:-}" ]; then sleep "$STUB_DIARIZE_SLEEP"; fi
    for spec in "$@"; do
      case "$spec" in *:*:*) ;; *) continue ;; esac
      guest="${spec%%:*}"; rest="${spec#*:}"; wav="${rest%:*}"
      [ -f "$wav" ] || { echo "diarize: cannot read $wav" >&2; exit 1; }
      echo "$wav" >> "$STUB_STATE/diarize.wavs"
      cat "$wav" >> "$STUB_STATE/diarize.wav-content"
    done
    [ -z "${STUB_DIARIZE_FAIL:-}" ] || { echo "diarize: boom" >&2; exit 1; }
    for spec in "$@"; do
      case "$spec" in *:*:*) ;; *) continue ;; esac
      guest="${spec%%:*}"
      mkdir -p "$out"
      echo "# stub" > "$out/${guest}_Transcript.md"
      echo '{"turn_count":1,"duration_seconds":1.0}' > "$out/${guest}_Transcript.summary.json"
    done
    ;;
esac
"""#

/// `ffmpeg ... OUTPUT`: writes the first half of its output at once, the second half after
/// STUB_FFMPEG_SLEEP seconds (or never, with STUB_FFMPEG_HANG).
private let ffmpegStub = #"""
#!/bin/sh
for a in "$@"; do last="$a"; done
echo "$last" >> "$STUB_STATE/ffmpeg.log"
echo "$$ begin" > "$last"
if [ -n "${STUB_FFMPEG_HANG:-}" ]; then echo $$ > "$STUB_STATE/ffmpeg.pid"; exec sleep 60; fi
if [ -n "${STUB_FFMPEG_SLEEP:-}" ]; then sleep "$STUB_FFMPEG_SLEEP"; fi
echo "$$ end" >> "$last"
"""#

/// `uv venv PATH ...` creates PATH/bin/python at once; `uv pip install --python PY ...` is the
/// slow, interruptible, failable part, and the only thing that makes the import check pass.
private let uvStub = #"""
#!/bin/sh
echo "$*" >> "$STUB_STATE/uv.log"
case "$1" in
  venv)
    mkdir -p "$2/bin"
    cp "$STUB_PYTHON" "$2/bin/python"
    chmod +x "$2/bin/python"
    ;;
  pip)
    touch "$STUB_STATE/uv-install.started"
    if [ -n "${STUB_UV_SLEEP:-}" ]; then echo $$ > "$STUB_STATE/uv.pid"; exec sleep "$STUB_UV_SLEEP"; fi
    [ -z "${STUB_UV_FAIL:-}" ] || { echo "uv: no network" >&2; exit 1; }
    touch "$(dirname "$(dirname "$4")")/installed"
    ;;
esac
"""#

private struct Sandbox {
    enum Venv {
        case none            // nothing in ~/.cache/diarize
        case leftover        // a .venv folder without a python (an interrupted `uv venv`)
        case unfinished      // python exists, packages don't (a cancelled `uv pip install`)
        case complete        // python and packages, but no .ready marker (made before the marker existed)
        case ready           // complete, with the marker
    }

    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var cache: URL { home.appendingPathComponent(".cache/diarize") }
    var venv: URL { cache.appendingPathComponent(".venv") }
    var bin: URL { root.appendingPathComponent("bin") }
    var state: URL { root.appendingPathComponent("state") }
    var out: URL { root.appendingPathComponent("out") }

    init(venv kind: Venv = .ready, voiceprints: [String] = ["joao"]) {
        root = makeTempDirectory("pipeline-sandbox")
        try! FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        writeExecutable(root.appendingPathComponent("python-stub"), pythonStub)
        writeExecutable(bin.appendingPathComponent("ffmpeg"), ffmpegStub)
        writeExecutable(bin.appendingPathComponent("uv"), uvStub)
        try! FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        switch kind {
        case .none: break
        case .leftover:
            try! FileManager.default.createDirectory(
                at: venv.appendingPathComponent("lib"), withIntermediateDirectories: true)
        case .unfinished, .complete, .ready:
            writeExecutable(venv.appendingPathComponent("bin/python"), pythonStub)
            if kind != .unfinished { touch(venv.appendingPathComponent("installed")) }
            if kind == .ready { touch(venv.appendingPathComponent(".ready")) }
        }
        for name in voiceprints { touch(cache.appendingPathComponent("voiceprint-\(name).npy")) }
    }

    func touch(_ url: URL) { try! Data("x".utf8).write(to: url) }

    var environment: [String: String] {
        [
            "HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin", "STUB_STATE": state.path,
            "STUB_PYTHON": root.appendingPathComponent("python-stub").path,
        ]
    }

    func audio(_ folder: String, content: String = "audio") -> URL {
        let dir = root.appendingPathComponent("recordings/\(folder)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("meeting.flac")
        try! Data(content.utf8).write(to: url)
        return url
    }

    func log(_ name: String) -> [String] {
        let text = (try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func stateFileExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: state.appendingPathComponent(name).path)
    }

    func cacheFiles(where predicate: (String) -> Bool = { _ in true }) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []).filter(predicate).sorted()
    }

    func cacheFiles(withSuffix suffix: String) -> [String] {
        cacheFiles { $0.hasSuffix(suffix) }
    }

    /// Cached 16 kHz conversions, not this run's private `.use.wav` links.
    var sharedWavs: [String] { cacheFiles { $0.hasSuffix(".wav") && !$0.hasSuffix(".use.wav") } }
    var cachedJSON: [String] { cacheFiles(withSuffix: ".json").filter { !$0.hasSuffix(".part") } }
    var useLinks: [String] { cacheFiles(withSuffix: ".use.wav") }
    var parts: [String] { cacheFiles(withSuffix: ".part") }
    var ready: Bool { FileManager.default.fileExists(atPath: venv.appendingPathComponent(".ready").path) }
    var venvPythonExists: Bool {
        FileManager.default.fileExists(atPath: venv.appendingPathComponent("bin/python").path)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Running the script

private func pipelineDirectory() throws -> URL {
    guard let dir = PipelineLocator().locate(override: nil) else {
        throw TestFailure(description: "Pipeline directory not found")
    }
    return dir
}

/// run.sh started in the background, so a test can interrupt it or start a second one.
private final class ScriptRun {
    let process = FFmpegProcess()
    private(set) var stdout: [String] = []
    private(set) var stderr: [String] = []
    private(set) var status: Int32 = -1
    private(set) var done = false

    init(_ sandbox: Sandbox, _ arguments: [String], environment extra: [String: String] = [:]) throws {
        let script = try pipelineDirectory().appendingPathComponent("run.sh").path
        var env = sandbox.environment
        for (key, value) in extra { env[key] = value }
        process.onStdoutLine = { [unowned self] in stdout.append($0) }
        process.onStderrLine = { [unowned self] in stderr.append($0) }
        process.onTermination = { [unowned self] in status = $0; done = true }
        try process.start(
            executable: "/bin/bash", arguments: [script] + arguments, environment: env, currentDirectory: nil)
    }

    @discardableResult
    func wait(timeout: TimeInterval = 30) -> Bool {
        waitOnMain(timeout: timeout) { self.done }
    }

    var stages: [String] { stdout.filter { $0.hasPrefix("STAGE:") } }

    deinit { process.forceKill() }
}

private func run(
    _ sandbox: Sandbox, _ arguments: [String], environment: [String: String] = [:]
) throws -> ScriptRun {
    let script = try ScriptRun(sandbox, arguments, environment: environment)
    try expect(script.wait(), "run.sh did not finish: \(script.stdout) \(script.stderr)")
    return script
}

private func processID(in file: URL) -> pid_t? {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Tests

func runPipelineRobustnessTests() {
    runCancelTests()
    runEnvironmentTests()
    runOverlappingRunTests()
    runInterviewerTests()
    runCacheContentsTests()
}

private func runCancelTests() {
    test("cancel while ffmpeg is writing: exits 130 promptly, its part file and the process are gone") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let script = try ScriptRun(
            sandbox, [sandbox.out.path, "Dana:\(audio.path)"], environment: ["STUB_FFMPEG_HANG": "1"])
        let ffmpegPID = sandbox.state.appendingPathComponent("ffmpeg.pid")
        try expect(waitOnMain(timeout: 15) { !sandbox.parts.isEmpty && processID(in: ffmpegPID) != nil },
                   "ffmpeg never started writing: \(script.stdout) \(script.stderr)")
        let part = sandbox.parts[0]
        try expect(part.contains(".wav.") && part.hasSuffix(".part"), "unexpected part name \(part)")
        guard let ffmpeg = processID(in: ffmpegPID) else { throw TestFailure(description: "no ffmpeg pid") }

        let cancelledAt = Date()
        script.process.interrupt()
        try expect(script.wait(timeout: 10), "run.sh did not exit after SIGINT")
        try expect(Date().timeIntervalSince(cancelledAt) < 2, "cancelling took too long")
        try expectEqual(script.status, 130)
        try expect(waitOnMain(timeout: 5) { !processIsAlive(ffmpeg) }, "ffmpeg \(ffmpeg) survived the cancel")
        try expectEqual(sandbox.parts, [])
        try expectEqual(sandbox.sharedWavs, [])
        try expectEqual(sandbox.useLinks, [])
    }

    test("cancel while transcribing: the JSON part file is removed, nothing is cached as a transcription") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let script = try ScriptRun(
            sandbox, [sandbox.out.path, "Dana:\(audio.path)"], environment: ["STUB_TRANSCRIBE_HANG": "1"])
        let transcribePID = sandbox.state.appendingPathComponent("transcribe.pid")
        try expect(waitOnMain(timeout: 15) { processID(in: transcribePID) != nil },
                   "transcribe never started: \(script.stdout) \(script.stderr)")
        try expect(sandbox.parts.contains { $0.contains(".json.") && $0.hasSuffix(".part") },
                   "no JSON part file during the run: \(sandbox.parts)")
        guard let python = processID(in: transcribePID) else { throw TestFailure(description: "no transcribe pid") }

        script.process.interrupt()
        try expect(script.wait(timeout: 10), "run.sh did not exit after SIGINT")
        try expectEqual(script.status, 130)
        try expect(waitOnMain(timeout: 5) { !processIsAlive(python) }, "transcribe \(python) survived the cancel")
        try expectEqual(sandbox.parts, [])
        try expectEqual(sandbox.cachedJSON, [])
        try expectEqual(sandbox.useLinks, [])
        // The finished conversion is kept, so a retry doesn't redo it.
        try expectEqual(sandbox.sharedWavs.count, 1)
    }

    test("cancel during setup: run.sh exits promptly, uv is stopped, and the next run runs setup again") {
        let sandbox = Sandbox(venv: .none); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let script = try ScriptRun(
            sandbox, [sandbox.out.path, "Dana:\(audio.path)"], environment: ["STUB_UV_SLEEP": "60"])
        let uvPID = sandbox.state.appendingPathComponent("uv.pid")
        try expect(waitOnMain(timeout: 15) { processID(in: uvPID) != nil },
                   "uv pip install never started: \(script.stdout) \(script.stderr)")
        guard let uv = processID(in: uvPID) else { throw TestFailure(description: "no uv pid") }
        try expect(processIsAlive(uv))
        try expect(sandbox.venvPythonExists, "`uv venv` should already have created python")

        let cancelledAt = Date()
        script.process.interrupt()
        try expect(script.wait(timeout: 10), "run.sh did not exit after SIGINT")
        let took = Date().timeIntervalSince(cancelledAt)
        try expect(took < 2, "cancelling during setup took \(took)s")
        try expectEqual(script.status, 130)
        try expect(script.stderr.contains("Cancelled"), "\(script.stderr)")
        try expect(waitOnMain(timeout: 5) { !processIsAlive(uv) }, "uv \(uv) survived the cancel")
        try expectEqual(script.stages, ["STAGE: setup"])
        try expectEqual(sandbox.log("ffmpeg.log"), [])
        // The half-made environment must not look finished.
        try expect(sandbox.venvPythonExists)
        try expect(!sandbox.ready, "an interrupted install was marked ready")

        let retry = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"])
        try expectEqual(retry.status, 0)
        try expectEqual(retry.stages, ["STAGE: setup", "STAGE: convert", "STAGE: transcribe", "STAGE: diarize", "STAGE: done"])
        try expect(sandbox.ready)
        // The venv was kept and completed, not recreated.
        try expectEqual(sandbox.log("uv.log").filter { $0.hasPrefix("venv ") }.count, 1)
        try expectEqual(sandbox.log("uv.log").filter { $0.hasPrefix("pip ") }.count, 2)
    }

    test("a failed install leaves no ready marker, fails the run, and the next run finishes the install") {
        let sandbox = Sandbox(venv: .none); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let args = [sandbox.out.path, "Dana:\(audio.path)"]
        let failed = try run(sandbox, args, environment: ["STUB_UV_FAIL": "1"])
        try expectEqual(failed.status, 1)
        try expect(failed.stderr.contains { $0.contains("Setup of the transcription environment failed") }, "\(failed.stderr)")
        try expect(sandbox.venvPythonExists)
        try expect(!sandbox.ready)
        try expectEqual(sandbox.log("ffmpeg.log"), [])

        let retry = try run(sandbox, args)
        try expectEqual(retry.status, 0)
        try expect(retry.stages.first == "STAGE: setup", "\(retry.stages)")
        try expect(sandbox.ready)
    }
}

private func runEnvironmentTests() {
    let importCheck = "import mlx_whisper, speechbrain, sklearn, soundfile"

    test("a complete venv without the marker keeps working: no setup, and the marker is created") {
        let sandbox = Sandbox(venv: .complete); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let args = [sandbox.out.path, "Dana:\(audio.path)"]
        let first = try run(sandbox, args)
        try expectEqual(first.status, 0)
        try expect(!first.stages.contains("STAGE: setup"), "\(first.stages)")
        try expectEqual(sandbox.log("uv.log"), [])
        try expectEqual(sandbox.log("import-check.log"), [importCheck])
        try expect(sandbox.ready, "marker not created after a passing import check")

        let second = try run(sandbox, args)
        try expectEqual(second.status, 0)
        try expectEqual(sandbox.log("import-check.log"), [importCheck])  // not checked again
        try expectEqual(sandbox.log("uv.log"), [])
    }

    test("a venv with python but without working imports and without the marker goes through setup") {
        let sandbox = Sandbox(venv: .unfinished); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let result = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"])
        try expectEqual(result.status, 0)
        try expectEqual(result.stages.first, "STAGE: setup")
        try expectEqual(sandbox.log("import-check.log"), [importCheck])
        try expectEqual(sandbox.log("uv.log").filter { $0.hasPrefix("venv ") }.count, 0)
        try expectEqual(sandbox.log("uv.log").filter { $0.hasPrefix("pip ") }.count, 1)
        try expect(sandbox.ready)
    }

    test("with the marker present nothing is checked or installed") {
        let sandbox = Sandbox(venv: .ready); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        // Even a python whose imports would fail is trusted: the marker is the proof.
        let result = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"], environment: ["STUB_IMPORTS_OK": "0"])
        try expectEqual(result.status, 0)
        try expect(!result.stages.contains("STAGE: setup"))
        try expectEqual(sandbox.log("import-check.log"), [])
        try expectEqual(sandbox.log("uv.log"), [])
    }

    test("setup creates the venv and the marker, and clears the leftovers of an interrupted `uv venv`") {
        for kind in [Sandbox.Venv.none, .leftover] {
            let sandbox = Sandbox(venv: kind); defer { sandbox.remove() }
            let audio = sandbox.audio("a")
            let result = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"])
            try expectEqual(result.status, 0)
            try expectEqual(result.stages.first, "STAGE: setup")
            try expectEqual(sandbox.log("uv.log").filter { $0.hasPrefix("venv ") }.count, 1)
            try expect(sandbox.ready)
            try expect(!FileManager.default.fileExists(atPath: sandbox.venv.appendingPathComponent("lib").path),
                       "the leftover folder was kept")
            // The installed environment passes the import check, so later runs skip all of it.
            let again = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"])
            try expect(!again.stages.contains("STAGE: setup"))
        }
    }
}

private func runOverlappingRunTests() {
    test("two runs on the same recording at the same time both succeed and never share a temporary file") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let slow = ["STUB_FFMPEG_SLEEP": "1.2", "STUB_TRANSCRIBE_SLEEP": "1.2", "STUB_DIARIZE_SLEEP": "0.3"]
        let outA = sandbox.root.appendingPathComponent("out-a"), outB = sandbox.root.appendingPathComponent("out-b")
        let a = try ScriptRun(sandbox, [outA.path, "Dana:\(audio.path)"], environment: slow)
        try expect(waitOnMain(timeout: 10) { !sandbox.log("ffmpeg.log").isEmpty }, "first run never converted")
        let b = try ScriptRun(sandbox, [outB.path, "Dana:\(audio.path)"], environment: slow)
        try expect(a.wait(), "run A did not finish")
        try expect(b.wait(), "run B did not finish")
        try expectEqual(a.status, 0)
        try expectEqual(b.status, 0)
        try expect(a.stderr.isEmpty && b.stderr.isEmpty, "\(a.stderr) \(b.stderr)")
        for out in [outA, outB] {
            try expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Dana_Transcript.md").path))
        }

        // They really overlapped: both converted and both transcribed, each into its own part file.
        let ffmpegOutputs = sandbox.log("ffmpeg.log")
        try expectEqual(ffmpegOutputs.count, 2)
        try expectEqual(Set(ffmpegOutputs).count, 2)
        let transcribeParts = sandbox.log("transcribe.parts")
        try expectEqual(transcribeParts.count, 2)
        try expectEqual(Set(transcribeParts).count, 2)
        // Each conversion is complete and from one process: "<pid> begin" then "<pid> end".
        let contents = sandbox.log("diarize.wav-content")
        try expectEqual(contents.count, 4)
        for pair in stride(from: 0, to: contents.count, by: 2) {
            let begin = contents[pair].split(separator: " "), end = contents[pair + 1].split(separator: " ")
            try expect(begin.count == 2 && end.count == 2 && begin[0] == end[0] && begin[1] == "begin" && end[1] == "end",
                       "mixed-up WAV content: \(contents)")
        }
        try expectEqual(sandbox.parts, [])
        try expectEqual(sandbox.useLinks, [])
        try expectEqual(sandbox.cachedJSON.count, 1)
    }

    test("a run that finishes first and deletes the cached WAV does not take it from one still diarizing") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let outA = sandbox.root.appendingPathComponent("out-a"), outB = sandbox.root.appendingPathComponent("out-b")
        let slow = try ScriptRun(sandbox, [outB.path, "Dana:\(audio.path)"], environment: ["STUB_DIARIZE_SLEEP": "2"])
        try expect(waitOnMain(timeout: 15) { sandbox.stateFileExists("diarize.started") }, "slow run never reached diarize")

        let quick = try run(sandbox, [outA.path, "Dana:\(audio.path)"])
        try expectEqual(quick.status, 0)
        try expect(quick.stdout.contains("Using cached 16 kHz conversion"), "second run should have used the cache: \(quick.stdout)")
        try expectEqual(sandbox.sharedWavs, [])  // the quick run cleaned up the cached WAV...
        try expect(!slow.done, "the slow run should still be diarizing")

        try expect(slow.wait(), "slow run did not finish")
        // ...and the slow run, which reads its WAV after that, still found it.
        try expectEqual(slow.status, 0)
        try expect(slow.stderr.isEmpty, "\(slow.stderr)")
        try expect(FileManager.default.fileExists(atPath: outB.appendingPathComponent("Dana_Transcript.md").path))
        let wavs = sandbox.log("diarize.wavs")
        try expectEqual(wavs.count, 2)
        try expect(wavs.allSatisfy { $0.hasSuffix(".use.wav") }, "diarize should get a run-private name: \(wavs)")
        try expectEqual(Set(wavs).count, 2)
        try expectEqual(sandbox.useLinks, [])
    }
}

private func runInterviewerTests() {
    test("INTERVIEWER values that could leave the cache folder or hide the file are rejected up front") {
        let names = ["x/../../evil", "../up", "/abs", ".hidden", "..", "back\\slash", "line\nbreak", "tab\tname", "   "]
        for name in names {
            let sandbox = Sandbox(venv: .none); defer { sandbox.remove() }
            let first = sandbox.audio("a"), second = sandbox.audio("b")
            // Two recordings: the only case in which the pipeline would write a voiceprint.
            let result = try run(
                sandbox, [sandbox.out.path, "Dana:\(first.path)", "Eve:\(second.path)"],
                environment: ["INTERVIEWER": name])
            try expectEqual(result.status, 1)
            try expect(result.stderr.joined().contains("Invalid INTERVIEWER"), "\(name.debugDescription): \(result.stderr)")
            try expectEqual(sandbox.log("uv.log"), [])  // before any setup
            try expectEqual(sandbox.log("ffmpeg.log"), [])
            try expectEqual(sandbox.log("diarize.args"), [])
            try expect(!FileManager.default.fileExists(atPath: sandbox.home.appendingPathComponent(".cache/evil.npy").path))
            try expect(!FileManager.default.fileExists(atPath: sandbox.out.path), "created the output folder")
        }
    }

    test("ordinary INTERVIEWER names, including non-ASCII ones, find their lower-cased voiceprint") {
        // The script's locale is C (no LANG), as for an app started from Finder.
        for (name, file) in [("Ana María", "ana maría"), ("Élodie", "élodie"), ("JOAO", "joao"), ("O'Brien-Smith", "o'brien-smith")] {
            let sandbox = Sandbox(voiceprints: [file]); defer { sandbox.remove() }
            let audio = sandbox.audio("a")
            let result = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"], environment: ["INTERVIEWER": name])
            try expectEqual(result.status, 0)
            try expect(result.stderr.isEmpty, "\(name): \(result.stderr)")
            try expect(sandbox.log("diarize.args").joined().hasSuffix("--interviewer \(name)"), "\(sandbox.log("diarize.args"))")
        }
    }

    test("no voiceprint and one recording fails before any setup, without needing the venv") {
        let sandbox = Sandbox(venv: .none, voiceprints: []); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let result = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"], environment: ["INTERVIEWER": "Zed"])
        try expectEqual(result.status, 1)
        try expect(
            result.stderr.joined().contains("No voiceprint at \(sandbox.cache.path)/voiceprint-zed.npy and only one recording"),
            "\(result.stderr)")
        try expectEqual(result.stages, [])
        try expectEqual(sandbox.log("uv.log"), [])
        try expect(!sandbox.venvPythonExists)
        try expectEqual(sandbox.log("ffmpeg.log"), [])
    }

    test("REFRESH_VOICEPRINT with one recording also fails before any setup") {
        let sandbox = Sandbox(venv: .none); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let result = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"], environment: ["REFRESH_VOICEPRINT": "1"])
        try expectEqual(result.status, 1)
        try expect(result.stderr.joined().contains("only one recording"), "\(result.stderr)")
        try expectEqual(sandbox.log("uv.log"), [])
    }
}

private func runCacheContentsTests() {
    test("the cached WAV is deleted after a successful run, the JSON stays, and a re-run reconverts but skips Whisper") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let args = [sandbox.out.path, "Dana:\(audio.path)"]
        let first = try run(sandbox, args)
        try expectEqual(first.status, 0)
        try expectEqual(first.stages, ["STAGE: convert", "STAGE: transcribe", "STAGE: diarize", "STAGE: done"])
        try expectEqual(sandbox.sharedWavs, [])
        try expectEqual(sandbox.useLinks, [])
        try expectEqual(sandbox.parts, [])
        try expectEqual(sandbox.cachedJSON.count, 1)
        try expectEqual(sandbox.log("ffmpeg.log").count, 1)
        // Whisper's part file is a name of its own, not the shared `<json>.part`.
        let part = sandbox.log("transcribe.parts")
        try expectEqual(part.count, 1)
        try expect(part[0].contains(".json.") && part[0].hasSuffix(".part") && part[0] != sandbox.cache.path + "/" + sandbox.cachedJSON[0] + ".part", part[0])

        let second = try run(sandbox, args)
        try expectEqual(second.status, 0)
        try expectEqual(second.stages, ["STAGE: convert", "STAGE: transcribe", "STAGE: diarize", "STAGE: done"])
        try expect(second.stdout.contains("Converting \(audio.path) -> 16 kHz mono"), "\(second.stdout)")
        try expect(second.stdout.contains("Using cached transcription"), "\(second.stdout)")
        try expectEqual(sandbox.log("ffmpeg.log").count, 2)
        try expectEqual(sandbox.log("transcribe.parts").count, 1)  // Whisper did not run again
        try expectEqual(sandbox.sharedWavs, [])
        try expect(FileManager.default.fileExists(atPath: sandbox.out.appendingPathComponent("Dana_Transcript.md").path))
    }

    test("when diarization fails the WAV and JSON are kept, and the retry reuses both") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let args = [sandbox.out.path, "Dana:\(audio.path)"]
        let failed = try run(sandbox, args, environment: ["STUB_DIARIZE_FAIL": "1"])
        try expect(failed.status != 0)
        try expectEqual(sandbox.sharedWavs.count, 1)
        try expectEqual(sandbox.cachedJSON.count, 1)
        try expectEqual(sandbox.useLinks, [])
        try expectEqual(sandbox.parts, [])

        let retry = try run(sandbox, args)
        try expectEqual(retry.status, 0)
        try expect(retry.stdout.contains("Using cached 16 kHz conversion"), "\(retry.stdout)")
        try expect(retry.stdout.contains("Using cached transcription"), "\(retry.stdout)")
        try expectEqual(sandbox.log("ffmpeg.log").count, 1)
        try expectEqual(sandbox.log("transcribe.parts").count, 1)
        try expectEqual(sandbox.sharedWavs, [])
    }

    test("with two recordings every WAV is deleted after the run") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let first = sandbox.audio("a", content: "one"), second = sandbox.audio("b", content: "two")
        let result = try run(sandbox, [sandbox.out.path, "Dana:\(first.path)", "Eve:\(second.path)"])
        try expectEqual(result.status, 0)
        try expectEqual(sandbox.log("diarize.wavs").count, 2)
        try expectEqual(sandbox.sharedWavs, [])
        try expectEqual(sandbox.useLinks, [])
        try expectEqual(sandbox.cachedJSON.count, 2)
    }

    test("temporary files left by a killed run are swept after a day, live ones and real cache entries are not") {
        let sandbox = Sandbox(); defer { sandbox.remove() }
        let audio = sandbox.audio("a")
        let old = Date(timeIntervalSinceNow: -3 * 24 * 3600)
        func plant(_ name: String, modified: Date) {
            let url = sandbox.cache.appendingPathComponent(name)
            sandbox.touch(url)
            try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        for name in ["k-aaaa.wav.111.part", "k-aaaa.json.111.part", "k-aaaa.111.use.wav", "k-aaaa.wav.part"] {
            plant(name, modified: old)
        }
        plant("k-bbbb.wav.222.part", modified: Date())          // a run that is still going
        plant("k-cccc.wav", modified: old)                      // cache entries are not temporary
        plant("k-cccc.json", modified: old)
        let result = try run(sandbox, [sandbox.out.path, "Dana:\(audio.path)"])
        try expectEqual(result.status, 0)
        try expectEqual(
            sandbox.cacheFiles { $0.hasPrefix("k-") },
            ["k-bbbb.wav.222.part", "k-cccc.json", "k-cccc.wav"])
        try expect(FileManager.default.fileExists(atPath: sandbox.cache.appendingPathComponent("voiceprint-joao.npy").path))
    }
}
