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
