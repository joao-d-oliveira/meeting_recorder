import Foundation
import RecorderCore

test("harness smoke test") {
    try expectEqual(AudioDevice(index: 0, name: "BlackHole 2ch").id, "BlackHole 2ch")
}

runDeviceListParserTests()
runFFmpegLocatorTests()
runFFmpegProcessTests()
runTranscriptionTests()
runOutputLocationTests()
runSettingsStoreTests()
runCommandBuilderTests()
runLevelLineParserTests()
runRecordingControllerTests()
runPreflightValidatorTests()
TestRunner.shared.finish()
