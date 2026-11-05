import Foundation

public struct FFmpegLocator {
    private let fileExists: (String) -> Bool
    private let isDirectory: (String) -> Bool
    private let pathVariable: String?

    public init(
        fileExists: @escaping (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        // isExecutableFile is true for directories too, so they must be excluded separately.
        isDirectory: @escaping (String) -> Bool = {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        },
        pathVariable: String? = ProcessInfo.processInfo.environment["PATH"]
    ) {
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.pathVariable = pathVariable
    }

    public func locate(override: String? = nil) -> String? {
        if let override = override?.trimmingCharacters(in: .whitespacesAndNewlines),
           isUsable(override) {
            return override
        }
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] where isUsable(candidate) {
            return candidate
        }
        for dir in (pathVariable ?? "").split(separator: ":") {
            let candidate = "\(dir)/ffmpeg"
            if isUsable(candidate) { return candidate }
        }
        return nil
    }

    private func isUsable(_ path: String) -> Bool {
        !path.isEmpty && fileExists(path) && !isDirectory(path)
    }
}
