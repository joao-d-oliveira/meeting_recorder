import Foundation
import RecorderCore

func runLevelLineParserTests() {
    test("parses remote RMS level line") {
        let parser = LevelLineParser()
        let sample = parser.parse(line: "[Parsed_ametadata_4 @ 0x600002c10000] lavfi.astats.Overall.RMS_level=-23.456789")
        try expectEqual(sample?.source, .remote)
        try expect(abs((sample?.rmsDB ?? 0) - (-23.456789)) < 0.0001, "wrong dB value")
    }

    test("parses mic RMS level line") {
        let parser = LevelLineParser()
        let sample = parser.parse(line: "[Parsed_ametadata_9 @ 0x600002c10aaa] lavfi.astats.Overall.RMS_level=-5.1")
        try expectEqual(sample?.source, .mic)
    }

    test("maps -inf (silence) to the floor value") {
        let parser = LevelLineParser()
        let sample = parser.parse(line: "[Parsed_ametadata_9 @ 0x600002c10aaa] lavfi.astats.Overall.RMS_level=-inf")
        try expectEqual(sample?.rmsDB, -120)
    }

    test("ignores frame header lines and unrelated output") {
        let parser = LevelLineParser()
        try expectEqual(parser.parse(line: "[Parsed_ametadata_4 @ 0x6000] frame:120  pts:122880  pts_time:2.56") == nil, true)
        try expectEqual(parser.parse(line: "size=     512KiB time=00:00:10.00 bitrate= 419.4kbits/s") == nil, true)
    }

    test("ignores unknown instance ids") {
        let parser = LevelLineParser()
        try expectEqual(parser.parse(line: "[Parsed_ametadata_7 @ 0x6000] lavfi.astats.Overall.RMS_level=-3.0") == nil, true)
    }
}
