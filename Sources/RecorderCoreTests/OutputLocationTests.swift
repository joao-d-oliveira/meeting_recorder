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
