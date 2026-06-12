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
