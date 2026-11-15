import Foundation
import RecorderCore

/// Runs `body` with a fake "ffmpeg" (a shell script made of `script`) in a temp folder that
/// also holds the device listing fixture; `$LISTING` and `$PIDFILE` are set for the script.
/// The folder is removed afterwards.
private func withScanScript(
    _ script: String, listing: String = deviceListFixture,
    _ body: (_ executable: String, _ folder: URL) throws -> Void
) throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("scanner-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let listingFile = folder.appendingPathComponent("listing.txt")
    try listing.write(to: listingFile, atomically: true, encoding: .utf8)
    let executable = folder.appendingPathComponent("fake-ffmpeg")
    let text = "#!/bin/sh\nLISTING='\(listingFile.path)'\nPIDFILE='\(folder.path)/pid'\n" + script + "\n"
    try text.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    try body(executable.path, folder)
}

private let expectedFixtureDevices = [
    AudioDevice(index: 0, name: "BlackHole 2ch"),
    AudioDevice(index: 1, name: "MacBook Air Microphone"),
    AudioDevice(index: 2, name: "Microsoft Teams Audio"),
    AudioDevice(index: 3, name: "BlackHole 16ch"),
]

private func isProcessAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
}

/// The pid the fake scanner wrote, waiting up to `seconds` for it to appear (a loaded machine
/// can take a while to start a shell). Nil if it never did.
private func fakeScannerPID(_ pidFile: URL, within seconds: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return nil
}

/// True once the fake scanner's process is gone (polls: it is reaped a moment after the kill).
/// A scanner that was killed before it wrote its pid counts as gone.
private func fakeScannerIsGone(pidFile: URL, within seconds: TimeInterval) -> Bool {
    guard let pid = fakeScannerPID(pidFile, within: 3) else { return true }
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if !isProcessAlive(pid) { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return !isProcessAlive(pid)
}

func runDeviceScannerTests() {
    test("scan parses the devices an executable lists on stderr, whatever its exit status") {
        try withScanScript("cat \"$LISTING\" >&2\nexit 1") { executable, _ in
            let result = DeviceScanner.scan(
                executable: executable, arguments: [], timeout: 10)
            try expectEqual(result, .devices(expectedFixtureDevices))
        }
    }

    test("scan(ffmpegPath:) asks ffmpeg for the avfoundation device listing") {
        // The fake only prints the listing when it gets exactly the arguments ffmpeg needs.
        let script = "if [ \"$*\" = \"-hide_banner -f avfoundation -list_devices true -i \" ]; then cat \"$LISTING\" >&2; fi\nexit 1"
        try withScanScript(script) { executable, _ in
            try expectEqual(
                DeviceScanner.scan(ffmpegPath: executable), .devices(expectedFixtureDevices))
        }
    }

    test("scan reports an executable that cannot be launched") {
        let result = DeviceScanner.scan(
            executable: "/nonexistent/ffmpeg", arguments: [], timeout: 10)
        guard case .failedToLaunch = result else {
            throw TestFailure(description: "expected failedToLaunch, got \(result)")
        }
    }

    test("scan kills a process that does not finish within the timeout") {
        try withScanScript("echo $$ > \"$PIDFILE\"\nexec sleep 30") { executable, folder in
            let started = Date()
            let result = DeviceScanner.scan(executable: executable, arguments: [], timeout: 1)
            try expectEqual(result, .timedOut)
            try expect(Date().timeIntervalSince(started) < 5, "the scan did not give up at its timeout")
            try expect(
                fakeScannerIsGone(pidFile: folder.appendingPathComponent("pid"), within: 5),
                "the stalled scan process is still running")
        }
    }

    test("scan returns what was listed when a descendant keeps stderr open after the exit") {
        // `sleep 3 &` inherits the pipe, so it never reaches EOF while that sleep lives.
        try withScanScript("cat \"$LISTING\" >&2\nsleep 3 &\nexit 1") { executable, _ in
            let started = Date()
            let result = DeviceScanner.scan(executable: executable, arguments: [], timeout: 10)
            try expectEqual(result, .devices(expectedFixtureDevices))
            try expect(Date().timeIntervalSince(started) < 2.5, "waited for the descendant's pipe")
        }
    }

    test("a cancelled scan kills its process and returns right away") {
        try withScanScript("echo $$ > \"$PIDFILE\"\nexec sleep 30") { executable, folder in
            let cancellation = DeviceScanCancellation()
            let pidFile = folder.appendingPathComponent("pid")
            // Cancel once the process is really running (its pid is written).
            DispatchQueue.global().async {
                _ = fakeScannerPID(pidFile, within: 5)
                cancellation.cancel()
            }
            let started = Date()
            let result = DeviceScanner.scan(
                executable: executable, arguments: [], timeout: 20, cancellation: cancellation)
            try expectEqual(result, .cancelled)
            try expect(Date().timeIntervalSince(started) < 8, "cancel did not wake the scan")
            try expect(
                fakeScannerIsGone(pidFile: pidFile, within: 5),
                "the cancelled scan process is still running")
        }
    }

    test("a scan cancelled before it starts never launches the process") {
        try withScanScript("echo $$ > \"$PIDFILE\"\nexit 1") { executable, folder in
            let cancellation = DeviceScanCancellation()
            cancellation.cancel()
            let result = DeviceScanner.scan(
                executable: executable, arguments: [], timeout: 10, cancellation: cancellation)
            try expectEqual(result, .cancelled)
            try expect(
                !FileManager.default.fileExists(atPath: folder.appendingPathComponent("pid").path),
                "the process was launched")
        }
    }
}
