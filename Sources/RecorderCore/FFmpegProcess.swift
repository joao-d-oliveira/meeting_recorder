import Foundation

/// Wraps Foundation.Process for a long-running ffmpeg recording.
/// Delivers onStderrLine and onTermination on the main queue.
public final class FFmpegProcess: ProcessRunning {
    public var onStderrLine: ((String) -> Void)?
    public var onTermination: ((Int32) -> Void)?
    public var isRunning: Bool { process.isRunning }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stderrPipe = Pipe()
    private var lineBuffer = ""
    private let stderrQueue = DispatchQueue(label: "meetingrecorder.ffmpeg.stderr")

    public init() {}

    public func start(executable: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            self.stderrQueue.async { self.consumeStderr(data) }
        }

        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            let handle = self.stderrPipe.fileHandleForReading
            handle.readabilityHandler = nil
            // Drain whatever the readability handler hadn't delivered yet — on fast
            // failures the final lines carry the actual error message.
            let remaining = handle.readDataToEndOfFile()
            self.stderrQueue.async {
                self.consumeStderr(remaining)
                self.flushPartialLine()
                DispatchQueue.main.async { self.onTermination?(finished.terminationStatus) }
            }
        }

        try process.run()
    }

    public func writeStdin(_ string: String) {
        // Writing to a dead process's pipe raises SIGPIPE / NSFileHandleOperationException,
        // killing the app. Guard + throwing write (with SIGPIPE ignored at app startup)
        // turns that into a silent no-op; the pending termination callback resolves state.
        guard process.isRunning else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(string.utf8))
    }

    public func interrupt() {
        if process.isRunning { process.interrupt() } // SIGINT
    }

    public func forceKill() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Runs on stderrQueue only.
    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lineBuffer += String(decoding: data, as: UTF8.self)
        // ffmpeg uses \r for in-place progress lines and \n elsewhere; split on both.
        while let index = lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(lineBuffer[..<index])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: index)...])
            if !line.isEmpty {
                DispatchQueue.main.async { self.onStderrLine?(line) }
            }
        }
    }

    /// Runs on stderrQueue only. Emits a trailing line that lacked a terminator.
    private func flushPartialLine() {
        let line = lineBuffer
        lineBuffer = ""
        if !line.isEmpty {
            DispatchQueue.main.async { self.onStderrLine?(line) }
        }
    }
}
