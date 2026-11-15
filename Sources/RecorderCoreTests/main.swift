import Foundation
import RecorderCore

test("harness smoke test") {
    try expectEqual(AudioDevice(index: 0, name: "BlackHole 2ch").id, "BlackHole 2ch")
}

runDeviceListParserTests()
runFFmpegLocatorTests()
runFFmpegProcessTests()
runTranscriptionTests()
runPipelineRobustnessTests()
runOutputLocationTests()
runInputConfigTests()
runRecordingSettingsTests()
runSettingsStoreTests()
runCommandBuilderTests()
runFFmpegGraphValidationTests()
runLevelLineParserTests()
runRecordingControllerTests()
runPreflightValidatorTests()
TestRunner.shared.finish()
