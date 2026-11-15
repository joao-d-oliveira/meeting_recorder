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

/// A one-way "stop reading" request shared between the thread that decides and the reader
/// threads that poll it. Set once, never cleared.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
    }
}

/// Wraps Foundation.Process for a long-running child (the ffmpeg recording, the
/// transcription pipeline). Delivers onStdoutLine, onStderrLine and onTermination on the
/// main queue. onTermination is delivered exactly once, after the process has exited AND every
/// output pipe has been read to EOF, so it always arrives after the last line.
///
/// The one exception is a descendant that inherited the pipes and outlives the process (a
/// shell script's `sleep`, a daemonized helper): its copy of the write end keeps the pipe from
/// ever reaching EOF. The readers get `readerGracePeriod` after the process exits; then they
/// take whatever is already in the pipe, flush any partial line, close their end and stop, and
/// onTermination follows. Later output from such a descendant is not delivered (its next write
/// fails with EPIPE/SIGPIPE instead of piling up in a pipe nobody reads).
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

    /// How long, after the process has exited, the readers get to reach EOF on their own. In
    /// the normal case EOF is already there (the process held the only write end), so this only
    /// bounds the wait when a descendant keeps a pipe open. Read once, at `start`.
    static let defaultReaderGracePeriod: TimeInterval = 1.5
    var readerGracePeriod: TimeInterval = FFmpegProcess.defaultReaderGracePeriod

    /// How often an idle reader wakes up to check whether it was told to stop. Data wakes it
    /// immediately, so this is only the worst-case extra delay of a stop.
    private static let readerTickMilliseconds: Int32 = 100
    /// A stopping reader takes what is already in its pipe, but at most this many reads, so a
    /// descendant that keeps writing cannot hold the stop open.
    private static let maxReadsAfterStop = 16

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

        // Leaves when the process exits, and once per pipe when its reader is done (EOF, or told
        // to stop).
        let finished = DispatchGroup()
        finished.enter()
        let stop = StopFlag()
        let grace = readerGracePeriod
        process.terminationHandler = { [weak self] done in
            self?.exitStatus = done.terminationStatus
            // Readers normally see EOF right away. If a descendant still holds a pipe open they
            // never will, so after the grace period tell them to stop (a no-op if they are done).
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { stop.set() }
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
        if let stderr { startReader(for: stderr, as: .stderr, in: finished, stop: stop) }
        if let stdout { startReader(for: stdout, as: .stdout, in: finished, stop: stop) }
        finished.notify(queue: .main) { [weak self] in
            guard let self else { return }
            // Pipe does not close its write end when it is released, so without this every
            // process would leak its stdin descriptor. Nothing writes to a finished process.
            try? self.stdinPipe.fileHandleForWriting.close()
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

    /// Reads `pipe` on its own thread until EOF or until `stop` is set, splitting lines (ffmpeg and
    /// tqdm use "\r" for in-place progress) and handing each to the main queue in order.
    ///
    /// The thread waits in poll(2) with a short timeout instead of a blocking read(2): closing a
    /// file descriptor from another thread does not reliably wake a blocked read on macOS, but a
    /// poll loop can notice the stop flag within one tick and then close its own descriptor, so
    /// nothing is closed under a thread that is using it.
    private func startReader(for pipe: Pipe, as stream: Stream, in group: DispatchGroup, stop: StopFlag) {
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
            let fd = handle.fileDescriptor
            // Non-blocking, so a read can never hang even if poll reported readiness spuriously.
            // read(2) rather than FileHandle.read(upToCount:), which keeps waiting on a pipe until
            // the whole count (or EOF) has arrived and would hold back live lines.
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var buffer = [UInt8](repeating: 0, count: 65536)
            var readsAfterStop = 0
            while true {
                // Sampled before polling: once stopping, poll only for what is already there, so
                // the last bytes the process wrote are taken before the reader gives up.
                let stopping = stop.isSet
                var pollState = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pollState, 1, stopping ? 0 : Self.readerTickMilliseconds)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 {
                    if stopping { break }  // nothing left to take
                    continue  // idle tick: look at the stop flag again
                }
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    for line in splitter.feed(Data(buffer[0..<count])) { deliver(line) }
                    if stopping {
                        readsAfterStop += 1
                        if readsAfterStop >= Self.maxReadsAfterStop { break }
                    }
                } else if count == 0 {
                    break  // EOF
                } else if errno != EINTR && errno != EAGAIN {
                    break  // a real error
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
