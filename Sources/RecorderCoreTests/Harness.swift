import Foundation

final class TestRunner {
    static let shared = TestRunner()
    private(set) var passed = 0
    private(set) var failed = 0
    private(set) var skipped = 0

    func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch let skip as TestSkip {
            skipped += 1
            print("SKIP \(name): \(skip.reason)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed" + (skipped > 0 ? ", \(skipped) skipped" : ""))
        exit(failed == 0 ? 0 : 1)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

/// Thrown by a test whose precondition is missing on this machine (e.g. no ffmpeg installed).
/// Reported as a visible SKIP line and counted separately, never as a pass.
struct TestSkip: Error {
    let reason: String
}

func test(_ name: String, _ body: () throws -> Void) {
    TestRunner.shared.test(name, body)
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "expected true",
            file: String = #file, line: Int = #line) throws {
    if !condition {
        throw TestFailure(description: "\(message()) (\(file):\(line))")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T,
                               file: String = #file, line: Int = #line) throws {
    if actual != expected {
        throw TestFailure(description: "expected \(expected), got \(actual) (\(file):\(line))")
    }
}
