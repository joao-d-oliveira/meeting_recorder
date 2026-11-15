import Combine
import Foundation

/// Runs `Pipeline/run.sh` (Whisper + voiceprint diarization) for one recording and publishes
/// its progress. Like `RecordingController`, everything happens on the main queue.
public final class TranscriptionController: ObservableObject {
    @Published public private(set) var state: TranscriptionState = .idle
    /// True between `cancel()` and the pipeline actually exiting.
    @Published public private(set) var isCancelling = false

    /// PATH entries searched first. Apps launched from Finder only get /usr/bin:/bin.
    public static let searchPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Default process factory: stdout and stderr share one pipe so the log keeps the exact
    /// order of the output, and a force-kill also reaches the python/ffmpeg children of the
    /// shell script.
    public static func makePipelineProcess() -> ProcessRunning {
        let process = FFmpegProcess()
        process.mergesStderrIntoStdout = true
        process.killsDescendants = true
        return process
    }

    private let makeProcess: () -> ProcessRunning
    private let locator: PipelineLocator
    private let fileManager: FileManager
    private let baseEnvironment: [String: String]
    private let bashPath: String
    private let killAfter: TimeInterval
    private let logLimit = 200
    private let failureTailLength = 20

    private var process: ProcessRunning?
    private var run: Run?
    private var logLines: [String] = []
    private var cancelRequested = false
    private var killWork: DispatchWorkItem?

    private struct Run {
        let guest: String
        let outputDirectory: URL
        var transcriptURL: URL { outputDirectory.appendingPathComponent("\(guest)_Transcript.md") }
        var summaryURL: URL { outputDirectory.appendingPathComponent("\(guest)_Transcript.summary.json") }
    }

    /// - Parameters:
    ///   - makeProcess: must return a fresh process per call. It has to deliver stdout lines
    ///     (`onStdoutLine`), which `FFmpegProcess` does.
    ///   - baseEnvironment: merged into the child's environment (defaults to the app's own).
    ///   - killAfter: seconds between asking the pipeline to stop (SIGINT) and SIGKILL.
    public init(
        makeProcess: @escaping () -> ProcessRunning = TranscriptionController.makePipelineProcess,
        locator: PipelineLocator = PipelineLocator(),
        fileManager: FileManager = .default,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        bashPath: String = "/bin/bash",
        killAfter: TimeInterval = 4
    ) {
        self.makeProcess = makeProcess
        self.locator = locator
        self.fileManager = fileManager
        self.baseEnvironment = baseEnvironment
        self.bashPath = bashPath
        self.killAfter = killAfter
    }

    /// The most recent pipeline output (stdout and stderr), oldest first, progress noise removed.
    public var recentLog: [String] { Array(logLines.suffix(failureTailLength)) }

    /// Starts transcribing. Ignored while a run is in progress (including while cancelling).
    /// Ends in `.finished`, `.failed` or `.cancelled`.
    public func start(request: TranscriptionRequest, settings: TranscriptionSettings) {
        guard process == nil else { return }

        logLines = []
        cancelRequested = false
        isCancelling = false
        run = nil

        guard let pipeline = locator.locate(settings: settings) else {
            fail("Transcription pipeline not found. Reinstall the app, or set the pipeline folder in Settings.")
            return
        }
        let audio = request.audioURL.standardizedFileURL
        guard fileManager.fileExists(atPath: audio.path) else {
            fail("Recording not found: \(audio.path)")
            return
        }

        let guest = TranscriptionRequest.sanitizedName(request.guestName, fallback: settings.defaultGuestName)
        let interviewer = TranscriptionRequest.sanitizedName(
            request.interviewerName, fallback: settings.interviewerName, lastResort: "Joao")
        let home = baseEnvironment["HOME"] ?? NSHomeDirectory()

        // The app hands the pipeline one recording, which can only be matched against a saved
        // voiceprint; without one the run would fail after the (possibly multi-GB) first-time
        // setup. Say so right away. Only the pipeline that ships with the app is known to keep
        // its voiceprint there, so a pipeline folder chosen in Settings is left to decide for itself.
        if locator.overrideDirectory(settings.pipelineDirectoryOverride) == nil {
            let voiceprint = Self.voiceprintURL(interviewer: interviewer, home: home)
            guard fileManager.fileExists(atPath: voiceprint.path) else {
                fail("No voiceprint for \(interviewer) at \(voiceprint.path). Create it once with the "
                    + "interview-transcribe skill from 2 or more recordings (e.g. run.sh with two interviews), "
                    + "then try again.")
                return
            }
        }

        let outputDirectory = request.outputDirectory.standardizedFileURL
        let run = Run(guest: guest, outputDirectory: outputDirectory)
        self.run = run

        let proc = makeProcess()
        proc.onStdoutLine = { [weak self] line in self?.handleLine(line) }
        proc.onStderrLine = { [weak self] line in self?.handleLine(line) }
        proc.onTermination = { [weak self] status in self?.handleTermination(status: status) }
        process = proc

        // Published before the launch so the UI never observes a gap between request and run.
        state = .running(stage: .convert, progress: nil)
        do {
            try proc.start(
                executable: bashPath,
                arguments: [
                    pipeline.appendingPathComponent("run.sh").path,
                    outputDirectory.path,
                    "\(guest):\(audio.path)",
                ],
                environment: Self.environment(base: baseEnvironment, interviewer: interviewer, home: home),
                currentDirectory: pipeline.path)
        } catch {
            process = nil
            fail("Could not launch the transcription pipeline: \(error.localizedDescription)")
        }
    }

    /// Asks the pipeline to stop (SIGINT; `run.sh` forwards it to its children), and kills it
    /// if it hasn't exited after `killAfter` seconds. The state becomes `.cancelled` once the
    /// process is gone, so no pipeline is running when you observe `.cancelled`.
    public func cancel() {
        guard case .running = state, let proc = process, !cancelRequested else { return }
        cancelRequested = true
        isCancelling = true
        proc.interrupt()

        // Strong capture: if the controller goes away mid-cancel, the orphan is still killed.
        let work = DispatchWorkItem { proc.forceKill() }
        killWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + killAfter, execute: work)
    }

    /// Returns to `.idle` after a finished/failed/cancelled run. No effect while running.
    public func reset() {
        guard process == nil else { return }
        state = .idle
        logLines = []
        run = nil
    }

    /// Where the pipeline keeps the interviewer's voiceprint:
    /// `<home>/.cache/diarize/voiceprint-<name, lower-cased>.npy` (see `Pipeline/run.sh`).
    public static func voiceprintURL(interviewer: String, home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".cache/diarize/voiceprint-\(interviewer.lowercased()).npy")
    }

    /// Environment for the child: the base environment plus a PATH that finds Homebrew tools,
    /// HOME (the shared ~/.cache/diarize lives under it), and INTERVIEWER. REFRESH_VOICEPRINT is
    /// always dropped so a stray variable can never overwrite the saved voiceprint from the app.
    static func environment(base: [String: String], interviewer: String, home: String) -> [String: String] {
        var env = base
        let preferred = searchPath.split(separator: ":").map(String.init)
        let existing = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (preferred + existing)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .joined(separator: ":")
        env["HOME"] = home
        env["INTERVIEWER"] = interviewer
        env["PIPELINE_PROGRESS"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["REFRESH_VOICEPRINT"] = nil
        return env
    }

    // MARK: Output handling

    private func handleLine(_ rawLine: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard case .running(let stage, _) = state else { return }
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }

        if let value = Self.value(of: "STAGE:", in: line) {
            if let next = TranscriptionStage(rawValue: value) {
                setRunning(stage: next, progress: nil)
            }
            // "done" and unknown names are not stages; both are still worth keeping in the log.
            appendLog(line)
        } else if let value = Self.value(of: "PROGRESS:", in: line) {
            if stage == .transcribe, let percent = Double(value), percent.isFinite {
                setRunning(stage: .transcribe, progress: min(max(percent, 0), 100) / 100)
            }
        } else if line.contains("%|") {
            // tqdm bars (model downloads) would push the real error out of the log tail.
            return
        } else {
            appendLog(line)
        }
    }

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    private func setRunning(stage: TranscriptionStage, progress: Double?) {
        let next = TranscriptionState.running(stage: stage, progress: progress)
        if state != next { state = next }
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > logLimit {
            logLines.removeFirst(logLines.count - logLimit)
        }
    }

    // MARK: Termination

    private func handleTermination(status: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        killWork?.cancel()
        killWork = nil
        process = nil
        let wasCancelled = cancelRequested
        cancelRequested = false
        isCancelling = false

        guard case .running = state else { return }

        if wasCancelled {
            state = .cancelled
            return
        }
        guard status == 0 else {
            var message = "Transcription failed (exit status \(status))"
            if let last = logLines.last(where: { !$0.hasPrefix("STAGE:") }) {
                message += ": \(String(last.prefix(200)))"
            }
            fail(message)
            return
        }
        finish()
    }

    private func finish() {
        guard let run else {
            fail("Internal error: no transcription run")
            return
        }
        guard let data = fileManager.contents(atPath: run.summaryURL.path) else {
            fail("Transcription finished but its summary file is missing: \(run.summaryURL.path)")
            return
        }
        let result: TranscriptionResult
        do {
            result = try TranscriptionResult.decode(
                summary: data, transcriptURL: run.transcriptURL, summaryURL: run.summaryURL)
        } catch {
            fail("Transcription finished but its summary file could not be read (\(run.summaryURL.lastPathComponent)): "
                + Self.describe(error))
            return
        }
        guard fileManager.fileExists(atPath: run.transcriptURL.path) else {
            fail("Transcription finished but the transcript file is missing: \(run.transcriptURL.path)")
            return
        }
        state = .finished(result)
    }

    private func fail(_ message: String) {
        state = .failed(message: message, logTail: recentLog)
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                return context.debugDescription
            @unknown default: break
            }
        }
        return error.localizedDescription
    }
}
