import Foundation

/// Audio and video conversions with ffmpeg. The codec choices, the odd-size scale filter, the GIF palette
/// pipeline and the progress handling are ported from Satsuma's `media.rs` (MIT, © sonatina-dream).
struct MediaEngine {
    let env: MediaEnvironment

    init(env: MediaEnvironment = .shared) {
        self.env = env
    }

    /// Keeps H.264/VP9/MPEG-4 happy with odd-sized sources.
    static let evenScale = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// High-quality GIF: 12 fps, at most 640 px wide, a palette generated from the clip itself, dithered.
    static let gifFilter =
        "fps=12,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4"

    // MARK: - Capability

    static let audioFormats: Set<String> = ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF", "WMA"]
    static let videoContainers: Set<String> = ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV"]

    /// Whether this Mac's ffmpeg can do `source → target`.
    func supports(source: String, target: String) -> Bool {
        guard env.hasFFmpeg else { return false }
        if Self.audioFormats.contains(source) {
            return (try? audioCodecArguments(for: target, kbps: 192)) != nil
        }
        if Self.videoContainers.contains(source) || source == "GIF" {
            switch target {
            case "GIF": return true
            case "MP3": return env.hasEncoder("libmp3lame")
            default: return (try? videoCodecArguments(for: target)) != nil
            }
        }
        return false
    }

    // MARK: - Codec arguments

    func audioCodecArguments(for target: String, kbps: Int) throws -> [String] {
        let bitrate = "\(kbps)k"
        switch target {
        case "MP3":
            guard env.hasEncoder("libmp3lame") else { throw ConversionError.encoderMissing("MP3") }
            return ["-c:a", "libmp3lame", "-b:a", bitrate]
        case "M4A", "MP4", "MOV", "MKV":
            guard let encoder = env.pickEncoder(["aac", "aac_at"]) else { throw ConversionError.encoderMissing("AAC") }
            return ["-c:a", encoder, "-b:a", bitrate]
        case "WAV": return ["-c:a", "pcm_s16le"]
        case "AIFF": return ["-c:a", "pcm_s16be"]
        case "FLAC": return ["-c:a", "flac", "-compression_level", "8"]
        case "OGG":
            switch env.pickEncoder(["libvorbis", "vorbis"]) {
            case "libvorbis": return ["-c:a", "libvorbis", "-q:a", "6"]
            case "vorbis": return ["-c:a", "vorbis", "-strict", "experimental", "-ac", "2"]
            default: throw ConversionError.encoderMissing("Ogg Vorbis")
            }
        case "OPUS", "WEBM":
            switch env.pickEncoder(["libopus", "opus"]) {
            case "libopus": return ["-c:a", "libopus", "-b:a", bitrate]
            case "opus": return ["-c:a", "opus", "-strict", "experimental", "-ar", "48000", "-b:a", bitrate]
            default: throw ConversionError.encoderMissing("Opus")
            }
        case "WMA", "WMV":
            guard env.hasEncoder("wmav2") else { throw ConversionError.encoderMissing("WMA") }
            return ["-c:a", "wmav2", "-b:a", bitrate]
        case "AVI":
            return env.hasEncoder("libmp3lame")
                ? ["-c:a", "libmp3lame", "-b:a", bitrate]
                : ["-c:a", "pcm_s16le"]
        default:
            throw ConversionError.unsupported(from: "audio", to: target)
        }
    }

    func h264Arguments(crf: Int) throws -> [String] {
        if env.hasEncoder("libx264") {
            return ["-c:v", "libx264", "-preset", "veryfast", "-crf", String(crf), "-pix_fmt", "yuv420p"]
        }
        if env.hasEncoder("h264_videotoolbox") {
            return ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
        }
        throw ConversionError.encoderMissing("H.264 video")
    }

    /// Video (and audio) encoder arguments for a video container.
    func videoCodecArguments(for target: String) throws -> [String] {
        var args: [String] = []
        switch target {
        case "MP4", "MOV", "MKV":
            args += try h264Arguments(crf: 20)
            args += try audioCodecArguments(for: target, kbps: 192)
            if target != "MKV" { args += ["-movflags", "+faststart"] }
        case "WEBM":
            guard env.hasEncoder("libvpx-vp9") else { throw ConversionError.encoderMissing("VP9 video") }
            args += ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good",
                     "-cpu-used", "4", "-pix_fmt", "yuv420p"]
            args += try audioCodecArguments(for: "WEBM", kbps: 128)
        case "AVI":
            args += ["-c:v", "mpeg4", "-q:v", "3", "-vtag", "xvid"]
            args += try audioCodecArguments(for: "AVI", kbps: 192)
        case "WMV":
            guard env.hasEncoder("wmv2") else { throw ConversionError.encoderMissing("WMV video") }
            args += ["-c:v", "wmv2", "-b:v", "5M"]
            args += try audioCodecArguments(for: "WMV", kbps: 192)
        default:
            throw ConversionError.unsupported(from: "video", to: target)
        }
        return args
    }

    // MARK: - Running ffmpeg

    func probe(_ url: URL) async -> MediaProbe {
        guard let ffmpeg = env.ffmpeg,
              let output = try? await ProcessRunner.capture(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-i", url.path])
        else { return MediaProbe() }
        return MediaProbe.parse(output.standardError)
    }

    /// Runs ffmpeg with `args` writing to `output`, reporting progress from `-progress pipe:1`.
    func run(args: [String], output: URL, duration: Double?, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let ffmpeg = env.ffmpeg else { throw ConversionError.toolMissing("ffmpeg") }
        let arguments = ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]
            + args + [output.path]
        try await ProcessRunner.run(ffmpeg, arguments: arguments, tool: "ffmpeg") { line in
            if let fraction = MediaProbe.progressFraction(line: line, duration: duration) { progress(fraction) }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
        guard size > 0 else { throw ConversionError.toolFailed(tool: "ffmpeg", message: "no output file was written") }
    }

    // MARK: - Conversions

    /// audio → audio
    func convertAudio(source: URL, output: URL, target: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = await probe(source)
        if info.duration == nil, info.audio == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        try await run(
            args: ["-i", source.path, "-map", "0:a:0", "-vn", "-map_metadata", "0"]
                + (try audioCodecArguments(for: target, kbps: 192)),
            output: output, duration: info.duration, progress: progress)
    }

    /// video or GIF → video, GIF or MP3
    func convertVideo(source: URL, output: URL, target: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = await probe(source)
        if info.duration == nil, info.video == nil, info.audio == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }

        let args: [String]
        switch target {
        case "GIF":
            args = ["-i", source.path, "-map", "0:v:0", "-an", "-vf", Self.gifFilter, "-loop", "0"]
        case "MP3":
            if info.audio == nil { throw ConversionError.toolFailed(tool: "ffmpeg", message: "This video has no audio track.") }
            args = ["-i", source.path, "-map", "0:a:0", "-vn"] + (try audioCodecArguments(for: "MP3", kbps: 192))
        default:
            args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", Self.evenScale]
                + (try videoCodecArguments(for: target))
        }
        try await run(args: args, output: output, duration: info.duration, progress: progress)
    }

    func convert(
        source: URL, options: ConversionOptions, allocator: OutputAllocator,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        guard env.hasFFmpeg else { throw ConversionError.toolMissing("ffmpeg") }
        guard supports(source: options.sourceFormat, target: options.targetFormat) else {
            throw ConversionError.unsupported(from: options.sourceFormat, to: options.targetFormat)
        }
        let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: options.targetFormat))
        if Self.audioFormats.contains(options.sourceFormat) {
            try await convertAudio(source: source, output: output, target: options.targetFormat, progress: progress)
        } else {
            try await convertVideo(source: source, output: output, target: options.targetFormat, progress: progress)
        }
        progress(1)
        return [output]
    }
}
