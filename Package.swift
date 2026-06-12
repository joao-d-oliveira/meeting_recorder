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
