import Foundation

/// What the installed ffmpeg can do. Ported from Satsuma's `env.rs`/`probe.rs` (MIT, © sonatina-dream).
struct MediaEnvironment: Sendable {
    let ffmpeg: URL?
    let encoders: Set<String>

    var hasFFmpeg: Bool { ffmpeg != nil }

    func hasEncoder(_ name: String) -> Bool { ffmpeg != nil && encoders.contains(name) }

    /// The first encoder of `names` this ffmpeg has.
    func pickEncoder(_ names: [String]) -> String? { names.first(where: hasEncoder) }

    static let none = MediaEnvironment(ffmpeg: nil, encoders: [])

    /// Discovered once per launch; running `ffmpeg -encoders` is cheap but not free.
    static let shared: MediaEnvironment = discover(BundledToolLocator.shared)

    static func discover(_ locator: BundledToolLocator) -> MediaEnvironment {
        guard let ffmpeg = locator.locate(.ffmpeg) else { return .none }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        process.qualityOfService = .userInitiated  // this call blocks its caller, which may be a high-priority thread
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return MediaEnvironment(ffmpeg: ffmpeg, encoders: []) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return MediaEnvironment(ffmpeg: ffmpeg, encoders: parseEncoders(String(decoding: data, as: UTF8.self)))
    }

    /// Parses `ffmpeg -encoders` (" A....D libmp3lame  libmp3lame MP3 …").
    static func parseEncoders(_ text: String) -> Set<String> {
        var set = Set<String>()
        var pastHeader = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("------") { pastHeader = true; continue }
            guard pastHeader else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].count == 6 { set.insert(String(parts[1])) }
        }
        return set
    }
}

/// Facts read from `ffmpeg -i` output (no ffprobe needed).
struct MediaProbe: Equatable {
    struct Audio: Equatable {
        var sampleRate: Int
        var channels: Int
    }

    var duration: Double?
    /// Size of the first real video stream (cover art excluded).
    var video: (width: Int, height: Int)?
    var audio: Audio?

    static func == (l: MediaProbe, r: MediaProbe) -> Bool {
        l.duration == r.duration && l.audio == r.audio && l.video?.width == r.video?.width && l.video?.height == r.video?.height
    }

    static func parse(_ text: String) -> MediaProbe {
        var probe = MediaProbe()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Duration:") {
                let field = line.dropFirst("Duration:".count).split(separator: ",").first.map(String.init) ?? ""
                probe.duration = parseClock(field.trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("Stream #") {
                if line.contains("Video:"), probe.video == nil, !line.contains("attached pic") {
                    probe.video = parseDimensions(line)
                } else if line.contains("Audio:"), probe.audio == nil {
                    probe.audio = parseAudio(line)
                }
            }
        }
        return probe
    }

    /// "00:01:02.50" → 62.5
    static func parseClock(_ t: String) -> Double? {
        let parts = t.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private static func parseDimensions(_ line: String) -> (width: Int, height: Int)? {
        guard let after = line.components(separatedBy: "Video:").dropFirst().first else { return nil }
        for token in after.split(whereSeparator: { " ,[".contains($0) }) {
            let pieces = token.split(separator: "x")
            guard pieces.count == 2, !pieces[0].hasPrefix("0"), let w = Int(pieces[0]), let h = Int(pieces[1]), w > 0, h > 0 else { continue }
            return (w, h)  // hex values such as 0x31637661 start with 0 and are skipped above
        }
        return nil
    }

    private static func parseAudio(_ line: String) -> Audio {
        let after = line.components(separatedBy: "Audio:").dropFirst().first ?? ""
        let fields = after.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let rate = fields.compactMap { f -> Int? in
            f.hasSuffix(" Hz") ? Int(f.dropLast(3).trimmingCharacters(in: .whitespaces)) : nil
        }.first ?? 48_000
        let channels = fields.compactMap { f -> Int? in
            let name = f.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? f
            switch name {
            case "mono": return 1
            case "stereo": return 2
            case "2.1": return 3
            case "quad", "4.0": return 4
            case "5.0": return 5
            case "5.1", "5.1(side)": return 6
            case "6.1": return 7
            case "7.1": return 8
            default: return name.hasSuffix(" channels") ? Int(name.dropLast(9).trimmingCharacters(in: .whitespaces)) : nil
            }
        }.first ?? 2
        return Audio(sampleRate: rate, channels: channels)
    }

    /// Fraction done from an ffmpeg `-progress` line, given the total duration.
    static func progressFraction(line: String, duration: Double?) -> Double? {
        guard let duration, duration > 0 else { return nil }
        let value: Substring
        if line.hasPrefix("out_time_us=") { value = line.dropFirst("out_time_us=".count) }
        else if line.hasPrefix("out_time_ms=") { value = line.dropFirst("out_time_ms=".count) }
        else { return nil }
        guard let micros = Double(value.trimmingCharacters(in: .whitespaces)) else { return nil }
        return min(1, max(0, micros / 1_000_000 / duration))
    }
}
