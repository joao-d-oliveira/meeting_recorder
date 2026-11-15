import Foundation

public enum DeviceScanResult: Equatable {
    case devices([AudioDevice])
    /// The scan process could not be started.
    case failedToLaunch(String)
    /// The scan did not finish within its timeout and was killed.
    case timedOut
    /// Stopped through its `DeviceScanCancellation`.
    case cancelled
}

/// Lets another thread stop a scan that is running (or about to run) on a background queue.
public final class DeviceScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: (() -> Void)?

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Kills the scan process, if there is one, and makes the scan return `.cancelled`.
    public func cancel() {
        lock.lock()
        cancelled = true
        let handler = onCancel
        lock.unlock()
        handler?()
    }

    fileprivate func setHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        onCancel = handler
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { handler() }
    }
}

public enum DeviceScanner {
    /// How long a scan may take. ffmpeg lists the devices in well under a second; a scan that
    /// takes this long is stuck (a wedged audio driver), and is killed.
    public static let defaultTimeout: TimeInterval = 10

    /// After the process has exited, how long to wait for its stderr to reach EOF. EOF is
    /// normally already there; a descendant that inherited the pipe could hold it open.
    private static let pipeGracePeriod: TimeInterval = 1

    /// Lists avfoundation audio devices by running ffmpeg's device listing.
    /// ffmpeg exits nonzero after listing (it has no real input) — that is expected.
    ///
    /// Blocks the calling thread until the listing is done, `timeout` has passed, or
    /// `cancellation` fires: call it from a background queue, never from the main thread.
    public static func scan(
        ffmpegPath: String,
        timeout: TimeInterval = defaultTimeout,
        cancellation: DeviceScanCancellation? = nil
    ) -> DeviceScanResult {
        scan(
            executable: ffmpegPath,
            arguments: ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
            timeout: timeout, cancellation: cancellation)
    }

    /// Runs `executable` and parses the audio devices from what it prints on stderr, in
    /// ffmpeg's listing format. A process that has not exited after `timeout` seconds is killed.
    public static func scan(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        cancellation: DeviceScanCancellation? = nil
    ) -> DeviceScanResult {
        if cancellation?.isCancelled == true { return .cancelled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        // Output is collected as it arrives, not read to EOF in one call: a read to EOF has no
        // timeout, and would return nothing at all if the process hangs.
        let output = ScanOutput()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let reader = stderrPipe.fileHandleForReading
        reader.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {  // EOF
                handle.readabilityHandler = nil
                output.reachedEOF.signal()
            } else {
                output.append(chunk)
            }
        }

        do {
            try process.run()
        } catch {
            reader.readabilityHandler = nil
            return .failedToLaunch(error.localizedDescription)
        }

        // Cancelling kills the process right away (the caller may be about to quit) and wakes
        // the wait below.
        cancellation?.setHandler {
            if process.isRunning { process.terminate() }
            exited.signal()
        }

        let finishedInTime = exited.wait(timeout: .now() + timeout) == .success
        if cancellation?.isCancelled == true {
            reader.readabilityHandler = nil
            stop(process)
            return .cancelled
        }
        guard finishedInTime else {
            reader.readabilityHandler = nil
            stop(process)
            return .timedOut
        }

        _ = output.reachedEOF.wait(timeout: .now() + pipeGracePeriod)
        reader.readabilityHandler = nil
        return .devices(DeviceListParser.parseAudioDevices(from: String(decoding: output.data, as: UTF8.self)))
    }

    /// SIGTERM, then SIGKILL a second later if the process is still there.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}

/// The scan's stderr, filled by the pipe's readability handler (a dispatch queue of its own)
/// and read by the scanning thread.
private final class ScanOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    /// Signalled once, when the pipe reaches EOF.
    let reachedEOF = DispatchSemaphore(value: 0)

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(chunk)
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
