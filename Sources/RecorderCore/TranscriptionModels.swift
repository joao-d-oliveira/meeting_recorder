import Foundation

/// Pipeline steps, in the order `Pipeline/run.sh` reports them with `STAGE:` lines.
/// `setup` only appears on the first run, while the Python environment is being created.
public enum TranscriptionStage: String, CaseIterable, Equatable {
    case setup
    case convert
    case transcribe
    case diarize

    /// Short user-facing label ("Transcribing…").
    public var title: String {
        switch self {
        case .setup: return "Setting up (first run only)…"
        case .convert: return "Converting audio…"
        case .transcribe: return "Transcribing…"
        case .diarize: return "Identifying speakers…"
        }
    }
}

public struct TranscriptionRequest: Equatable {
    public var audioURL: URL
    /// Name of the other speaker; sanitized before use. Empty = `TranscriptionSettings.defaultGuestName`.
    public var guestName: String
    /// Where `<Guest>_Transcript.md` and its summary are written. Defaults to
    /// `defaultOutputDirectory(for:)`: the recording's own folder, or a subfolder of it when
    /// other recordings share that folder.
    public var outputDirectory: URL
    /// Name used for the interviewer's turns. Empty = `TranscriptionSettings.interviewerName`.
    public var interviewerName: String

    public init(
        audioURL: URL,
        guestName: String = "",
        outputDirectory: URL? = nil,
        interviewerName: String = ""
    ) {
        self.audioURL = audioURL
        self.guestName = guestName
        self.outputDirectory = outputDirectory ?? Self.defaultOutputDirectory(for: audioURL)
        self.interviewerName = interviewerName
    }

    /// File extensions (lower case) that count as recordings when looking for neighbours.
    static let audioExtensions: Set<String> = ["flac", "wav", "m4a", "mp3"]

    /// Where the transcript of `audioURL` goes by default.
    ///
    /// The transcript is named after the guest (`<Guest>_Transcript.md`), so two recordings
    /// that share a folder (the "folder per recording" option is off) would overwrite each
    /// other's. If the audio's folder holds any other audio file (flac, wav, m4a, mp3, any
    /// case), the transcript goes to the subfolder `<audio file name without extension>
    /// transcript` next to the audio; otherwise to the audio's own folder, which keeps the
    /// one-folder-per-recording layout unchanged. A folder that can't be listed counts as
    /// having no other recordings.
    public static func defaultOutputDirectory(
        for audioURL: URL, fileManager: FileManager = .default
    ) -> URL {
        let folder = audioURL.deletingLastPathComponent()
        let siblings = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        let hasOtherRecording = siblings.contains { name in
            guard name != audioURL.lastPathComponent,
                  !name.hasPrefix("."),  // AppleDouble "._x.flac" leftovers are not recordings
                  audioExtensions.contains((name as NSString).pathExtension.lowercased())
            else { return false }
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(
                atPath: folder.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
        guard hasOtherRecording else { return folder }
        let base = audioURL.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent("\(base) transcript", isDirectory: true)
    }

    /// Makes a user-typed name safe for a file name (`<Guest>_Transcript.md`), for the
    /// `Guest:/path` spec and for the argument parser behind it: path separators and ':' become
    /// '-', control characters and newlines become spaces, leading '.' and '-' are dropped
    /// (no hidden files, no option lookalikes), and the result is trimmed and capped at 64
    /// characters. Returns "" if nothing is left.
    public static func sanitizedName(_ raw: String) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "/", ":", "\\":
                cleaned.append("-")
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                    cleaned.append(" ")
                } else {
                    cleaned.append(scalar)
                }
            }
        }
        var name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = name.first, first == "." || first == "-" {
            name.removeFirst()
        }
        if name.count > 64 { name = String(name.prefix(64)) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `sanitizedName(raw)`, or `sanitizedName(fallback)`, or `lastResort` when both are empty.
    public static func sanitizedName(_ raw: String, fallback: String, lastResort: String = "Guest") -> String {
        for candidate in [raw, fallback] {
            let name = sanitizedName(candidate)
            if !name.isEmpty { return name }
        }
        return lastResort
    }
}

/// Facts about a finished transcript, decoded from `<Guest>_Transcript.summary.json`.
public struct TranscriptionResult: Equatable {
    public let transcriptURL: URL
    public let summaryURL: URL
    public let guest: String
    public let interviewer: String
    public let turnCount: Int
    /// End of the last transcribed word.
    public let durationSeconds: Double
    public let interviewerSpeakingSeconds: Double
    public let guestSpeakingSeconds: Double
    /// "voiceprint" (saved voiceprint) or "cross-file" (voice common to 2+ recordings).
    public let identificationMethod: String
    /// Human-readable, e.g. "voiceprint similarity [0.93 0.12]".
    public let identificationDetail: String
    /// Similarity of the two voice clusters to the interviewer (voiceprint) or to the other
    /// recordings (cross-file), indexed by cluster.
    public let similarityScores: [Double]
    public let interviewerSimilarity: Double
    public let guestSimilarity: Double
    /// True when the voiceprint match was weak enough that the pipeline warned: the labels
    /// should be checked by reading the first turns.
    public let weakMatch: Bool
    /// Turns marked "(?)" in the transcript (weak voice match).
    public let uncertainTurns: Int

    public init(
        transcriptURL: URL,
        summaryURL: URL,
        guest: String,
        interviewer: String,
        turnCount: Int,
        durationSeconds: Double,
        interviewerSpeakingSeconds: Double,
        guestSpeakingSeconds: Double,
        identificationMethod: String,
        identificationDetail: String,
        similarityScores: [Double],
        interviewerSimilarity: Double,
        guestSimilarity: Double,
        weakMatch: Bool,
        uncertainTurns: Int
    ) {
        self.transcriptURL = transcriptURL
        self.summaryURL = summaryURL
        self.guest = guest
        self.interviewer = interviewer
        self.turnCount = turnCount
        self.durationSeconds = durationSeconds
        self.interviewerSpeakingSeconds = interviewerSpeakingSeconds
        self.guestSpeakingSeconds = guestSpeakingSeconds
        self.identificationMethod = identificationMethod
        self.identificationDetail = identificationDetail
        self.similarityScores = similarityScores
        self.interviewerSimilarity = interviewerSimilarity
        self.guestSimilarity = guestSimilarity
        self.weakMatch = weakMatch
        self.uncertainTurns = uncertainTurns
    }

    /// The JSON written by Pipeline/diarize.py. `turn_count` and `duration_seconds` are
    /// required; everything else falls back to a neutral default so a newer or older
    /// pipeline version doesn't fail a transcription that did succeed.
    private struct Summary: Decodable {
        var guest: String?
        var interviewer: String?
        var turnCount: Int
        var durationSeconds: Double
        var interviewerSpeakingSeconds: Double?
        var guestSpeakingSeconds: Double?
        var identificationMethod: String?
        var identification: String?
        var similarityScores: [Double]?
        var interviewerSimilarity: Double?
        var guestSimilarity: Double?
        var weakMatch: Bool?
        var uncertainTurns: Int?
    }

    public static func decode(
        summary data: Data, transcriptURL: URL, summaryURL: URL
    ) throws -> TranscriptionResult {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let s = try decoder.decode(Summary.self, from: data)
        let scores = s.similarityScores ?? []
        return TranscriptionResult(
            transcriptURL: transcriptURL,
            summaryURL: summaryURL,
            guest: s.guest ?? "",
            interviewer: s.interviewer ?? "",
            turnCount: s.turnCount,
            durationSeconds: s.durationSeconds,
            interviewerSpeakingSeconds: s.interviewerSpeakingSeconds ?? 0,
            guestSpeakingSeconds: s.guestSpeakingSeconds ?? 0,
            identificationMethod: s.identificationMethod ?? "",
            identificationDetail: s.identification ?? "",
            similarityScores: scores,
            interviewerSimilarity: s.interviewerSimilarity ?? 0,
            guestSimilarity: s.guestSimilarity ?? 0,
            weakMatch: s.weakMatch ?? false,
            uncertainTurns: s.uncertainTurns ?? 0)
    }
}

public enum TranscriptionState: Equatable {
    case idle
    /// `progress` is 0...1 and only known while transcribing; nil = indeterminate.
    case running(stage: TranscriptionStage, progress: Double?)
    case finished(TranscriptionResult)
    /// `logTail` is the last ~20 lines of pipeline output (stdout and stderr), oldest first.
    case failed(message: String, logTail: [String])
    case cancelled
}
