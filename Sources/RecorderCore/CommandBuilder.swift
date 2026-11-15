import Foundation

public enum CommandBuilder {
    /// Filters in one input branch: aresample(0) aformat(1) volume(2) astats(3) ametadata(4).
    /// ffmpeg numbers parsed filters in graph order, so branch `i` starts at `5 * i`.
    private static let filtersPerBranch = 5
    private static let ametadataOffsetInBranch = 4

    /// The `Parsed_ametadata_<id>` instance id of input `index`'s level-meter filter.
    public static func ametadataInstanceID(forInput index: Int) -> Int {
        filtersPerBranch * index + ametadataOffsetInBranch
    }

    /// Inverse of `ametadataInstanceID(forInput:)`; nil when `id` is not a branch's ametadata filter.
    public static func inputIndex(forAmetadataInstanceID id: Int) -> Int? {
        guard id >= ametadataOffsetInBranch,
              (id - ametadataOffsetInBranch) % filtersPerBranch == 0 else { return nil }
        return (id - ametadataOffsetInBranch) / filtersPerBranch
    }

    /// Mixes N inputs (ffmpeg inputs 0..N-1, in order) into one mono stream, with a
    /// per-input RMS meter on stderr. With the default three inputs and `includeMeters: false`
    /// this is the same graph as ~/.claude/skills/interview-transcribe/scripts/record-meeting.sh.
    public static func filterGraph(gains: [Double], includeMeters: Bool = true) -> String {
        let meter = includeMeters
            ? ",astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level"
            : ""
        let branches = gains.enumerated().map { index, gain in
            "[\(index):a]aresample=48000,aformat=channel_layouts=mono,"
                + "volume=\(formatVolume(gain))\(meter)[in\(index)]"
        }
        let labels = gains.indices.map { "[in\($0)]" }.joined()
        let mix = "\(labels)amix=inputs=\(gains.count):duration=longest:dropout_transition=0:normalize=0,"
            + "alimiter=limit=0.95[mixed]"
        return (branches + [mix]).joined(separator: ";")
    }

    /// `inputs` must not be empty (PreflightValidator guarantees it); an empty list produces
    /// a graph ffmpeg rejects, which surfaces as a failed recording rather than a crash.
    public static func arguments(
        inputs: [ResolvedInput],
        settings: RecordingSettings,
        outputURL: URL
    ) -> [String] {
        let inputArguments = inputs.flatMap { input in
            ["-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":\(input.deviceIndex)"]
        }
        let graph = filterGraph(gains: inputs.map(\.gain))

        // Audio has no keyframes, so +frag_keyframe alone emits no fragments: without
        // -frag_duration a SIGKILLed m4a has no moov atom and is unplayable.
        let containerArguments = settings.format == .m4a
            ? ["-movflags", "+frag_keyframe+empty_moov", "-frag_duration", "1000000"]
            : []

        return ["-hide_banner", "-nostats"] + inputArguments + [
            "-filter_complex", graph,
            "-map", "[mixed]",
        ] + settings.format.codecArguments + containerArguments + [
            // ffmpeg buffers ~32 KB of output; flushing each packet bounds what a crash loses.
            "-flush_packets", "1",
            "-n",
            outputURL.path,
        ]
    }

    private static func formatVolume(_ value: Double) -> String {
        // No-locale formatting is deliberate: a localized "0,55" would break the filtergraph.
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
