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

    test("trims whitespace around the override") {
        let locator = FFmpegLocator(fileExists: { $0 == "/custom/ffmpeg" }, pathVariable: nil)
        try expectEqual(locator.locate(override: "  /custom/ffmpeg\n"), "/custom/ffmpeg")
    }

    test("whitespace-only override falls back to auto-detect") {
        let locator = FFmpegLocator(
            fileExists: { $0 == "/usr/local/bin/ffmpeg" }, pathVariable: nil)
        try expectEqual(locator.locate(override: "   "), "/usr/local/bin/ffmpeg")
    }

    test("rejects a directory override and falls back to auto-detect") {
        let locator = FFmpegLocator(
            fileExists: { _ in true },
            isDirectory: { $0 == "/opt/homebrew/bin" },
            pathVariable: nil)
        try expectEqual(locator.locate(override: "/opt/homebrew/bin"), "/opt/homebrew/bin/ffmpeg")
    }

    test("returns nil when the only override is a directory and nothing else is found") {
        let locator = FFmpegLocator(
            fileExists: { $0 == "/opt/homebrew/bin" },
            isDirectory: { $0 == "/opt/homebrew/bin" },
            pathVariable: nil)
        try expectEqual(locator.locate(override: "/opt/homebrew/bin"), nil)
    }

    test("skips search candidates that are directories") {
        let locator = FFmpegLocator(
            fileExists: { _ in true },
            isDirectory: { $0 == "/opt/homebrew/bin/ffmpeg" || $0 == "/usr/local/bin/ffmpeg" },
            pathVariable: "/weird/place")
        try expectEqual(locator.locate(), "/weird/place/ffmpeg")
    }

    test("default checks accept an executable file and reject a directory") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let locator = FFmpegLocator(pathVariable: nil)
        try expectEqual(locator.locate(override: binary.path), binary.path)
        try expect(locator.locate(override: dir.path) != dir.path, "directory override was accepted")
    }
}
