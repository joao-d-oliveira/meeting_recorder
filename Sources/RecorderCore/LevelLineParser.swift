import Foundation

public enum InputSource: Equatable {
    case remote
    case mic
}

public struct LevelSample: Equatable {
    public let source: InputSource
    public let rmsDB: Double
}

public final class LevelLineParser {
    public static let silenceFloorDB: Double = -120

    private let remoteInstanceID: Int
    private let micInstanceID: Int
    private let regex = try! NSRegularExpression(
        pattern: #"\[Parsed_ametadata_(\d+) @ [^\]]+\] lavfi\.astats\.Overall\.RMS_level=(-?(?:[\d.]+|inf))"#)

    public init(
        remoteInstanceID: Int = CommandBuilder.remoteAmetadataInstanceID,
        micInstanceID: Int = CommandBuilder.micAmetadataInstanceID
    ) {
        self.remoteInstanceID = remoteInstanceID
        self.micInstanceID = micInstanceID
    }

    public func parse(line: String) -> LevelSample? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let idRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line),
              let instanceID = Int(line[idRange]) else { return nil }

        let source: InputSource
        switch instanceID {
        case remoteInstanceID: source = .remote
        case micInstanceID: source = .mic
        default: return nil
        }

        let rawValue = String(line[valueRange])
        let rmsDB = Double(rawValue) ?? Self.silenceFloorDB
        return LevelSample(source: source, rmsDB: max(rmsDB, Self.silenceFloorDB))
    }
}
