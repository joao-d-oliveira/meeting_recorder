import Foundation
import RecorderCore

test("harness smoke test") {
    try expectEqual(AudioDevice(index: 0, name: "BlackHole 2ch").id, "BlackHole 2ch")
}

TestRunner.shared.finish()
