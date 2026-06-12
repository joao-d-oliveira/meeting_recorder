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
    @Published public private(set) var remoteLevelDB: Double = LevelLineParser.silenceFloorDB
    @Published public private(set) var micLevelDB: Double = LevelLineParser.silenceFloorDB

    private let makeProcess: () -> ProcessRunning
    private let fileManager: FileManager
    private let clock: () -> Date

    private var process: ProcessRunning?
    private var outputURL: URL?
    private var stderrBuffer: [String] = []
    private var levelParser = LevelLineParser()
    private var escalationWork: [DispatchWorkItem] = []

    public init(
        makeProcess: @escaping () -> ProcessRunning = { FFmpegProcess() },
        fileManager: FileManager = .default,
        clock: @escaping () -> Date = Date.init
    ) {
        self.makeProcess = makeProcess
        self.fileManager = fileManager
        self.clock = clock
    }

    public func start(ffmpegPath: String, arguments: [String], outputURL: URL) {
        switch state {
        case .recording, .stopping: return
        default: break
        }

        let proc = makeProcess()
        proc.onStderrLine = { [weak self] line in self?.handleStderr(line) }
        proc.onTermination = { [weak self] status in self?.handleTermination(status: status) }

        stderrBuffer = []
        levelParser = LevelLineParser()
        remoteLevelDB = LevelLineParser.silenceFloorDB
        micLevelDB = LevelLineParser.silenceFloorDB
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: interruptWork)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killWork)
    }

    private func handleStderr(_ line: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        stderrBuffer.append(line)
        if stderrBuffer.count > 200 {
            stderrBuffer.removeFirst(stderrBuffer.count - 200)
        }
        guard let sample = levelParser.parse(line: line) else { return }
        switch sample.source {
        case .remote: remoteLevelDB = sample.rmsDB
        case .mic: micLevelDB = sample.rmsDB
        }
    }

    private func handleTermination(status: Int32) {
        dispatchPrecondition(condition: .onQueue(.main))
        escalationWork.forEach { $0.cancel() }
        escalationWork = []
        process = nil

        switch state {
        case .stopping:
            finalize()
        case .recording:
            state = .failed(
                message: "ffmpeg exited unexpectedly (status \(status))",
                stderrTail: Array(stderrBuffer.suffix(20)))
        default:
            break
        }
    }

    private func finalize() {
        guard let url = outputURL else {
            state = .failed(message: "Internal error: no output URL", stderrTail: [])
            return
        }
        let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if fileManager.fileExists(atPath: url.path), size > 0 {
            state = .saved(url)
        } else {
            state = .failed(
                message: "Recording file is missing or empty",
                stderrTail: Array(stderrBuffer.suffix(20)))
        }
    }
}
