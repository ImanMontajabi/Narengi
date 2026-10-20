import Foundation

/// The ffmpeg-based tools: normalize, trim silence, channels, mute, speed, snapshot, split, join,
/// visualizer, compress and metadata removal. Filter chains and argument choices are ported from
/// Satsuma's `media.rs` (MIT, © sonatina-dream); see THIRD_PARTY_NOTICES.md.
extension MediaEngine {
    typealias Progress = @Sendable (Double) -> Void

    /// Container formats whose files are video (as opposed to audio-only).
    static let videoToolFormats: Set<String> = ["MP4", "MOV", "MKV"]

    // MARK: - Audio

    private func audioFilterTool(
        source: URL, output: URL, format: String, extra: [String], progress: @escaping Progress
    ) async throws {
        let info = await probe(source)
        if info.audio == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        try await run(
            args: ["-i", source.path, "-map", "0:a:0", "-vn", "-map_metadata", "0"] + extra
                + (try audioCodecArguments(for: format, kbps: 192)),
            output: output, duration: info.duration, progress: progress)
    }

    /// EBU R128 loudness normalisation to −16 LUFS.
    func normalize(source: URL, output: URL, format: String, progress: @escaping Progress) async throws {
        let rate = await probe(source).audio?.sampleRate ?? 48_000
        try await audioFilterTool(
            source: source, output: output, format: format,
            extra: ["-af", "loudnorm=I=-16:LRA=11:TP=-1.5", "-ar", String(rate)], progress: progress)
    }

    static let silenceEdge = "silenceremove=start_periods=1:start_duration=0:start_threshold=-50dB:start_silence=0.05"

    /// Removes silence at the start and end only, keeping pauses inside.
    func trimSilence(source: URL, output: URL, format: String, progress: @escaping Progress) async throws {
        let filter = "\(Self.silenceEdge),areverse,\(Self.silenceEdge),areverse"
        try await audioFilterTool(source: source, output: output, format: format, extra: ["-af", filter], progress: progress)
    }

    /// Mono ↔ stereo: stereo (or more) becomes mono; mono becomes stereo.
    func targetChannels(for source: URL) async -> Int {
        (await probe(source).audio?.channels ?? 2) == 1 ? 2 : 1
    }

    func changeChannels(source: URL, output: URL, format: String, channels: Int, progress: @escaping Progress) async throws {
        try await audioFilterTool(source: source, output: output, format: format, extra: ["-ac", String(channels)], progress: progress)
    }

    /// MP4 with an orange waveform on black.
    func visualize(source: URL, output: URL, progress: @escaping Progress) async throws {
        let info = await probe(source)
        if info.audio == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        try await run(
            args: ["-i", source.path, "-filter_complex",
                   "[0:a:0]showwaves=s=1280x720:mode=cline:rate=30:colors=0xFF7A1A:scale=sqrt,format=yuv420p[v]",
                   "-map", "[v]", "-map", "0:a:0"]
                + (try h264Arguments(crf: 23)) + (try audioCodecArguments(for: "MP4", kbps: 192))
                + ["-shortest", "-movflags", "+faststart"],
            output: output, duration: info.duration, progress: progress)
    }

    // MARK: - Video

    func mute(source: URL, output: URL, format: String, progress: @escaping Progress) async throws {
        let info = await probe(source)
        if info.video == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        var args = ["-i", source.path, "-map", "0:v:0", "-c:v", "copy", "-an", "-map_metadata", "0"]
        if format != "MKV" { args += ["-movflags", "+faststart"] }
        try await run(args: args, output: output, duration: info.duration, progress: progress)
    }

    /// `atempo` only accepts 0.5–2.0 per stage, so other factors are chained.
    static func atempoChain(_ factor: Double) -> String {
        var factor = factor
        var stages: [String] = []
        while factor > 2.0 { stages.append("atempo=2.0"); factor /= 2 }
        while factor < 0.5 { stages.append("atempo=0.5"); factor /= 0.5 }
        stages.append("atempo=" + String(format: "%g", factor))  // %g is locale-independent: ffmpeg needs a decimal point
        return stages.joined(separator: ",")
    }

    func changeSpeed(source: URL, output: URL, format: String, factor: Double, progress: @escaping Progress) async throws {
        let info = await probe(source)
        if info.video == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        var args = ["-i", source.path, "-filter:v", "setpts=PTS/\(factor),\(Self.evenScale)", "-map", "0:v:0"]
        if info.audio != nil { args += ["-map", "0:a:0", "-filter:a", Self.atempoChain(factor)] }
        args += try videoCodecArguments(for: format)
        try await run(args: args, output: output, duration: info.duration.map { $0 / factor }, progress: progress)
    }

    /// Full-resolution PNG of the middle frame.
    func snapshot(source: URL, output: URL, progress: @escaping Progress) async throws {
        let info = await probe(source)
        if info.video == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        let at = (info.duration ?? 0) / 2
        try await run(
            args: ["-ss", String(format: "%.3f", at), "-i", source.path, "-map", "0:v:0", "-frames:v", "1", "-update", "1"],
            output: output, duration: nil, progress: progress)
    }

    /// Splits into `parts` equal clips named `<stem> 01.<ext>` inside `directory`.
    func splitEqual(
        source: URL, directory: URL, stem: String, format: String, parts: Int,
        allocator: OutputAllocator, progress: @escaping Progress
    ) async throws {
        let info = await probe(source)
        guard let duration = info.duration, info.video != nil else {
            throw ConversionError.toolFailed(tool: "ffmpeg", message: "Could not read the video duration.")
        }
        let parts = max(parts, 2)
        let length = duration / Double(parts)
        if length < 0.05 { throw ConversionError.toolFailed(tool: "ffmpeg", message: "The video is too short to split.") }
        let ext = NamingRules.fileExtension(for: format)
        for index in 0..<parts {
            try Task.checkCancellation()
            let output = directory.appendingPathComponent("\(stem) \(String(format: "%02d", index + 1)).\(ext)")
            var args = ["-ss", String(format: "%.3f", length * Double(index)), "-i", source.path,
                        "-t", String(format: "%.3f", length), "-map", "0:v:0", "-map", "0:a:0?", "-vf", Self.evenScale]
            args += try videoCodecArguments(for: format)
            if format != "MKV" { args += ["-avoid_negative_ts", "make_zero"] }
            let base = Double(index) / Double(parts)
            try await run(args: args, output: output, duration: length) { progress(base + $0 / Double(parts)) }
        }
    }

    /// Joins clips into one MP4; the first clip sets the canvas, the others are letterboxed.
    func join(sources: [URL], output: URL, progress: @escaping Progress) async throws {
        guard sources.count >= 2 else { throw ConversionError.custom("Select at least two videos to join.") }
        var probes: [MediaProbe] = []
        for source in sources { probes.append(await probe(source)) }
        guard let first = probes[0].video, probes.allSatisfy({ $0.video != nil }) else {
            throw ConversionError.custom("Every selected file must contain a video track.")
        }
        let width = first.width / 2 * 2, height = first.height / 2 * 2
        var args: [String] = []
        for source in sources { args += ["-i", source.path] }
        var silentIndex = sources.count
        var graph = "", concatInputs = ""
        for (k, info) in probes.enumerated() {
            graph += "[\(k):v:0]scale=\(width):\(height):force_original_aspect_ratio=decrease,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p[v\(k)];"
            if info.audio != nil {
                graph += "[\(k):a:0]aformat=sample_rates=48000:channel_layouts=stereo[a\(k)];"
            } else {
                // Silent audio so clips without a sound track still line up.
                args += ["-f", "lavfi", "-t", String(format: "%.3f", info.duration ?? 1), "-i", "anullsrc=r=48000:cl=stereo"]
                graph += "[\(silentIndex):a:0]anull[a\(k)];"
                silentIndex += 1
            }
            concatInputs += "[v\(k)][a\(k)]"
        }
        graph += "\(concatInputs)concat=n=\(sources.count):v=1:a=1[v][a]"
        args += ["-filter_complex", graph, "-map", "[v]", "-map", "[a]"]
        args += try h264Arguments(crf: 20) + (try audioCodecArguments(for: "MP4", kbps: 192)) + ["-movflags", "+faststart"]
        try await run(args: args, output: output, duration: probes.compactMap(\.duration).reduce(0, +), progress: progress)
    }

    // MARK: - Compress

    /// Audio compression: lower bitrate for lossy formats, FLAC for WAV, maximum compression for FLAC.
    func compressAudio(
        source: URL, output: URL, format: String, kbps: Int, progress: @escaping Progress
    ) async throws {
        let info = await probe(source)
        let codec: [String]
        switch format {
        case "WAV": codec = ["-c:a", "flac", "-compression_level", "8"]
        case "FLAC": codec = ["-c:a", "flac", "-compression_level", "12"]
        default: codec = try audioCodecArguments(for: format, kbps: kbps)
        }
        try await run(
            args: ["-i", source.path, "-map", "0:a:0", "-vn", "-map_metadata", "0"] + codec,
            output: output, duration: info.duration, progress: progress)
    }

    /// Video compression with HEVC (VideoToolbox when available), falling back to x264.
    /// `strength` runs 0 (gentle) … 1 (strong).
    func compressVideo(
        source: URL, output: URL, format: String, strength: Double, progress: @escaping Progress
    ) async throws {
        let info = await probe(source)
        if info.video == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        var video: [String]
        if env.hasEncoder("hevc_videotoolbox") {
            video = ["-c:v", "hevc_videotoolbox", "-q:v", String(Int((55 - 20 * strength).rounded()))]
        } else if env.hasEncoder("libx265") {
            video = ["-c:v", "libx265", "-preset", "fast", "-crf", String(Int((26 + 8 * strength).rounded()))]
        } else {
            video = try h264Arguments(crf: Int((24 + 8 * strength).rounded()))
        }
        if !video.contains("-pix_fmt") { video += ["-pix_fmt", "yuv420p"] }
        if format != "MKV", video.contains(where: { $0.contains("hevc") || $0.contains("265") }) { video += ["-tag:v", "hvc1"] }
        var args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", Self.evenScale] + video
        args += try audioCodecArguments(for: "MP4", kbps: strength > 0.5 ? 96 : 128)
        if format != "MKV" { args += ["-movflags", "+faststart"] }
        try await run(args: args, output: output, duration: info.duration, progress: progress)
    }

    // MARK: - Metadata

    /// Strips container and stream metadata without re-encoding.
    func removeMetadata(source: URL, output: URL, format: String, progress: @escaping Progress) async throws {
        let info = await probe(source)
        var args = ["-i", source.path, "-map", "0", "-map_metadata", "-1", "-map_metadata:s", "-1", "-map_chapters", "-1",
                    "-c", "copy", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"]
        if ["MP4", "MOV", "M4A"].contains(format) { args += ["-movflags", "+faststart"] }
        if format == "MP3" { args += ["-write_xing", "0", "-id3v2_version", "0"] }
        try await run(args: args, output: output, duration: info.duration, progress: progress)
    }
}
