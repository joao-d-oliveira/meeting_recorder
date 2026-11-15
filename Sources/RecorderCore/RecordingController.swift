import Combine
import Foundation

public enum RecordingState: Equatable {
    case idle
    case recording(startedAt: Date)
    case stopping
    case saved(URL)
    case failed(message: String, stderrTail: [String])
}

public final class RecordingController: ObservableObject {
    @Published public private(set) var state: RecordingState = .idle
    /// Latest RMS level (dB) of each recorded input, indexed like the `inputs` passed to
    /// `CommandBuilder.arguments`. Empty before the first recording; reset to the silence
    /// floor whenever a recording starts.
    @Published public private(set) var levelsDB: [Double] = []

    private let makeProcess: () -> ProcessRunning
    private let fileManager: FileManager
    private let clock: () -> Date
    private let interruptAfter: TimeInterval
    private let killAfter: TimeInterval

    private var process: ProcessRunning?
    private var outputURL: URL?
    private var stderrBuffer: [String] = []
    private var levelParser = LevelLineParser(inputCount: 0)
    private var escalationWork: [DispatchWorkItem] = []
    /// Latest unpublished level per input; applied together once the shared window allows.
    private var pendingLevels: [Int: Double] = [:]
    private var lastLevelPublish: Date?
    /// ffmpeg emits ~50-100 level lines/sec per input, and every @Published write invalidates
    /// the whole SwiftUI view tree, so all inputs share one ~10 Hz publish window.
    private static let levelPublishInterval: TimeInterval = 0.1

    public init(
        makeProcess: @escaping () -> ProcessRunning = { FFmpegProcess() },
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init,
        interruptAfter: TimeInterval = 5,
        killAfter: TimeInterval = 10
    ) {
        self.makeProcess = makeProcess
        self.fileManager = fileManager
        self.clock = clock
        self.interruptAfter = interruptAfter
        self.killAfter = killAfter
    }

    /// `inputCount` is the number of inputs in `arguments`; it sizes `levelsDB` and bounds
    /// which ffmpeg level lines are accepted.
    public func start(ffmpegPath: String, arguments: [String], outputURL: URL, inputCount: Int) {
        switch state {
        case .recording, .stopping: return
        default: break
        }

        let proc = makeProcess()
        proc.onStderrLine = { [weak self] line in self?.handleStderr(line) }
        proc.onTermination = { [weak self] status in self?.handleTermination(status: status) }

        stderrBuffer = []
        levelParser = LevelLineParser(inputCount: inputCount)
        pendingLevels = [:]
        lastLevelPublish = nil
        levelsDB = Array(repeating: LevelLineParser.silenceFloorDB, count: max(0, inputCount))
        self.outputURL = outputURL
        self.process = proc

        do {
            try proc.start(executable: ffmpegPath, arguments: arguments)
            state = .recording(startedAt: clock())
        } catch {
            state = .failed(message: "Could not launch ffmpeg: \(error.localizedDescription)", stderrTail: [])
            process = nil
        }
    }

    public func stop() {
        guard case .recording = state, let proc = process else { return }
        state = .stopping
        proc.writeStdin("q")

        // Strong captures: if the controller deallocates mid-stop, escalation still
        // terminates the orphaned ffmpeg; clean exits cancel these work items anyway.
        let interruptWork = DispatchWorkItem { proc.interrupt() }
        let killWork = DispatchWorkItem { proc.forceKill() }
        escalationWork = [interruptWork, killWork]
        DispatchQueue.global().asyncAfter(deadline: .now() + interruptAfter, execute: interruptWork)
        DispatchQueue.global().asyncAfter(deadline: .now() + killAfter, execute: killWork)
    }

    private func handleStderr(_ line: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let sample = levelParser.parse(line: line), levelsDB.indices.contains(sample.inputIndex) {
            // Meter chatter never enters stderrBuffer: it would push real errors out of the
            // 20-line failure tail within a fraction of a second.
            pendingLevels[sample.inputIndex] = sample.rmsDB     // latest value per input wins
            publishPendingLevels(force: false)
            return
        }
        if levelParser.isMeterHeader(line: line) { return }

        stderrBuffer.append(line)
        if stderrBuffer.count > 200 {
            stderrBuffer.removeFirst(stderrBuffer.count - 200)
        }
    }

    /// Applies every pending level in one assignment (one view invalidation). Unless forced,
    /// that happens at most once per window; levels that arrive inside the window wait for
    /// the next level line after it (ffmpeg sends them continuously) or for the process exit.
    private func publishPendingLevels(force: Bool) {
        guard !pendingLevels.isEmpty else { return }
        let now = clock()
        if !force, let last = lastLevelPublish,
           now.timeIntervalSince(last) < Self.levelPublishInterval { return }
        var updated = levelsDB
        for (index, level) in pendingLevels where updated.indices.contains(index) {
            updated[index] = level
        }
        pendingLevels = [:]
        lastLevelPublish = now
        levelsDB = updated
    }

    private func handleTermination(status: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        escalationWork.forEach { $0.cancel() }
        escalationWork = []
        process = nil
        publishPendingLevels(force: true)

        switch state {
        case .stopping:
            finalize(exitStatus: status)
        case .recording:
            state = .failed(
                message: "ffmpeg exited unexpectedly (status \(status))",
                stderrTail: Array(stderrBuffer.suffix(20)))
        default:
            break
        }
    }

    private func finalize(exitStatus: Int32) {
        guard let url = outputURL else {
            state = .failed(message: "Internal error: no output URL", stderrTail: [])
            return
        }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard fileManager.fileExists(atPath: url.path), size > 0 else {
            state = .failed(
                message: "Recording file is missing or empty",
                stderrTail: Array(stderrBuffer.suffix(20)))
            return
        }
        // A clean 'q' stop exits 0. Non-zero here means ffmpeg was signalled (SIGINT -> 255,
        // SIGKILL -> 9) and the container trailer may not have been written.
        guard exitStatus == 0 else {
            state = .failed(
                message: "ffmpeg didn't stop cleanly (status \(exitStatus)); "
                    + "the partial file may be incomplete: \(url.path)",
                stderrTail: Array(stderrBuffer.suffix(20)))
            return
        }
        state = .saved(url)
    }
}
