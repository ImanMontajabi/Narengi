import CoreGraphics
import Foundation
import ImageIO

/// A box to cover in a video, as fractions of the frame (0…1, top-left origin).
struct VideoRedaction: Equatable, Sendable {
    enum Style: String, Sendable { case blackout, pixelate, blur }
    var rect: CGRect
    var style: Style
}

/// A stretch of audio to replace with a bleep, in seconds.
struct BleepInterval: Equatable, Sendable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double

    var length: Double { end - start }
}

/// Trim, Crop, Redact (video) and Bleep (audio). Re-encoding uses the same codec choices as conversions
/// (VideoToolbox/x264 + AAC) so cuts are frame-accurate and never start with black frames.
extension MediaEngine {
    // MARK: - Previews

    /// One frame at `seconds`, scaled to fit `maxEdge`, for the editors' preview.
    func frame(of source: URL, at seconds: Double, maxEdge: Int = 1280) async throws -> CGImage {
        guard let ffmpeg = env.ffmpeg else { throw ConversionError.toolMissing("ffmpeg") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("narengi-frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProcessRunner.run(
            ffmpeg,
            arguments: ["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-ss", String(format: "%.3f", max(seconds, 0)), "-i", source.path,
                        "-frames:v", "1", "-vf", "scale='min(\(maxEdge),iw)':-2", url.path],
            tool: "ffmpeg")
        // Decode from memory: an image source reads lazily, and the temp file is deleted when we return.
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let data = try? Data(contentsOf: url), let image = CGImageSourceCreateWithData(data as CFData, options)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, options) }) else {
            throw ConversionError.decodeFailed(source.lastPathComponent)
        }
        return image
    }

    /// Peak level (0…1) of `bins` equal slices of the audio, for the waveform.
    func waveform(of source: URL, bins: Int = 400) async throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("narengi-wave-\(UUID().uuidString).raw")
        defer { try? FileManager.default.removeItem(at: url) }
        try await run(args: ["-i", source.path, "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le"], output: url, duration: nil) { _ in }
        return Self.peaks(of: try Data(contentsOf: url), bins: bins)
    }

    /// Signed 16-bit little-endian mono samples → `bins` peak values.
    static func peaks(of data: Data, bins: Int) -> [Float] {
        let count = data.count / 2
        guard count > 0, bins > 0 else { return [] }
        var result = [Float](repeating: 0, count: bins)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let bin = min(i * bins / count, bins - 1)
                result[bin] = max(result[bin], abs(Float(Int16(littleEndian: samples[i]))) / 32768)
            }
        }
        return result
    }

    // MARK: - Trim

    /// Keeps `start`…`end` seconds, re-encoded for an exact cut.
    func trim(source: URL, output: URL, format: String, start: Double, end: Double, progress: @escaping Progress) async throws {
        let info = await probe(source)
        if info.video == nil { throw ConversionError.decodeFailed(source.lastPathComponent) }
        guard end - start >= 0.05 else { throw ConversionError.custom("Pick a longer stretch to keep.") }
        let length = min(end, info.duration ?? end) - start
        var args = ["-ss", String(format: "%.3f", start), "-i", source.path, "-t", String(format: "%.3f", length),
                    "-map", "0:v:0", "-map", "0:a:0?", "-vf", Self.evenScale]
        args += try videoCodecArguments(for: format)
        if format != "MKV" { args += ["-avoid_negative_ts", "make_zero"] }
        try await run(args: args, output: output, duration: length, progress: progress)
    }

    // MARK: - Crop

    /// Even-sized pixel rectangle for a fractional crop (H.264 needs even dimensions).
    static func croppedRect(_ spec: CropSpec, video: (width: Int, height: Int)) -> (w: Int, h: Int, x: Int, y: Int) {
        let r = spec.pixels(in: CGSize(width: video.width, height: video.height))
        let w = max(2, Int(r.width) & ~1), h = max(2, Int(r.height) & ~1)
        let x = min(Int(r.minX), video.width - w), y = min(Int(r.minY), video.height - h)
        return (w, h, max(x, 0), max(y, 0))
    }

    func crop(source: URL, output: URL, format: String, spec: CropSpec, progress: @escaping Progress) async throws {
        let info = await probe(source)
        guard let size = info.video else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        let box = Self.croppedRect(spec, video: size)
        var args = ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0?", "-vf", "crop=\(box.w):\(box.h):\(box.x):\(box.y)"]
        args += try videoCodecArguments(for: format)
        try await run(args: args, output: output, duration: info.duration, progress: progress)
    }

    // MARK: - Redact

    /// The filter graph that covers `regions` (optionally only between `start` and `end` seconds).
    static func redactionGraph(
        regions: [VideoRedaction], video: (width: Int, height: Int), start: Double?, end: Double?
    ) -> String {
        let enable: String = {
            switch (start, end) {
            case (nil, nil): return ""
            case (let s?, nil): return ":enable='gte(t,\(String(format: "%.3f", s)))'"
            case (nil, let e?): return ":enable='lte(t,\(String(format: "%.3f", e)))'"
            case (let s?, let e?): return ":enable='between(t,\(String(format: "%.3f", s)),\(String(format: "%.3f", e)))'"
            }
        }()
        var stages: [String] = []
        var current = "[0:v]"
        for (i, region) in regions.enumerated() {
            let r = CGRect(x: region.rect.minX * Double(video.width), y: region.rect.minY * Double(video.height),
                           width: region.rect.width * Double(video.width), height: region.rect.height * Double(video.height))
            let x = max(0, Int(r.minX) & ~1), y = max(0, Int(r.minY) & ~1)
            let w = max(2, min(Int(r.width.rounded(.up)) + 1, video.width - x) & ~1)
            let h = max(2, min(Int(r.height.rounded(.up)) + 1, video.height - y) & ~1)
            let next = "[r\(i)]"
            switch region.style {
            case .blackout:
                stages.append("\(current)drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black@1:t=fill\(enable)\(next)")
            case .blur, .pixelate:
                let effect: String
                if region.style == .blur {
                    effect = "boxblur=\(max(2, min(w, h) / 6)):2"
                } else {
                    let cell = max(8, min(w, h) / 8)
                    effect = "scale=max(2\\,\(w / cell)):max(2\\,\(h / cell)),scale=\(w):\(h):flags=neighbor"
                }
                stages.append("\(current)split[m\(i)][s\(i)]")
                stages.append("[s\(i)]crop=\(w):\(h):\(x):\(y),\(effect)[c\(i)]")
                stages.append("[m\(i)][c\(i)]overlay=\(x):\(y)\(enable)\(next)")
            }
            current = next
        }
        stages.append("\(current)\(evenScale)[out]")
        return stages.joined(separator: ";")
    }

    func redact(
        source: URL, output: URL, format: String, regions: [VideoRedaction], start: Double?, end: Double?,
        progress: @escaping Progress
    ) async throws {
        let info = await probe(source)
        guard let size = info.video else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        guard !regions.isEmpty else { throw ConversionError.custom("Draw at least one area to cover.") }
        var args = ["-i", source.path, "-filter_complex", Self.redactionGraph(regions: regions, video: size, start: start, end: end),
                    "-map", "[out]", "-map", "0:a:0?", "-map_metadata", "-1", "-map_chapters", "-1"]
        args += try videoCodecArguments(for: format)
        try await run(args: args, output: output, duration: info.duration, progress: progress)
    }

    // MARK: - Bleep

    /// Intervals sorted, clamped to `duration`, with overlaps merged.
    static func normalized(_ intervals: [BleepInterval], duration: Double?) -> [BleepInterval] {
        let limit = duration ?? .greatestFiniteMagnitude
        let clean = intervals.compactMap { i -> BleepInterval? in
            let start = max(0, min(i.start, i.end)), end = min(max(i.start, i.end), limit)
            return end - start >= 0.02 ? BleepInterval(id: i.id, start: start, end: end) : nil
        }.sorted { $0.start < $1.start }
        var merged: [BleepInterval] = []
        for i in clean {
            if var last = merged.last, i.start <= last.end {
                last.end = max(last.end, i.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(i)
            }
        }
        return merged
    }

    /// `between(t,a,b)+between(t,c,d)…`, true while any interval is active.
    static func bleepCondition(_ intervals: [BleepInterval]) -> String {
        intervals.map { String(format: "between(t,%.3f,%.3f)", $0.start, $0.end) }.joined(separator: "+")
    }

    /// ffmpeg's `sine` source peaks at 0.125; this gain brings the bleep to a clear 0.35.
    /// Replaces the audio inside each interval with a 1 kHz tone; video (if any) is copied untouched.
    func bleep(
        source: URL, output: URL, format: String, intervals: [BleepInterval], progress: @escaping Progress
    ) async throws {
        let info = await probe(source)
        guard let audio = info.audio else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        let list = Self.normalized(intervals, duration: info.duration)
        guard !list.isEmpty else { throw ConversionError.custom("Add at least one stretch to bleep.") }
        let condition = Self.bleepCondition(list)
        let layout = audio.channels == 1 ? "mono" : "stereo"
        let rate = audio.sampleRate
        let graph = "[0:a]aformat=sample_rates=\(rate):channel_layouts=\(layout),volume=0:enable='\(condition)'[o];"
            + "[1:a]aformat=sample_rates=\(rate):channel_layouts=\(layout),volume=2.8:enable='\(condition)',"
            + "volume=0:enable='not(\(condition))'[t];"
            + "[o][t]amix=inputs=2:duration=first:normalize=0[out]"
        let hasVideo = info.video != nil
        var args = ["-i", source.path, "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=\(rate)", "-filter_complex", graph]
        args += hasVideo ? ["-map", "0:v:0", "-c:v", "copy"] : ["-vn"]
        args += ["-map", "[out]", "-map_metadata", "0"]
        args += try audioCodecArguments(for: hasVideo ? (format == "MKV" ? "MKV" : "MP4") : format, kbps: 192)
        if hasVideo, format != "MKV" { args += ["-movflags", "+faststart"] }
        args += ["-shortest"]
        try await run(args: args, output: output, duration: info.duration, progress: progress)
    }
}
