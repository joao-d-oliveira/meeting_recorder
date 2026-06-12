import Foundation

final class TestRunner {
    static let shared = TestRunner()
    private(set) var passed = 0
    private(set) var failed = 0

    func test(_ name: String, _ body: () throws -> Void) {
        do {
            try body()
            passed += 1
            print("PASS \(name)")
        } catch {
            failed += 1
            print("FAIL \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
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
