import Foundation

/// SRT ⇄ VTT and subtitle → plain text. Parsing and writing rules ported from Satsuma's `subtitle.rs`
/// (MIT, © sonatina-dream).
enum SubtitleEngine {
    struct Cue: Equatable {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    static func decode(_ data: Data) throws -> String {
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        guard let text = String(data: Data(bytes), encoding: .utf8) else {
            throw ConversionError.toolFailed(tool: "subtitles", message: "The subtitle file is not valid UTF-8.")
        }
        return text
    }

    /// "01:02:03,456", "01:02:03.456" or "02:03.456" → milliseconds.
    static func parseTime(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard let separator = s.lastIndex(where: { $0 == "," || $0 == "." }) else { return nil }
        let clock = s[..<separator]
        let fraction = String(s[s.index(after: separator)...].prefix(3))
        guard let ms = Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) else { return nil }
        let parts = clock.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.contains(where: { $0 == nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        let seconds: Int
        switch numbers.count {
        case 3: seconds = numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        case 2: seconds = numbers[0] * 60 + numbers[1]
        default: return nil
        }
        return seconds * 1000 + ms
    }

    static func formatTime(_ ms: Int, separator: Character) -> String {
        let h = ms / 3_600_000, m = (ms % 3_600_000) / 60_000, s = (ms % 60_000) / 1000, milli = ms % 1000
        return String(format: "%02d:%02d:%02d%@%03d", h, m, s, String(separator), milli)
    }

    /// Parses SRT or VTT (both are accepted whatever the file is called).
    static func parse(_ text: String) throws -> [Cue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let halves = lines[timeIndex].components(separatedBy: "-->")
            guard halves.count == 2,
                  let start = parseTime(halves[0]),
                  let endField = halves[1].split(whereSeparator: \.isWhitespace).first,
                  let end = parseTime(String(endField)) else { continue }
            let body = lines[(timeIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { cues.append(Cue(startMs: start, endMs: end, text: body)) }
        }
        guard !cues.isEmpty else {
            throw ConversionError.toolFailed(tool: "subtitles", message: "No valid subtitle cues were found.")
        }
        return cues
    }

    /// Removes markup tags (`<i>`, `<c.yellow>`, `<v Speaker>` …), optionally keeping `<i> <b> <u>`.
    static func stripTags(_ s: String, keepBasic: Bool) -> String {
        var out = ""
        var rest = s[...]
        while let open = rest.firstIndex(of: "<") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: ">") else {
                out += rest[open...]
                return out
            }
            let tag = rest[open...close]
            let name = tag.drop(while: { $0 == "<" || $0 == "/" }).dropLast()
            if keepBasic, ["i", "b", "u"].contains(String(name)) { out += tag }
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }

    static func write(_ cues: [Cue], as format: String) throws -> String {
        var out = ""
        switch format {
        case "SRT":
            for (i, cue) in cues.enumerated() {
                out += "\(i + 1)\n\(formatTime(cue.startMs, separator: ",")) --> \(formatTime(cue.endMs, separator: ","))\n"
                out += stripTags(cue.text, keepBasic: true) + "\n\n"
            }
        case "VTT":
            out += "WEBVTT\n\n"
            for cue in cues {
                out += "\(formatTime(cue.startMs, separator: ".")) --> \(formatTime(cue.endMs, separator: "."))\n\(cue.text)\n\n"
            }
        case "TXT":
            var last = ""
            for cue in cues {
                for raw in stripTags(cue.text, keepBasic: false).components(separatedBy: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty, line != last {
                        out += line + "\n"
                        last = line
                    }
                }
            }
        default:
            throw ConversionError.unsupported(from: "subtitles", to: format)
        }
        return out
    }

    static func convert(source: URL, options: ConversionOptions, allocator: OutputAllocator) throws -> [URL] {
        let cues = try parse(try decode(Data(contentsOf: source)))
        let text = try write(cues, as: options.targetFormat)
        let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: options.targetFormat))
        try text.write(to: output, atomically: false, encoding: .utf8)
        return [output]
    }
}
