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
