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
