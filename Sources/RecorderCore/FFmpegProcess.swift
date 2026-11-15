import Foundation

/// Splits a byte stream into lines on "\n" and "\r" (ffmpeg and tqdm both use "\r" for
/// in-place progress lines). Empty segments are skipped, so "\r\n" yields no blank line.
/// Works on bytes, so a multi-byte UTF-8 character split across reads stays intact.
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        pending.append(data)
        var lines: [String] = []
        var lineStart = pending.startIndex
        var index = lineStart
        while index < pending.endIndex {
            let byte = pending[index]
            if byte == 0x0A || byte == 0x0D {
                if index > lineStart {
                    lines.append(String(decoding: pending[lineStart..<index], as: UTF8.self))
                }
                lineStart = pending.index(after: index)
            }
            index = pending.index(after: index)
        }
        pending = Data(pending[lineStart...])
        return lines
    }

    /// The trailing line that lacked a terminator, if any.
    mutating func flush() -> String? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }
}

/// Wraps Foundation.Process for a long-running child (the ffmpeg recording, the
/// transcription pipeline). Delivers onStdoutLine, onStderrLine and onTermination on the
/// main queue. onTermination is delivered once the process has exited AND every output pipe
/// has been read to EOF, so it always arrives after the last line.
public final class FFmpegProcess: ProcessRunning {
    /// stdout is only captured when this is set before `start`; otherwise it goes to /dev/null.
    public var onStdoutLine: ((String) -> Void)?
    public var onStderrLine: ((String) -> Void)?
    public var onTermination: ((Int32) -> Void)?
    public var isRunning: Bool { process.isRunning }
    /// When true, `forceKill` also SIGKILLs everything the process has spawned (a shell script
    /// whose children would otherwise be orphaned and keep running). Off by default.
    public var killsDescendants = false
    /// When true (and `onStdoutLine` is set), stderr is written to the same pipe as stdout, so
    /// every line arrives through `onStdoutLine` in exactly the order it was written and
    /// `onStderrLine` is never called. Separate pipes are read concurrently, so lines written
    /// close together on the two streams can otherwise be delivered out of order.
    public var mergesStderrIntoStdout = false

    private enum Stream { case stdout, stderr }

    private let process = Process()
    private let stdinPipe = Pipe()
    private var exitStatus: Int32 = 0  // written by the termination handler before the group leaves
    private let readerQueue = DispatchQueue(label: "meetingrecorder.process.reader", attributes: .concurrent)

    public init() {}

    public func start(executable: String, arguments: [String]) throws {
        try start(executable: executable, arguments: arguments, environment: nil, currentDirectory: nil)
    }

    public func start(
        executable: String, arguments: [String],
        environment: [String: String]?, currentDirectory: String?
    ) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        process.standardInput = stdinPipe
        let stdout: Pipe? = onStdoutLine == nil ? nil : Pipe()
        // A pipe that is not handed to the child would keep its write end open in this process,
        // and reading it to EOF would then never finish. So only create what is attached.
        let stderr: Pipe? = (mergesStderrIntoStdout && stdout != nil) ? nil : Pipe()
        process.standardOutput = stdout ?? FileHandle.nullDevice
        process.standardError = stderr ?? stdout!

        // Leaves when the process exits, and once per pipe when its reader reaches EOF.
        let finished = DispatchGroup()
        finished.enter()
        process.terminationHandler = { [weak self] done in
            self?.exitStatus = done.terminationStatus
            finished.leave()
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }

        // Readers start after a successful launch: a failed launch leaves nothing to read, and a
        // blocked reader would never see EOF. Output written meanwhile waits in the pipe.
        if let stderr { startReader(for: stderr, as: .stderr, in: finished) }
        if let stdout { startReader(for: stdout, as: .stdout, in: finished) }
        finished.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.onTermination?(self.exitStatus)
        }
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
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if killsDescendants {
            for child in Self.descendants(of: pid) { kill(child, SIGKILL) }
        }
        kill(pid, SIGKILL)
    }

    /// Reads `pipe` until EOF on its own thread, splitting lines (ffmpeg and tqdm use "\r" for
    /// in-place progress) and handing each to the main queue in order.
    private func startReader(for pipe: Pipe, as stream: Stream, in group: DispatchGroup) {
        group.enter()
        let handle = pipe.fileHandleForReading
        readerQueue.async { [weak self] in
            var splitter = LineSplitter()
            func deliver(_ line: String) {
                DispatchQueue.main.async {
                    switch stream {
                    case .stdout: self?.onStdoutLine?(line)
                    case .stderr: self?.onStderrLine?(line)
                    }
                }
            }
            // read(2) directly: FileHandle.read(upToCount:) keeps waiting on a pipe until the
            // whole count (or EOF) has arrived, which would hold back live lines.
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    for line in splitter.feed(Data(buffer[0..<count])) { deliver(line) }
                } else if count == 0 || errno != EINTR {
                    break  // EOF or a real error
                }
            }
            if let rest = splitter.flush() { deliver(rest) }
            try? handle.close()
            group.leave()
        }
    }

    // MARK: Process tree

    private static func descendants(of pid: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var frontier = [pid]
        while let next = frontier.popLast() {
            let children = childPIDs(of: next)
            found += children
            frontier += children
        }
        return found
    }

    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let output = Pipe()
        pgrep.standardOutput = output
        pgrep.standardError = FileHandle.nullDevice
        pgrep.standardInput = FileHandle.nullDevice
        do { try pgrep.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }
}
