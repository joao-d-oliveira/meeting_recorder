# Meeting Recorder MVP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native SwiftUI macOS app that records meeting audio by mixing a remote/system source (e.g. BlackHole 2ch) with a microphone via an ffmpeg subprocess, per the design spec at `docs/superpowers/specs/2026-06-12-meeting-recorder-design.md`.

**Architecture:** Swift Package with three targets: `RecorderCore` (library — all logic, no UI), `MeetingRecorder` (SwiftUI executable), `RecorderCoreTests` (executable test runner). Devices are stored by name and resolved to avfoundation indices at record time by parsing ffmpeg's own device listing. A pure `CommandBuilder` generates the ffmpeg arguments; `RecordingController` owns the subprocess lifecycle and parses live RMS levels from stderr.

**Tech Stack:** Swift 6.3 toolchain (Command Line Tools only — **no Xcode, no XCTest**; tests run via a tiny hand-rolled harness as `swift run RecorderCoreTests`), SwiftUI, Foundation `Process`, ffmpeg 8.x from Homebrew (`/opt/homebrew/bin/ffmpeg`).

**Environment facts (verified 2026-06-12):**
- `swift --version` → Apple Swift 6.3.2, arm64-apple-macosx26.0
- No `/Applications/Xcode*.app`; `xcodebuild` unavailable. Do NOT plan around XCTest or Swift Testing — neither module exists with CLT.
- ffmpeg 8.1.1 at `/opt/homebrew/bin/ffmpeg`
- Current audio devices: `[0] BlackHole 2ch`, `[1] MacBook Air Microphone`, `[2] Microsoft Teams Audio`, `[3] BlackHole 16ch`

---

### Task 1: Package scaffolding + test harness

**Files:**
- Create: `Package.swift`
- Create: `.gitignore`
- Create: `Sources/RecorderCore/AudioDevice.swift`
- Create: `Sources/MeetingRecorder/main.swift` (placeholder, replaced in Task 11)
- Create: `Sources/RecorderCoreTests/Harness.swift`
- Create: `Sources/RecorderCoreTests/main.swift`

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RecorderCore"),
        .executableTarget(name: "MeetingRecorder", dependencies: ["RecorderCore"]),
        .executableTarget(name: "RecorderCoreTests", dependencies: ["RecorderCore"]),
    ]
)
```

Note: `RecorderCoreTests` is an **executable target**, not a `.testTarget` — XCTest is unavailable with Command Line Tools.

- [ ] **Step 2: Create `.gitignore`**

```gitignore
.build/
build/
.swiftpm/
.DS_Store
```

- [ ] **Step 3: Create `Sources/RecorderCore/AudioDevice.swift`**

```swift
public struct AudioDevice: Equatable, Identifiable {
    public let index: Int
    public let name: String
    public var id: String { name }

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}
```

- [ ] **Step 4: Create placeholder `Sources/MeetingRecorder/main.swift`**

```swift
// Placeholder so the package builds; replaced by the SwiftUI app in Task 11.
print("MeetingRecorder placeholder")
```

- [ ] **Step 5: Create `Sources/RecorderCoreTests/Harness.swift`**

```swift
import Foundation

final class TestRunner {
    static let shared = TestRunner()
    private(set) var passed = 0
    private(set) var failed = 0

    func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func test(_ name: String, _ body: () throws -> Void) {
    TestRunner.shared.test(name, body)
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
            file: String = #file, line: Int = #line) throws {
    if !condition {
        throw TestFailure(description: "\(message()) (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               file: String = #file, line: Int = #line) throws {
    if actual != expected {
        throw TestFailure(description: "expected \(expected), got \(actual) (\(file):\(line))")
    }
}
```

- [ ] **Step 6: Create `Sources/RecorderCoreTests/main.swift` with a smoke test**

```swift
import Foundation
import RecorderCore

test("harness smoke test") {
    try expectEqual(AudioDevice(index: 0, name: "BlackHole 2ch").id, "BlackHole 2ch")
}

TestRunner.shared.finish()
```

- [ ] **Step 7: Run tests**

Run: `swift run RecorderCoreTests`
Expected: `PASS harness smoke test` then `1 passed, 0 failed`, exit code 0.

- [ ] **Step 8: Commit**

```bash
git add Package.swift .gitignore Sources
git commit -m "feat: scaffold Swift package with RecorderCore, app target, and test harness"
```

---

### Task 2: DeviceListParser

**Files:**
- Create: `Sources/RecorderCore/DeviceListParser.swift`
- Create: `Sources/RecorderCoreTests/DeviceListParserTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

- [ ] **Step 1: Write failing tests in `Sources/RecorderCoreTests/DeviceListParserTests.swift`**

The fixture is real output captured from `ffmpeg -hide_banner -f avfoundation -list_devices true -i ""` on this machine (ffmpeg 8.1.1):

```swift
import Foundation
import RecorderCore

let deviceListFixture = """
[AVFoundation indev @ 0x9f6c20140] AVFoundation video devices:
[AVFoundation indev @ 0x9f6c20140] [0] FaceTime HD Camera
[AVFoundation indev @ 0x9f6c20140] AVFoundation audio devices:
[AVFoundation indev @ 0x9f6c20140] [0] BlackHole 2ch
[AVFoundation indev @ 0x9f6c20140] [1] MacBook Air Microphone
[AVFoundation indev @ 0x9f6c20140] [2] Microsoft Teams Audio
[AVFoundation indev @ 0x9f6c20140] [3] BlackHole 16ch
[in#0 @ 0x9f6c20000] Error opening input: Input/output error
Error opening input file .
Error opening input files: Input/output error
"""

func runDeviceListParserTests() {
    test("parses audio devices with indices and names") {
        let devices = DeviceListParser.parseAudioDevices(from: deviceListFixture)
        try expectEqual(devices, [
            AudioDevice(index: 0, name: "BlackHole 2ch"),
            AudioDevice(index: 1, name: "MacBook Air Microphone"),
            AudioDevice(index: 2, name: "Microsoft Teams Audio"),
            AudioDevice(index: 3, name: "BlackHole 16ch"),
        ])
    }

    test("ignores video devices") {
        let devices = DeviceListParser.parseAudioDevices(from: deviceListFixture)
        try expect(!devices.contains { $0.name.contains("FaceTime") }, "video device leaked into audio list")
    }

    test("returns empty for output with no audio section") {
        try expectEqual(DeviceListParser.parseAudioDevices(from: "garbage\nmore garbage"), [])
    }
}
```

- [ ] **Step 2: Register in `Sources/RecorderCoreTests/main.swift`** (insert before `TestRunner.shared.finish()`)

```swift
runDeviceListParserTests()
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift run RecorderCoreTests`
Expected: compile error — `DeviceListParser` not defined. That counts as the failing state.

- [ ] **Step 4: Implement `Sources/RecorderCore/DeviceListParser.swift`**

```swift
import Foundation

public enum DeviceListParser {
    private static let deviceRegex = try! NSRegularExpression(pattern: #"\] \[(\d+)\] (.+)$"#)

    public static func parseAudioDevices(from stderr: String) -> [AudioDevice] {
        var inAudioSection = false
        var devices: [AudioDevice] = []
        for rawLine in stderr.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.contains("AVFoundation audio devices:") { inAudioSection = true; continue }
            if line.contains("AVFoundation video devices:") { inAudioSection = false; continue }
            guard inAudioSection, line.contains("AVFoundation indev") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = deviceRegex.firstMatch(in: line, range: range),
                  let indexRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line),
                  let index = Int(line[indexRange]) else { continue }
            devices.append(AudioDevice(index: index, name: String(line[nameRange])))
        }
        return devices
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 4 passed (incl. smoke test), 0 failed.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "feat: parse avfoundation audio device list from ffmpeg stderr"
```

---

### Task 3: FFmpegLocator

**Files:**
- Create: `Sources/RecorderCore/FFmpegLocator.swift`
- Create: `Sources/RecorderCoreTests/FFmpegLocatorTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

- [ ] **Step 1: Write failing tests in `Sources/RecorderCoreTests/FFmpegLocatorTests.swift`**

```swift
import Foundation
import RecorderCore

func runFFmpegLocatorTests() {
    test("prefers explicit override when it exists") {
        let locator = FFmpegLocator(fileExists: { $0 == "/custom/ffmpeg" }, pathVariable: nil)
        try expectEqual(locator.locate(override: "/custom/ffmpeg"), "/custom/ffmpeg")
    }

    test("ignores override that does not exist, falls back to homebrew path") {
        let locator = FFmpegLocator(
            fileExists: { $0 == "/opt/homebrew/bin/ffmpeg" }, pathVariable: nil)
        try expectEqual(locator.locate(override: "/missing/ffmpeg"), "/opt/homebrew/bin/ffmpeg")
    }

    test("falls back to /usr/local/bin") {
        let locator = FFmpegLocator(
            fileExists: { $0 == "/usr/local/bin/ffmpeg" }, pathVariable: nil)
        try expectEqual(locator.locate(), "/usr/local/bin/ffmpeg")
    }

    test("searches PATH directories last") {
        let locator = FFmpegLocator(
            fileExists: { $0 == "/weird/place/ffmpeg" },
            pathVariable: "/usr/bin:/weird/place")
        try expectEqual(locator.locate(), "/weird/place/ffmpeg")
    }

    test("returns nil when nothing found") {
        let locator = FFmpegLocator(fileExists: { _ in false }, pathVariable: "/usr/bin")
        try expectEqual(locator.locate(), nil)
    }
}
```

- [ ] **Step 2: Register `runFFmpegLocatorTests()` in `main.swift`** (before `finish()`)

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift run RecorderCoreTests`
Expected: compile error — `FFmpegLocator` not defined.

- [ ] **Step 4: Implement `Sources/RecorderCore/FFmpegLocator.swift`**

```swift
import Foundation

public struct FFmpegLocator {
    private let fileExists: (String) -> Bool
    private let pathVariable: String?

    public init(
        fileExists: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        pathVariable: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.fileExists = fileExists
        self.pathVariable = pathVariable
    }

    public func locate(override: String? = nil) -> String? {
        if let override, !override.isEmpty, fileExists(override) { return override }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where fileExists(candidate) {
            return candidate
        }
        for dir in (pathVariable ?? "").split(separator: ":") {
            let candidate = "\(dir)/ffmpeg"
            if fileExists(candidate) { return candidate }
        }
        return nil
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 9 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "feat: locate ffmpeg binary via override, homebrew paths, then PATH"
```

---

### Task 4: RecordingSettings, AudioFormat, OutputLocation

**Files:**
- Create: `Sources/RecorderCore/RecordingSettings.swift`
- Create: `Sources/RecorderCore/OutputLocation.swift`
- Create: `Sources/RecorderCoreTests/OutputLocationTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

- [ ] **Step 1: Create `Sources/RecorderCore/RecordingSettings.swift`** (plain model — no test needed beyond its use everywhere else)

```swift
import Foundation

public enum AudioFormat: String, Codable, CaseIterable, Identifiable {
    case flac, wav, mp3, m4a
    public var id: String { rawValue }

    /// ffmpeg codec arguments for this container.
    public var codecArguments: [String] {
        switch self {
        case .flac: return ["-c:a", "flac"]
        case .wav: return ["-c:a", "pcm_s16le"]
        case .mp3: return ["-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-c:a", "aac", "-b:a", "192k"]
        }
    }
}

public struct RecordingSettings: Codable, Equatable {
    public var remoteDeviceName: String?
    public var micDeviceName: String?
    public var remoteVolume: Double
    public var micVolume: Double
    public var format: AudioFormat
    public var outputFolder: URL
    public var filenamePrefix: String
    public var folderPerRecording: Bool
    public var ffmpegPathOverride: String?

    public init(
        remoteDeviceName: String? = nil,
        micDeviceName: String? = nil,
        remoteVolume: Double = 0.55,
        micVolume: Double = 1.0,
        format: AudioFormat = .flac,
        outputFolder: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Recordings/meetings", isDirectory: true),
        filenamePrefix: String = "meeting",
        folderPerRecording: Bool = true,
        ffmpegPathOverride: String? = nil
    ) {
        self.remoteDeviceName = remoteDeviceName
        self.micDeviceName = micDeviceName
        self.remoteVolume = remoteVolume
        self.micVolume = micVolume
        self.format = format
        self.outputFolder = outputFolder
        self.filenamePrefix = filenamePrefix
        self.folderPerRecording = folderPerRecording
        self.ffmpegPathOverride = ffmpegPathOverride
    }
}
```

- [ ] **Step 2: Write failing tests in `Sources/RecorderCoreTests/OutputLocationTests.swift`**

```swift
import Foundation
import RecorderCore

func runOutputLocationTests() {
    // 2026-06-12 14:30:05 UTC, fixed for determinism
    let fixedDate = Date(timeIntervalSince1970: 1781274605)
    var calendarSettings = RecordingSettings(outputFolder: URL(fileURLWithPath: "/tmp/rec"))

    test("builds session folder per recording with timestamp") {
        calendarSettings.folderPerRecording = true
        let url = OutputLocation.makeURL(settings: calendarSettings, date: fixedDate,
                                         timeZone: TimeZone(identifier: "UTC")!,
                                         fileExists: { _ in false })
        try expectEqual(url.path, "/tmp/rec/2026-06-12_14-30-05/meeting.flac")
    }

    test("writes directly into output folder when folderPerRecording is off") {
        calendarSettings.folderPerRecording = false
        let url = OutputLocation.makeURL(settings: calendarSettings, date: fixedDate,
                                         timeZone: TimeZone(identifier: "UTC")!,
                                         fileExists: { _ in false })
        try expectEqual(url.path, "/tmp/rec/meeting.flac")
    }

    test("uses format extension") {
        calendarSettings.folderPerRecording = false
        calendarSettings.format = .m4a
        let url = OutputLocation.makeURL(settings: calendarSettings, date: fixedDate,
                                         timeZone: TimeZone(identifier: "UTC")!,
                                         fileExists: { _ in false })
        try expectEqual(url.lastPathComponent, "meeting.m4a")
        calendarSettings.format = .flac
    }

    test("appends -2, -3 to avoid overwriting existing files") {
        calendarSettings.folderPerRecording = false
        let existing = Set(["/tmp/rec/meeting.flac", "/tmp/rec/meeting-2.flac"])
        let url = OutputLocation.makeURL(settings: calendarSettings, date: fixedDate,
                                         timeZone: TimeZone(identifier: "UTC")!,
                                         fileExists: { existing.contains($0) })
        try expectEqual(url.lastPathComponent, "meeting-3.flac")
    }
}
```

- [ ] **Step 3: Register `runOutputLocationTests()` in `main.swift`, run, verify compile failure** (`OutputLocation` not defined)

- [ ] **Step 4: Implement `Sources/RecorderCore/OutputLocation.swift`**

```swift
import Foundation

public enum OutputLocation {
    public static func makeURL(
        settings: RecordingSettings,
        date: Date,
        timeZone: TimeZone = .current,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        var directory = settings.outputFolder
        if settings.folderPerRecording {
            directory = directory.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        }

        let ext = settings.format.rawValue
        var candidate = directory.appendingPathComponent("\(settings.filenamePrefix).\(ext)")
        var counter = 2
        while fileExists(candidate.path) {
            candidate = directory.appendingPathComponent("\(settings.filenamePrefix)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 13 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "feat: recording settings model and collision-safe output path builder"
```

---

### Task 5: SettingsStore

**Files:**
- Create: `Sources/RecorderCore/SettingsStore.swift`
- Create: `Sources/RecorderCoreTests/SettingsStoreTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

- [ ] **Step 1: Write failing tests in `Sources/RecorderCoreTests/SettingsStoreTests.swift`**

```swift
import Foundation
import RecorderCore

func runSettingsStoreTests() {
    let suiteName = "MeetingRecorderTests"

    func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    test("load returns defaults when nothing saved") {
        let store = SettingsStore(defaults: freshDefaults())
        let settings = store.load()
        try expectEqual(settings.remoteVolume, 0.55)
        try expectEqual(settings.micVolume, 1.0)
        try expectEqual(settings.format, .flac)
        try expectEqual(settings.remoteDeviceName, nil)
    }

    test("save then load round-trips all fields") {
        let store = SettingsStore(defaults: freshDefaults())
        var settings = RecordingSettings()
        settings.remoteDeviceName = "BlackHole 2ch"
        settings.micDeviceName = "MacBook Air Microphone"
        settings.remoteVolume = 0.7
        settings.micVolume = 0.9
        settings.format = .m4a
        settings.outputFolder = URL(fileURLWithPath: "/tmp/elsewhere")
        settings.filenamePrefix = "standup"
        settings.folderPerRecording = false
        settings.ffmpegPathOverride = "/custom/ffmpeg"
        store.save(settings)
        try expectEqual(store.load(), settings)
    }

    test("corrupt stored data falls back to defaults") {
        let defaults = freshDefaults()
        defaults.set(Data("not json".utf8), forKey: "settings.v1")
        let store = SettingsStore(defaults: defaults)
        try expectEqual(store.load(), RecordingSettings())
    }
}
```

- [ ] **Step 2: Register `runSettingsStoreTests()` in `main.swift`, run, verify compile failure**

- [ ] **Step 3: Implement `Sources/RecorderCore/SettingsStore.swift`**

```swift
import Foundation

public final class SettingsStore {
    private static let key = "settings.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(_ settings: RecordingSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func load() -> RecordingSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(RecordingSettings.self, from: data)
        else { return RecordingSettings() }
        return settings
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 16 passed, 0 failed.

Note: `RecordingSettings` compares `outputFolder` as `URL`; JSON round-trip preserves file URLs. If the round-trip test fails on URL equality (e.g. trailing-slash normalization), compare `.path` fields instead — adjust the test, not the model.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: persist settings as JSON in UserDefaults"
```

---

### Task 6: CommandBuilder

**Files:**
- Create: `Sources/RecorderCore/CommandBuilder.swift`
- Create: `Sources/RecorderCoreTests/CommandBuilderTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

The generated command mirrors the user's proven pipeline, plus `astats`/`ametadata` on each input branch for live level metering. Filter instance numbering (used by the level parser): ffmpeg numbers parsed filters by position in the filtergraph spec. Remote branch declares `aresample(0), aformat(1), volume(2), astats(3), ametadata(4)`; mic branch `aresample(5), aformat(6), volume(7), astats(8), ametadata(9)`. So remote levels arrive tagged `Parsed_ametadata_4`, mic `Parsed_ametadata_9`. These constants live in `CommandBuilder` so builder and parser cannot drift. (Task 12 validates them against the real ffmpeg.)

- [ ] **Step 1: Write failing tests in `Sources/RecorderCoreTests/CommandBuilderTests.swift`**

```swift
import Foundation
import RecorderCore

func runCommandBuilderTests() {
    let expectedGraph = "[0:a]aresample=48000,aformat=channel_layouts=mono,volume=0.55,"
        + "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[remote];"
        + "[1:a]aresample=48000,aformat=channel_layouts=mono,volume=1.00,"
        + "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[mic];"
        + "[remote][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,"
        + "alimiter=limit=0.95[mixed]"

    test("builds full default flac command") {
        let args = CommandBuilder.arguments(
            remoteIndex: 0, micIndex: 1,
            settings: RecordingSettings(),
            outputURL: URL(fileURLWithPath: "/tmp/out/meeting.flac"))
        try expectEqual(args, [
            "-hide_banner", "-nostats",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":0",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":1",
            "-filter_complex", expectedGraph,
            "-map", "[mixed]",
            "-c:a", "flac",
            "-n",
            "/tmp/out/meeting.flac",
        ])
    }

    test("applies custom volumes with two decimals") {
        var settings = RecordingSettings()
        settings.remoteVolume = 0.8
        settings.micVolume = 1.25
        let args = CommandBuilder.arguments(
            remoteIndex: 0, micIndex: 1, settings: settings,
            outputURL: URL(fileURLWithPath: "/tmp/x.flac"))
        let graph = args[args.firstIndex(of: "-filter_complex")! + 1]
        try expect(graph.contains("volume=0.80"), "remote volume missing: \(graph)")
        try expect(graph.contains("volume=1.25"), "mic volume missing: \(graph)")
    }

    test("uses selected device indices") {
        let args = CommandBuilder.arguments(
            remoteIndex: 2, micIndex: 3, settings: RecordingSettings(),
            outputURL: URL(fileURLWithPath: "/tmp/x.flac"))
        let inputs = args.indices.filter { args[$0] == "-i" }.map { args[$0 + 1] }
        try expectEqual(inputs, [":2", ":3"])
    }

    test("maps formats to codec args") {
        for (format, expected) in [
            (AudioFormat.flac, ["-c:a", "flac"]),
            (.wav, ["-c:a", "pcm_s16le"]),
            (.mp3, ["-c:a", "libmp3lame", "-q:a", "2"]),
            (.m4a, ["-c:a", "aac", "-b:a", "192k"]),
        ] {
            var settings = RecordingSettings()
            settings.format = format
            let args = CommandBuilder.arguments(
                remoteIndex: 0, micIndex: 1, settings: settings,
                outputURL: URL(fileURLWithPath: "/tmp/x.\(format.rawValue)"))
            let codecStart = args.firstIndex(of: "-c:a")!
            try expectEqual(Array(args[codecStart..<(codecStart + expected.count)]), expected)
        }
    }

    test("exposes ametadata instance ids for the level parser") {
        try expectEqual(CommandBuilder.remoteAmetadataInstanceID, 4)
        try expectEqual(CommandBuilder.micAmetadataInstanceID, 9)
    }
}
```

- [ ] **Step 2: Register `runCommandBuilderTests()` in `main.swift`, run, verify compile failure**

- [ ] **Step 3: Implement `Sources/RecorderCore/CommandBuilder.swift`**

```swift
import Foundation

public enum CommandBuilder {
    /// Position of each branch's ametadata filter in the filtergraph spec.
    /// Remote branch: aresample(0) aformat(1) volume(2) astats(3) ametadata(4)
    /// Mic branch:    aresample(5) aformat(6) volume(7) astats(8) ametadata(9)
    public static let remoteAmetadataInstanceID = 4
    public static let micAmetadataInstanceID = 9

    public static func arguments(
        remoteIndex: Int,
        micIndex: Int,
        settings: RecordingSettings,
        outputURL: URL
    ) -> [String] {
        let meter = "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level"
        let remoteBranch = "[0:a]aresample=48000,aformat=channel_layouts=mono,"
            + "volume=\(formatVolume(settings.remoteVolume)),\(meter)[remote]"
        let micBranch = "[1:a]aresample=48000,aformat=channel_layouts=mono,"
            + "volume=\(formatVolume(settings.micVolume)),\(meter)[mic]"
        let mix = "[remote][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,"
            + "alimiter=limit=0.95[mixed]"
        let graph = "\(remoteBranch);\(micBranch);\(mix)"

        return [
            "-hide_banner", "-nostats",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":\(remoteIndex)",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":\(micIndex)",
            "-filter_complex", graph,
            "-map", "[mixed]",
        ] + settings.format.codecArguments + [
            "-n",
            outputURL.path,
        ]
    }

    private static func formatVolume(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
```

Note `-n` (never overwrite): combined with `OutputLocation`'s collision suffixes, ffmpeg can never hang on an interactive "Overwrite? [y/N]" prompt.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 21 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: generate ffmpeg mixing command with level metering branches"
```

---

### Task 7: LevelLineParser

**Files:**
- Create: `Sources/RecorderCore/LevelLineParser.swift`
- Create: `Sources/RecorderCoreTests/LevelLineParserTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

ffmpeg's `ametadata=mode=print` writes lines like these to stderr (one header line per frame, then one value line):

```
[Parsed_ametadata_4 @ 0x600002c10000] frame:120  pts:122880  pts_time:2.56
[Parsed_ametadata_4 @ 0x600002c10000] lavfi.astats.Overall.RMS_level=-23.456789
```

- [ ] **Step 1: Write failing tests in `Sources/RecorderCoreTests/LevelLineParserTests.swift`**

```swift
import Foundation
import RecorderCore

func runLevelLineParserTests() {
    test("parses remote RMS level line") {
        let parser = LevelLineParser()
        let sample = parser.parse(line: "[Parsed_ametadata_4 @ 0x600002c10000] lavfi.astats.Overall.RMS_level=-23.456789")
        try expectEqual(sample?.source, .remote)
        try expect(abs((sample?.rmsDB ?? 0) - (-23.456789)) < 0.0001, "wrong dB value")
    }

    test("parses mic RMS level line") {
        let parser = LevelLineParser()
        let sample = parser.parse(line: "[Parsed_ametadata_9 @ 0x600002c10aaa] lavfi.astats.Overall.RMS_level=-5.1")
        try expectEqual(sample?.source, .mic)
    }

    test("maps -inf (silence) to the floor value") {
        let parser = LevelLineParser()
        let sample = parser.parse(line: "[Parsed_ametadata_9 @ 0x600002c10aaa] lavfi.astats.Overall.RMS_level=-inf")
        try expectEqual(sample?.rmsDB, -120)
    }

    test("ignores frame header lines and unrelated output") {
        let parser = LevelLineParser()
        try expectEqual(parser.parse(line: "[Parsed_ametadata_4 @ 0x6000] frame:120  pts:122880  pts_time:2.56") == nil, true)
        try expectEqual(parser.parse(line: "size=     512KiB time=00:00:10.00 bitrate= 419.4kbits/s") == nil, true)
    }

    test("ignores unknown instance ids") {
        let parser = LevelLineParser()
        try expectEqual(parser.parse(line: "[Parsed_ametadata_7 @ 0x6000] lavfi.astats.Overall.RMS_level=-3.0") == nil, true)
    }
}
```

- [ ] **Step 2: Register `runLevelLineParserTests()` in `main.swift`, run, verify compile failure**

- [ ] **Step 3: Implement `Sources/RecorderCore/LevelLineParser.swift`**

```swift
import Foundation

public enum InputSource: Equatable {
    case remote
    case mic
}

public struct LevelSample: Equatable {
    public let source: InputSource
    public let rmsDB: Double
}

public final class LevelLineParser {
    public static let silenceFloorDB: Double = -120

    private let remoteInstanceID: Int
    private let micInstanceID: Int
    private let regex = try! NSRegularExpression(
        pattern: #"\[Parsed_ametadata_(\d+) @ [^\]]+\] lavfi\.astats\.Overall\.RMS_level=(-?(?:[\d.]+|inf))"#)

    public init(
        remoteInstanceID: Int = CommandBuilder.remoteAmetadataInstanceID,
        micInstanceID: Int = CommandBuilder.micAmetadataInstanceID
    ) {
        self.remoteInstanceID = remoteInstanceID
        self.micInstanceID = micInstanceID
    }

    public func parse(line: String) -> LevelSample? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let idRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line),
              let instanceID = Int(line[idRange]) else { return nil }

        let source: InputSource
        switch instanceID {
        case remoteInstanceID: source = .remote
        case micInstanceID: source = .mic
        default: return nil
        }

        let rawValue = String(line[valueRange])
        let rmsDB = Double(rawValue) ?? Self.silenceFloorDB
        return LevelSample(source: source, rmsDB: max(rmsDB, Self.silenceFloorDB))
    }
}
```

(`Double("-inf")` parses to `-.infinity`, and `max(-inf, -120)` clamps it to the floor — that's what the `-inf` test exercises.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 26 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: parse per-input RMS levels from ffmpeg ametadata stderr lines"
```

---

### Task 8: ProcessRunning protocol + RecordingController

**Files:**
- Create: `Sources/RecorderCore/ProcessRunning.swift`
- Create: `Sources/RecorderCore/RecordingController.swift`
- Create: `Sources/RecorderCoreTests/RecordingControllerTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

Threading contract: the real process implementation (Task 9) delivers `onStderrLine` and `onTermination` on the **main queue**; the controller assumes callbacks arrive on its own thread and does no hopping itself. Tests call callbacks synchronously.

- [ ] **Step 1: Create `Sources/RecorderCore/ProcessRunning.swift`**

```swift
import Foundation

public protocol ProcessRunning: AnyObject {
    var onStderrLine: ((String) -> Void)? { get set }
    var onTermination: ((Int32) -> Void)? { get set }
    var isRunning: Bool { get }

    func start(executable: String, arguments: [String]) throws
    func writeStdin(_ string: String)
    func interrupt()
    func forceKill()
}
```

- [ ] **Step 2: Write failing tests in `Sources/RecorderCoreTests/RecordingControllerTests.swift`**

```swift
import Foundation
import RecorderCore

final class FakeProcess: ProcessRunning {
    var onStderrLine: ((String) -> Void)?
    var onTermination: ((Int32) -> Void)?
    var isRunning = false
    var startedWith: (executable: String, arguments: [String])?
    var stdinWrites: [String] = []
    var interrupted = false
    var killed = false

    func start(executable: String, arguments: [String]) throws {
        startedWith = (executable, arguments)
        isRunning = true
    }

    func writeStdin(_ string: String) { stdinWrites.append(string) }
    func interrupt() { interrupted = true }
    func forceKill() { killed = true }

    func emitStderr(_ line: String) { onStderrLine?(line) }
    func terminate(status: Int32) {
        isRunning = false
        onTermination?(status)
    }
}

func runRecordingControllerTests() {
    func makeTempFile(content: String = "x") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-test-\(UUID().uuidString).flac")
        try! Data(content.utf8).write(to: url)
        return url
    }

    func makeController() -> (RecordingController, FakeProcess) {
        let fake = FakeProcess()
        let controller = RecordingController(makeProcess: { fake })
        return (controller, fake)
    }

    test("start launches ffmpeg and enters recording state") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/opt/homebrew/bin/ffmpeg",
                         arguments: ["-i", ":0"],
                         outputURL: URL(fileURLWithPath: "/tmp/never.flac"))
        try expectEqual(fake.startedWith?.executable, "/opt/homebrew/bin/ffmpeg")
        try expectEqual(fake.startedWith?.arguments, ["-i", ":0"])
        guard case .recording = controller.state else {
            throw TestFailure(description: "expected .recording, got \(controller.state)")
        }
    }

    test("level lines update published levels") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"))
        fake.emitStderr("[Parsed_ametadata_4 @ 0x1] lavfi.astats.Overall.RMS_level=-20.0")
        fake.emitStderr("[Parsed_ametadata_9 @ 0x2] lavfi.astats.Overall.RMS_level=-7.5")
        try expectEqual(controller.remoteLevelDB, -20.0)
        try expectEqual(controller.micLevelDB, -7.5)
    }

    test("stop writes q and transitions to stopping") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"))
        controller.stop()
        try expectEqual(fake.stdinWrites, ["q"])
        guard case .stopping = controller.state else {
            throw TestFailure(description: "expected .stopping, got \(controller.state)")
        }
    }

    test("clean exit after stop with valid file ends in saved") {
        let (controller, fake) = makeController()
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file)
        controller.stop()
        fake.terminate(status: 0)
        try expectEqual(controller.state, .saved(file))
    }

    test("exit after stop with missing file ends in failed") {
        let (controller, fake) = makeController()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).flac")
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: missing)
        controller.stop()
        fake.terminate(status: 0)
        guard case .failed(let message, _) = controller.state else {
            throw TestFailure(description: "expected .failed, got \(controller.state)")
        }
        try expect(message.contains("missing or empty"), "unexpected message: \(message)")
    }

    test("unexpected exit while recording ends in failed with stderr tail") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: URL(fileURLWithPath: "/tmp/n.flac"))
        for i in 1...30 { fake.emitStderr("line \(i)") }
        fake.terminate(status: 1)
        guard case .failed(let message, let tail) = controller.state else {
            throw TestFailure(description: "expected .failed, got \(controller.state)")
        }
        try expect(message.contains("unexpectedly"), "unexpected message: \(message)")
        try expectEqual(tail.count, 20)
        try expectEqual(tail.last, "line 30")
    }

    test("can start a new recording after saved") {
        let (controller, fake) = makeController()
        let file = makeTempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file)
        controller.stop()
        fake.terminate(status: 0)
        controller.start(ffmpegPath: "/ff", arguments: [], outputURL: file)
        guard case .recording = controller.state else {
            throw TestFailure(description: "expected .recording after restart, got \(controller.state)")
        }
    }

    test("start while already recording is ignored") {
        let (controller, fake) = makeController()
        controller.start(ffmpegPath: "/ff", arguments: ["first"], outputURL: URL(fileURLWithPath: "/tmp/n.flac"))
        controller.start(ffmpegPath: "/ff", arguments: ["second"], outputURL: URL(fileURLWithPath: "/tmp/n.flac"))
        try expectEqual(fake.startedWith?.arguments, ["first"])
    }
}
```

- [ ] **Step 3: Register `runRecordingControllerTests()` in `main.swift`, run, verify compile failure**

- [ ] **Step 4: Implement `Sources/RecorderCore/RecordingController.swift`**

```swift
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

        let interruptWork = DispatchWorkItem { [weak proc] in proc?.interrupt() }
        let killWork = DispatchWorkItem { [weak proc] in proc?.forceKill() }
        escalationWork = [interruptWork, killWork]
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: interruptWork)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killWork)
    }

    private func handleStderr(_ line: String) {
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
        escalationWork.forEach { $0.cancel() }
        escalationWork = []
        defer { process = nil }

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
```

This references `FFmpegProcess` (the default factory), which doesn't exist yet. To keep this task compiling on its own, add a **temporary stub** at the bottom of `ProcessRunning.swift` (replaced by the real implementation in Task 9):

```swift
/// Temporary stub — real implementation lands in FFmpegProcess.swift (Task 9).
public final class FFmpegProcess: ProcessRunning {
    public var onStderrLine: ((String) -> Void)?
    public var onTermination: ((Int32) -> Void)?
    public var isRunning: Bool { false }
    public init() {}
    public func start(executable: String, arguments: [String]) throws {
        fatalError("FFmpegProcess not implemented yet")
    }
    public func writeStdin(_ string: String) {}
    public func interrupt() {}
    public func forceKill() {}
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 34 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "feat: recording controller state machine with clean-stop escalation"
```

---

### Task 9: FFmpegProcess (real subprocess) + DeviceScanner

**Files:**
- Create: `Sources/RecorderCore/FFmpegProcess.swift`
- Create: `Sources/RecorderCore/DeviceScanner.swift`
- Modify: `Sources/RecorderCore/ProcessRunning.swift` (remove the stub)

These wrap Foundation `Process` and are verified by the live end-to-end checks in Task 12 (unit tests would just re-test Foundation).

- [ ] **Step 1: Delete the temporary `FFmpegProcess` stub from `Sources/RecorderCore/ProcessRunning.swift`** (the file keeps only the protocol).

- [ ] **Step 2: Create `Sources/RecorderCore/FFmpegProcess.swift`**

```swift
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
```

- [ ] **Step 3: Create `Sources/RecorderCore/DeviceScanner.swift`**

```swift
import Foundation

public enum DeviceScanner {
    /// Lists avfoundation audio devices by running ffmpeg's device listing.
    /// ffmpeg exits nonzero after listing (it has no real input) — that is expected.
    public static func scan(ffmpegPath: String) -> [AudioDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-hide_banner", "-f", "avfoundation", "-list_devices", "true", "-i", ""]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return []
        }
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return DeviceListParser.parseAudioDevices(from: String(decoding: data, as: UTF8.self))
    }
}
```

- [ ] **Step 4: Verify everything still builds and tests pass**

Run: `swift build && swift run RecorderCoreTests`
Expected: build succeeds; 34 passed, 0 failed.

- [ ] **Step 5: Smoke-test DeviceScanner against the real ffmpeg**

Run:
```bash
swift build
cat > /tmp/scan_probe.swift <<'EOF'
import RecorderCore
for d in DeviceScanner.scan(ffmpegPath: "/opt/homebrew/bin/ffmpeg") {
    print("\(d.index): \(d.name)")
}
EOF
swiftc /tmp/scan_probe.swift -I .build/debug/Modules -L .build/debug -lRecorderCore -o /tmp/scan_probe && /tmp/scan_probe
```
Expected output (device set may vary, BlackHole 2ch must appear):
```
0: BlackHole 2ch
1: MacBook Air Microphone
2: Microsoft Teams Audio
3: BlackHole 16ch
```
If the `swiftc` link incantation fails (module layout differs between toolchains), an equivalent check: temporarily change `Sources/MeetingRecorder/main.swift` to run the scan, `swift run MeetingRecorder`, then revert. Either path satisfies this step.

- [ ] **Step 6: Commit**

```bash
git add Sources
git commit -m "feat: real ffmpeg subprocess wrapper and device scanner"
```

---

### Task 10: PreflightValidator

**Files:**
- Create: `Sources/RecorderCore/PreflightValidator.swift`
- Create: `Sources/RecorderCoreTests/PreflightValidatorTests.swift`
- Modify: `Sources/RecorderCoreTests/main.swift`

- [ ] **Step 1: Write failing tests in `Sources/RecorderCoreTests/PreflightValidatorTests.swift`**

```swift
import Foundation
import RecorderCore

func runPreflightValidatorTests() {
    let devices = [
        AudioDevice(index: 0, name: "BlackHole 2ch"),
        AudioDevice(index: 1, name: "MacBook Air Microphone"),
    ]

    func validSettings() -> RecordingSettings {
        var settings = RecordingSettings(outputFolder: FileManager.default.temporaryDirectory
            .appendingPathComponent("preflight-\(UUID().uuidString)", isDirectory: true))
        settings.remoteDeviceName = "BlackHole 2ch"
        settings.micDeviceName = "MacBook Air Microphone"
        return settings
    }

    test("all good yields no issues and creates the output folder") {
        let settings = validSettings()
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: "/opt/homebrew/bin/ffmpeg", micAuthorized: true)
        try expectEqual(issues, [])
        try expect(FileManager.default.fileExists(atPath: settings.outputFolder.path),
                   "output folder was not created")
        try? FileManager.default.removeItem(at: settings.outputFolder)
    }

    test("missing selections are reported") {
        var settings = validSettings()
        settings.remoteDeviceName = nil
        settings.micDeviceName = nil
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: "/ff", micAuthorized: true)
        try expect(issues.contains(.noRemoteSelected), "noRemoteSelected missing")
        try expect(issues.contains(.noMicSelected), "noMicSelected missing")
    }

    test("selected device that disappeared is reported by name") {
        var settings = validSettings()
        settings.remoteDeviceName = "Jabra Elite 8 Active"
        let issues = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: "/ff", micAuthorized: true)
        try expect(issues.contains(.deviceMissing(name: "Jabra Elite 8 Active")),
                   "deviceMissing not reported: \(issues)")
    }

    test("missing ffmpeg and denied mic access are reported") {
        let issues = PreflightValidator.validate(
            settings: validSettings(), availableDevices: devices,
            ffmpegPath: nil, micAuthorized: false)
        try expect(issues.contains(.ffmpegNotFound), "ffmpegNotFound missing")
        try expect(issues.contains(.microphoneAccessDenied), "microphoneAccessDenied missing")
    }

    test("issues have user-readable descriptions") {
        try expect(PreflightIssue.ffmpegNotFound.description.contains("brew install ffmpeg"),
                   "ffmpeg issue should tell the user how to install it")
        try expect(PreflightIssue.deviceMissing(name: "Jabra").description.contains("Jabra"),
                   "device issue should name the device")
    }
}
```

- [ ] **Step 2: Register `runPreflightValidatorTests()` in `main.swift`, run, verify compile failure**

- [ ] **Step 3: Implement `Sources/RecorderCore/PreflightValidator.swift`**

```swift
import Foundation

public enum PreflightIssue: Equatable, CustomStringConvertible {
    case noRemoteSelected
    case noMicSelected
    case deviceMissing(name: String)
    case ffmpegNotFound
    case microphoneAccessDenied
    case outputFolderNotWritable(path: String)

    public var description: String {
        switch self {
        case .noRemoteSelected:
            return "Select a remote/system audio source (e.g. BlackHole 2ch)."
        case .noMicSelected:
            return "Select a microphone."
        case .deviceMissing(let name):
            return "Device \"\(name)\" is not available. Refresh devices and pick another."
        case .ffmpegNotFound:
            return "ffmpeg was not found. Install it with: brew install ffmpeg"
        case .microphoneAccessDenied:
            return "Microphone access is denied. Enable it in System Settings → Privacy & Security → Microphone."
        case .outputFolderNotWritable(let path):
            return "Cannot write to output folder: \(path). Choose another folder."
        }
    }
}

public enum PreflightValidator {
    public static func validate(
        settings: RecordingSettings,
        availableDevices: [AudioDevice],
        ffmpegPath: String?,
        micAuthorized: Bool,
        fileManager: FileManager = .default
    ) -> [PreflightIssue] {
        var issues: [PreflightIssue] = []
        let names = Set(availableDevices.map(\.name))

        if let remote = settings.remoteDeviceName {
            if !names.contains(remote) { issues.append(.deviceMissing(name: remote)) }
        } else {
            issues.append(.noRemoteSelected)
        }

        if let mic = settings.micDeviceName {
            if !names.contains(mic) { issues.append(.deviceMissing(name: mic)) }
        } else {
            issues.append(.noMicSelected)
        }

        if ffmpegPath == nil { issues.append(.ffmpegNotFound) }
        if !micAuthorized { issues.append(.microphoneAccessDenied) }

        do {
            try fileManager.createDirectory(at: settings.outputFolder, withIntermediateDirectories: true)
            if !fileManager.isWritableFile(atPath: settings.outputFolder.path) {
                issues.append(.outputFolderNotWritable(path: settings.outputFolder.path))
            }
        } catch {
            issues.append(.outputFolderNotWritable(path: settings.outputFolder.path))
        }

        return issues
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run RecorderCoreTests`
Expected: 39 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add Sources
git commit -m "feat: pre-recording validation with actionable issue messages"
```

---

### Task 11: SwiftUI app (AppModel + views)

**Files:**
- Delete: `Sources/MeetingRecorder/main.swift` (placeholder)
- Create: `Sources/MeetingRecorder/MeetingRecorderApp.swift`
- Create: `Sources/MeetingRecorder/AppModel.swift`
- Create: `Sources/MeetingRecorder/ContentView.swift`
- Create: `Sources/MeetingRecorder/LevelMeterView.swift`
- Create: `Sources/MeetingRecorder/SettingsSheet.swift`

UI code is verified by `swift build` plus the manual run in Task 12 — no unit tests for views.

- [ ] **Step 1: Delete `Sources/MeetingRecorder/main.swift`** (an `@main` attribute cannot coexist with `main.swift` in the same target).

- [ ] **Step 2: Create `Sources/MeetingRecorder/MeetingRecorderApp.swift`**

```swift
import SwiftUI

@main
struct MeetingRecorderApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Meeting Recorder") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    // Needed when launched via `swift run` (no bundle): become a regular app.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 3: Create `Sources/MeetingRecorder/AppModel.swift`**

```swift
import AVFoundation
import Combine
import RecorderCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [AudioDevice] = []
    @Published var settings: RecordingSettings {
        didSet { store.save(settings) }
    }
    @Published var issues: [PreflightIssue] = []
    @Published var showSettingsSheet = false

    let controller = RecordingController()
    private let store: SettingsStore
    private let locator = FFmpegLocator()
    private var cancellables: Set<AnyCancellable> = []

    var ffmpegPath: String? {
        locator.locate(override: settings.ffmpegPathOverride)
    }

    var isRecording: Bool {
        if case .recording = controller.state { return true }
        if case .stopping = controller.state { return true }
        return false
    }

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
        // Forward nested ObservableObject changes so views observing the model re-render.
        controller.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        refreshDevices()
    }

    func refreshDevices() {
        guard let path = ffmpegPath else {
            devices = []
            issues = [.ffmpegNotFound]
            return
        }
        devices = DeviceScanner.scan(ffmpegPath: path)
    }

    func startRecording() {
        issues = []
        refreshDevices()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in self.beginRecording(micAuthorized: granted) }
            }
        case .authorized:
            beginRecording(micAuthorized: true)
        default:
            beginRecording(micAuthorized: false)
        }
    }

    private func beginRecording(micAuthorized: Bool) {
        let path = ffmpegPath
        let found = PreflightValidator.validate(
            settings: settings, availableDevices: devices,
            ffmpegPath: path, micAuthorized: micAuthorized)
        guard found.isEmpty,
              let path,
              let remote = devices.first(where: { $0.name == settings.remoteDeviceName }),
              let mic = devices.first(where: { $0.name == settings.micDeviceName })
        else {
            issues = found
            return
        }

        let outputURL = OutputLocation.makeURL(settings: settings, date: Date())
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let arguments = CommandBuilder.arguments(
            remoteIndex: remote.index, micIndex: mic.index,
            settings: settings, outputURL: outputURL)
        controller.start(ffmpegPath: path, arguments: arguments, outputURL: outputURL)
    }

    func stopRecording() {
        controller.stop()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
```

- [ ] **Step 4: Create `Sources/MeetingRecorder/LevelMeterView.swift`**

```swift
import SwiftUI

struct LevelMeterView: View {
    let label: String
    let levelDB: Double

    // Map -60 dB...0 dB onto 0...1.
    private var fraction: CGFloat {
        CGFloat(max(0, min(1, (levelDB + 60) / 60)))
    }

    private var barColor: Color {
        if fraction > 0.85 { return .red }
        if fraction > 0.6 { return .yellow }
        return .green
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .frame(width: 56, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 8)
        }
        .animation(.linear(duration: 0.1), value: fraction)
    }
}
```

- [ ] **Step 5: Create `Sources/MeetingRecorder/ContentView.swift`**

```swift
import RecorderCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showFolderPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            deviceSection
            Divider()
            volumeSection
            meterSection
            Divider()
            outputSection
            Divider()
            controlSection
            statusSection
        }
        .padding(20)
        .frame(width: 460)
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                model.settings.outputFolder = url
            }
        }
        .sheet(isPresented: $model.showSettingsSheet) {
            SettingsSheet()
                .environmentObject(model)
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Sources").font(.headline)
                Spacer()
                Button {
                    model.refreshDevices()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan audio devices")
                .disabled(model.isRecording)
                Button {
                    model.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
            Picker("Remote audio", selection: $model.settings.remoteDeviceName) {
                Text("Select…").tag(String?.none)
                ForEach(model.devices) { device in
                    Text(device.name).tag(Optional(device.name))
                }
            }
            .disabled(model.isRecording)
            Picker("Microphone", selection: $model.settings.micDeviceName) {
                Text("Select…").tag(String?.none)
                ForEach(model.devices) { device in
                    Text(device.name).tag(Optional(device.name))
                }
            }
            .disabled(model.isRecording)
        }
    }

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Levels").font(.headline)
            HStack {
                Text("Remote").frame(width: 56, alignment: .leading).font(.caption)
                Slider(value: $model.settings.remoteVolume, in: 0...1.5)
                Text("\(Int(model.settings.remoteVolume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
            HStack {
                Text("Mic").frame(width: 56, alignment: .leading).font(.caption)
                Slider(value: $model.settings.micVolume, in: 0...1.5)
                Text("\(Int(model.settings.micVolume * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var meterSection: some View {
        if model.isRecording {
            VStack(alignment: .leading, spacing: 6) {
                LevelMeterView(label: "Remote", levelDB: model.controller.remoteLevelDB)
                LevelMeterView(label: "Mic", levelDB: model.controller.micLevelDB)
            }
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output").font(.headline)
            HStack {
                Text(model.settings.outputFolder.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change…") { showFolderPicker = true }
                    .disabled(model.isRecording)
            }
            Picker("Format", selection: $model.settings.format) {
                ForEach(AudioFormat.allCases) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRecording)
        }
    }

    private var controlSection: some View {
        HStack {
            if model.isRecording {
                Button(role: .destructive) {
                    model.stopRecording()
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.escape, modifiers: [])
            } else {
                Button {
                    model.startRecording()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            if case .recording(let startedAt) = model.controller.state {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(elapsedString(from: startedAt, to: context.date))
                        .font(.title3.monospacedDigit())
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch model.controller.state {
        case .idle:
            EmptyView()
        case .recording:
            Label("Recording…", systemImage: "circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .stopping:
            Label("Finishing up…", systemImage: "hourglass").font(.caption)
        case .saved(let url):
            HStack {
                Label("Saved: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Button("Reveal in Finder") { model.revealInFinder(url) }
                    .font(.caption)
            }
        case .failed(let message, let stderrTail):
            VStack(alignment: .leading, spacing: 4) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                if !stderrTail.isEmpty {
                    DisclosureGroup("ffmpeg output") {
                        ScrollView {
                            Text(stderrTail.joined(separator: "\n"))
                                .font(.caption2.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                    .font(.caption)
                }
            }
        }
        ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
            Label(issue.description, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
        }
    }

    private func elapsedString(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
```

- [ ] **Step 6: Create `Sources/MeetingRecorder/SettingsSheet.swift`**

```swift
import RecorderCore
import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings").font(.title3.bold())

            Form {
                TextField("Filename prefix", text: $model.settings.filenamePrefix)
                Toggle("Create one folder per recording", isOn: $model.settings.folderPerRecording)
                TextField(
                    "ffmpeg path (blank = auto-detect)",
                    text: Binding(
                        get: { model.settings.ffmpegPathOverride ?? "" },
                        set: { model.settings.ffmpegPathOverride = $0.isEmpty ? nil : $0 }
                    ))
            }

            HStack {
                Text(model.ffmpegPath.map { "Using ffmpeg at \($0)" } ?? "ffmpeg not found")
                    .font(.caption)
                    .foregroundStyle(model.ffmpegPath == nil ? .red : .secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
```

- [ ] **Step 7: Build and run**

Run: `swift build`
Expected: builds with no errors (warnings acceptable).

Run: `swift run MeetingRecorder` (then quit the window)
Expected: a "Meeting Recorder" window appears with device dropdowns populated (BlackHole 2ch etc.), sliders at 55%/100%, FLAC selected, output folder `~/Documents/Recordings/meetings`.

- [ ] **Step 8: Commit**

```bash
git add Sources
git commit -m "feat: SwiftUI main window, settings sheet, and app model wiring"
```

---

### Task 12: App bundle script + live validation + manual E2E

**Files:**
- Create: `Scripts/make_app.sh`
- Create: `README.md`

- [ ] **Step 1: Create `Scripts/make_app.sh`**

```bash
#!/bin/bash
# Builds MeetingRecorder.app into build/. Ad-hoc signed so macOS TCC
# (microphone permission) gets a stable identity to attach to.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=build/MeetingRecorder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/MeetingRecorder "$APP/Contents/MacOS/MeetingRecorder"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MeetingRecorder</string>
    <key>CFBundleIdentifier</key>
    <string>com.joao.meeting-recorder</string>
    <key>CFBundleName</key>
    <string>Meeting Recorder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Meeting Recorder captures your microphone and system audio to record meetings locally.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
```

Run: `chmod +x Scripts/make_app.sh && ./Scripts/make_app.sh`
Expected: `Built build/MeetingRecorder.app`

- [ ] **Step 2: Launch the bundled app**

Run: `open build/MeetingRecorder.app`
Expected: app launches; on first Start Recording, macOS shows the microphone permission prompt with the usage description above.

- [ ] **Step 3: Validate ametadata instance IDs against real ffmpeg**

This confirms the hardcoded `Parsed_ametadata_4` / `Parsed_ametadata_9` assumption from Task 6:

```bash
/opt/homebrew/bin/ffmpeg -hide_banner -nostats \
  -thread_queue_size 1024 -f avfoundation -i ":0" \
  -thread_queue_size 1024 -f avfoundation -i ":1" \
  -filter_complex "[0:a]aresample=48000,aformat=channel_layouts=mono,volume=0.55,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[remote];[1:a]aresample=48000,aformat=channel_layouts=mono,volume=1.00,astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level[mic];[remote][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,alimiter=limit=0.95[mixed]" \
  -map "[mixed]" -c:a flac -t 3 -y /tmp/meter_probe.flac 2>&1 \
  | grep -o "Parsed_ametadata_[0-9]*" | sort -u
```
Expected output:
```
Parsed_ametadata_4
Parsed_ametadata_9
```
**If the IDs differ:** update `CommandBuilder.remoteAmetadataInstanceID` / `micAmetadataInstanceID` to the observed values (lower ID = remote, since the remote branch is declared first), update the Task 6 test expectations, and re-run `swift run RecorderCoreTests`.

- [ ] **Step 4: Manual end-to-end checklist** (operator at the keyboard; play audio through BlackHole during the test, e.g. join a test Meet or play a video with sound output routed to BlackHole 2ch)

1. In the app: Remote = `BlackHole 2ch`, Mic = `MacBook Air Microphone`, format FLAC, defaults elsewhere.
2. Click Start Recording → grant mic permission if prompted → status shows "Recording…", timer ticks, **both** meters move (speak for the mic one).
3. Record ~15 seconds, click Stop Recording → status shows "Saved: meeting.flac".
4. Verify the file: `afplay "$(ls -t ~/Documents/Recordings/meetings/*/meeting.flac | head -1)"` — both the system audio and your voice are audible, voice louder (0.55 vs 1.00 mix).
5. No-selection flow: set Remote audio back to "Select…" and click Start → Start is blocked and "Select a remote/system audio source" appears. (To exercise the disappeared-device path, select a Bluetooth headset as mic, disconnect it, click Start → the warning names the missing device.)
6. Crash flow: start a recording, then in a terminal run `pkill -9 -f "ffmpeg.*avfoundation"` → app shows "ffmpeg exited unexpectedly" with the ffmpeg output disclosure; the partial FLAC still plays.
7. ffmpeg-missing flow: in Settings set the ffmpeg path override to `/nonexistent/ffmpeg` (devices still selected) and click Start → the error says ffmpeg was not found and how to install it. Clear the override afterward and confirm "Using ffmpeg at /opt/homebrew/bin/ffmpeg" reappears in the settings sheet.

- [ ] **Step 5: Create `README.md`**

```markdown
# Meeting Recorder

Native macOS app that records meeting audio locally by mixing a remote/system
audio source (e.g. BlackHole 2ch) with your microphone via ffmpeg.

## Requirements

- macOS 14+
- ffmpeg (`brew install ffmpeg`)
- A loopback audio device such as [BlackHole](https://github.com/ExistentialAudio/BlackHole)
  receiving the meeting audio (e.g. via a Multi-Output Device)

## Build & run

```bash
./Scripts/make_app.sh
open build/MeetingRecorder.app
```

## Development

```bash
swift build              # compile
swift run RecorderCoreTests   # run the test suite
swift run MeetingRecorder     # run the app unbundled (no mic permission prompt)
```

Recordings default to `~/Documents/Recordings/meetings/<timestamp>/meeting.flac`.
```

- [ ] **Step 6: Commit and push**

```bash
git add Scripts README.md
git commit -m "feat: app bundle build script and README"
git push
```

---

## Acceptance criteria traceability (PRD §11)

| Criterion | Covered by |
|---|---|
| Recording Start | Task 8 (controller), Task 11 (AppModel.startRecording), Task 12 E2E step 2 |
| Recording Stop | Task 8 (stop + finalize verification), Task 12 E2E step 3-4 |
| Device Selection by name | Task 2 (parser), Task 11 (pickers), Task 12 E2E step 1 |
| Volume Control | Task 6 (volume in graph, tested), Task 11 (sliders) |
| Missing Device | Task 10 (deviceMissing), Task 12 E2E step 5 |
| Missing ffmpeg | Task 3 (locator), Task 10 (issue + brew hint), Task 12 E2E step 7 |
| Output Folder creation | Task 10 (creates folder), Task 4 (collision-safe paths) |
