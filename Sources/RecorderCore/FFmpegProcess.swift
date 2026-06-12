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
            self.lineBuffer += String(decoding: data, as: UTF8.self)
            // ffmpeg uses \r for in-place progress lines and \n elsewhere; split on both.
            while let index = self.lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let line = String(self.lineBuffer[..<index])
                self.lineBuffer = String(self.lineBuffer[self.lineBuffer.index(after: index)...])
                if !line.isEmpty {
                    DispatchQueue.main.async { self.onStderrLine?(line) }
                }
            }
        }

        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.stderrPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self.onTermination?(finished.terminationStatus) }
        }

        try process.run()
    }

    public func writeStdin(_ string: String) {
        stdinPipe.fileHandleForWriting.write(Data(string.utf8))
    }

    public func interrupt() {
        if process.isRunning { process.interrupt() } // SIGINT
    }

    public func forceKill() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
