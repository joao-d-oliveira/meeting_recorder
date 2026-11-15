import Foundation

/// Finds the directory holding `run.sh` and its sibling scripts.
///
/// Resolution order:
///  1. `TranscriptionSettings.pipelineDirectoryOverride`, if it contains `run.sh`
///  2. `<app bundle>/Contents/Resources/Pipeline` (what `Scripts/make_app.sh` installs)
///  3. development (`swift run`): the repo's `Pipeline/`, found by walking up from the
///     executable, then from this source file. A directory only counts as the repo root
///     if it also contains `Package.swift`, so an unrelated `~/Pipeline` is never picked up.
public struct PipelineLocator {
    public var fileExists: (String) -> Bool
    public var bundleResourceURL: URL?
    public var executableURL: URL?
    public var sourceFilePath: String

    public init(
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        executableURL: URL? = Bundle.main.executableURL,
        sourceFilePath: String = #filePath
    ) {
        self.fileExists = fileExists
        self.bundleResourceURL = bundleResourceURL
        self.executableURL = executableURL
        self.sourceFilePath = sourceFilePath
    }

    public func locate(settings: TranscriptionSettings) -> URL? {
        locate(override: settings.pipelineDirectoryOverride)
    }

    public func locate(override: String?) -> URL? {
        if let dir = overrideDirectory(override) { return dir }

        if let resources = bundleResourceURL {
            let dir = resources.appendingPathComponent("Pipeline", isDirectory: true)
            if containsRunScript(dir) { return dir }
        }

        if let executable = executableURL {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<8 {
                if let found = repoPipeline(under: dir) { return found }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }

        // Sources/RecorderCore/<this file> -> repo root is three levels up.
        let root = URL(fileURLWithPath: sourceFilePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return repoPipeline(under: root)
    }

    /// The folder configured in Settings, if it is set and contains `run.sh`; the first
    /// choice of `locate`. nil means the bundled (or development) copy is used.
    public func overrideDirectory(_ override: String?) -> URL? {
        guard let override = override?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
        else { return nil }
        let dir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        return containsRunScript(dir) ? dir : nil
    }

    /// True if `directory` contains `run.sh`.
    public func containsRunScript(_ directory: URL) -> Bool {
        fileExists(directory.appendingPathComponent("run.sh").path)
    }

    private func repoPipeline(under root: URL) -> URL? {
        guard fileExists(root.appendingPathComponent("Package.swift").path) else { return nil }
        let dir = root.appendingPathComponent("Pipeline", isDirectory: true)
        return containsRunScript(dir) ? dir : nil
    }
}
