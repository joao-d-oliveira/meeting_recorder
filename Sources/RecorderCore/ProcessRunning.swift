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
