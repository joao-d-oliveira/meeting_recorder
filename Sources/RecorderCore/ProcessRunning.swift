import Foundation

public protocol ProcessRunning: AnyObject {
    /// Delivered on the main queue. Only populated by implementations that capture
    /// stdout, and only if the handler is set before `start`; the default is a no-op.
    var onStdoutLine: ((String) -> Void)? { get set }
    var onStderrLine: ((String) -> Void)? { get set }
    var onTermination: ((Int32) -> Void)? { get set }
    var isRunning: Bool { get }

    func start(executable: String, arguments: [String]) throws
    /// Like `start(executable:arguments:)`, with an explicit environment (replaces the
    /// inherited one entirely when non-nil) and working directory.
    /// The default implementation ignores both and calls `start(executable:arguments:)`.
    func start(
        executable: String, arguments: [String],
        environment: [String: String]?, currentDirectory: String?
    ) throws
    func writeStdin(_ string: String)
    func interrupt()
    func forceKill()
}

extension ProcessRunning {
    public var onStdoutLine: ((String) -> Void)? {
        get { nil }
        set {}
    }

    public func start(
        executable: String, arguments: [String],
        environment: [String: String]?, currentDirectory: String?
    ) throws {
        try start(executable: executable, arguments: arguments)
    }
}
