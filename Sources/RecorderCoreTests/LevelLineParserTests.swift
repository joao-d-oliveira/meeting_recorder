import Foundation
import RecorderCore

func runLevelLineParserTests() {
    func line(_ instance: Int, _ value: String) -> String {
        "[Parsed_ametadata_\(instance) @ 0x600002c10000] lavfi.astats.Overall.RMS_level=\(value)"
    }

    test("parses RMS level lines into input positions") {
        let parser = LevelLineParser(inputCount: 3)
        for (instance, index) in [(4, 0), (9, 1), (14, 2)] {
            let sample = parser.parse(line: line(instance, "-23.456789"))
            try expectEqual(sample?.inputIndex, index)
            try expect(abs((sample?.rmsDB ?? 0) - (-23.456789)) < 0.0001, "wrong dB value")
        }
    }

    test("positions follow CommandBuilder's instance ids for any input count") {
        let parser = LevelLineParser(inputCount: 6)
        for index in 0..<6 {
            let id = CommandBuilder.ametadataInstanceID(forInput: index)
            try expectEqual(parser.parse(line: line(id, "-10.0"))?.inputIndex, index)
        }
    }

    test("maps -inf (silence) to the floor value") {
        let parser = LevelLineParser(inputCount: 2)
        try expectEqual(parser.parse(line: line(9, "-inf"))?.rmsDB, -120)
    }

    test("clamps levels to the -120...0 dB range") {
        let parser = LevelLineParser(inputCount: 1)
        try expectEqual(parser.parse(line: line(4, "-300.0"))?.rmsDB, -120)
        try expectEqual(parser.parse(line: line(4, "2.5"))?.rmsDB, 0)
    }

    test("ignores frame header lines and unrelated output") {
        let parser = LevelLineParser(inputCount: 3)
        try expect(parser.parse(line: "[Parsed_ametadata_4 @ 0x6000] frame:120  pts:122880  pts_time:2.56") == nil,
                   "frame header parsed")
        try expect(parser.parse(line: "size=     512KiB time=00:00:10.00 bitrate= 419.4kbits/s") == nil,
                   "progress line parsed")
    }

    test("recognizes ametadata frame headers, and nothing else, as meter headers") {
        let parser = LevelLineParser(inputCount: 3)
        for id in [4, 9, 14] {
            try expect(parser.isMeterHeader(
                line: "[Parsed_ametadata_\(id) @ 0x6000] frame:120  pts:122880  pts_time:2.56"),
                "header of instance \(id) not recognized")
        }
        try expect(!parser.isMeterHeader(line: line(4, "-20.0")), "level line is not a header")
        try expect(!parser.isMeterHeader(line: "[Parsed_astats_3 @ 0x6000] frame:120"), "other filter")
        try expect(!parser.isMeterHeader(line: "size=     512KiB time=00:00:10.00"), "progress line")
        try expect(!parser.isMeterHeader(line: "Error: frame:12 dropped"), "free text")
    }

    test("ignores ametadata instances that are not an input's meter") {
        let parser = LevelLineParser(inputCount: 3)
        for id in [0, 3, 5, 7, 8, 10, 13] {
            try expect(parser.parse(line: line(id, "-3.0")) == nil, "instance \(id) should be ignored")
        }
    }

    test("ignores inputs beyond the recorded count") {
        let parser = LevelLineParser(inputCount: 2)
        try expect(parser.parse(line: line(9, "-3.0")) != nil, "input 1 should parse")
        try expect(parser.parse(line: line(14, "-3.0")) == nil, "input 2 is not recorded")
        try expect(LevelLineParser(inputCount: 0).parse(line: line(4, "-3.0")) == nil, "no inputs, no levels")
    }
}
