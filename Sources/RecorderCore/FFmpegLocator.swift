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
