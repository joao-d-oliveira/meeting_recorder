import Foundation

public enum CommandBuilder {
    /// Position of each branch's ametadata filter in the filtergraph spec.
    /// Remote branch: aresample(0) aformat(1) volume(2) astats(3) ametadata(4)
    /// Mic branch:    aresample(5) aformat(6) volume(7) astats(8) ametadata(9)
    public static let remoteAmetadataInstanceID = 4
    public static let micAmetadataInstanceID = 9

    public static func arguments(
        remoteIndex: Int,
        micIndex: Int,
        settings: RecordingSettings,
        outputURL: URL
    ) -> [String] {
        let meter = "astats=metadata=1:reset=1,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level"
        let remoteBranch = "[0:a]aresample=48000,aformat=channel_layouts=mono,"
            + "volume=\(formatVolume(settings.remoteVolume)),\(meter)[remote]"
        let micBranch = "[1:a]aresample=48000,aformat=channel_layouts=mono,"
            + "volume=\(formatVolume(settings.micVolume)),\(meter)[mic]"
        let mix = "[remote][mic]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0,"
            + "alimiter=limit=0.95[mixed]"
        let graph = "\(remoteBranch);\(micBranch);\(mix)"

        // Audio has no keyframes, so +frag_keyframe alone emits no fragments: without
        // -frag_duration a SIGKILLed m4a has no moov atom and is unplayable.
        let containerArguments = settings.format == .m4a
            ? ["-movflags", "+frag_keyframe+empty_moov", "-frag_duration", "1000000"]
            : []

        return [
            "-hide_banner", "-nostats",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":\(remoteIndex)",
            "-thread_queue_size", "1024", "-f", "avfoundation", "-i", ":\(micIndex)",
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
