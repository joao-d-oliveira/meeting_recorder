import Foundation

public struct LevelSample: Equatable {
    /// Position of the input among the recorded inputs (ffmpeg input number).
    public let inputIndex: Int
    public let rmsDB: Double

    public init(inputIndex: Int, rmsDB: Double) {
        self.inputIndex = inputIndex
        self.rmsDB = rmsDB
    }
}

public final class LevelLineParser {
    public static let silenceFloorDB: Double = -120

    private let inputCount: Int
    private let regex = try! NSRegularExpression(
        pattern: #"\[Parsed_ametadata_(\d+) @ [^\]]+\] lavfi\.astats\.Overall\.RMS_level=(-?(?:[\d.]+|inf))"#)

    /// `inputCount` is how many inputs the recording mixes; lines from any other
    /// ametadata instance are ignored.
    public init(inputCount: Int) {
        self.inputCount = inputCount
    }

    public func parse(line: String) -> LevelSample? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let idRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line),
              let instanceID = Int(line[idRange]),
              let inputIndex = CommandBuilder.inputIndex(forAmetadataInstanceID: instanceID),
              inputIndex < inputCount else { return nil }

        let rawValue = String(line[valueRange])
        let rmsDB = Double(rawValue) ?? Self.silenceFloorDB
        return LevelSample(inputIndex: inputIndex, rmsDB: min(max(rmsDB, Self.silenceFloorDB), 0))
    }
}
