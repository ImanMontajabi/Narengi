import CoreGraphics
import Foundation
import ImageIO

/// How hard to compress. `preset` is the Balanced/Strong choice from Settings (used for batches and quick
/// drops); `percentage` is the "Reduce by" slider of the Compress window: the result is at most
/// `original × (1 − percent/100)` where the format allows it.
struct CompressionSpec: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        case preset(strong: Bool)
        case percentage(Double)
    }

    var mode: Mode = .preset(strong: false)
    /// Longest edge for images, from Settings → Formats → Image size.
    var maxEdge: Int?
    /// Fraction of the original dimensions for images (Settings' 75/50/25 % choices).
    var scale: Double?

    var isStrong: Bool {
        switch mode {
        case .preset(let strong): return strong
        case .percentage(let percent): return percent >= 50
        }
    }

    /// Largest output size for a percentage reduction, or nil for presets.
    func targetBytes(original: Int) -> Int? {
        guard case .percentage(let percent) = mode else { return nil }
        return Int(Double(original) * (1 - min(max(percent, 0), 99) / 100))
    }

    /// 0 (gentle) … 1 (strong) for codecs that take a single strength.
    var strength: Double {
        switch mode {
        case .preset(let strong): return strong ? 0.85 : 0.4
        case .percentage(let percent): return min(max(percent / 100, 0), 1)
        }
    }

    @MainActor
    static func fromSettings(format: String, settings: SettingsStore? = nil) -> CompressionSpec {
        let settings = settings ?? .shared
        let options = settings.options(for: format)
        var spec = CompressionSpec(mode: .preset(strong: options.compression == .strong))
        switch options.imageSize {
        case .original: break
        case .percent75: spec.scale = 0.75
        case .percent50: spec.scale = 0.5
        case .percent25: spec.scale = 0.25
        case .max4096: spec.maxEdge = 4096
        case .max2048: spec.maxEdge = 2048
        case .max1080: spec.maxEdge = 1080
        }
        return spec
    }
}

/// Compress for every file kind. Behaviour (HEVC for video, bitrate cuts for audio, FLAC for WAV,
/// JPEG recompression for PDF, quality/palette cuts for images, and refusing a result that is not smaller)
/// is ported from Satsuma's `run.rs`/`image.rs`/`media.rs` (MIT, © sonatina-dream).
struct CompressEngine {
    var availability: Availability

    func compress(
        source: URL, format: String, spec: CompressionSpec, allocator: OutputAllocator,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let extensionFormat = format == "WAV" ? "FLAC" : format
        let output = try allocator.allocateFile(
            for: source, baseName: "\(NamingRules.stem(of: source.lastPathComponent)) Compressed",
            pathExtension: NamingRules.fileExtension(for: extensionFormat))
        let original = ImageOps.fileSize(source)
        switch FormatCatalog.category(of: format)?.id {
        case "images": try await compressImage(source: source, format: format, spec: spec, output: output, original: original)
        case "audio": try await compressAudio(source: source, format: format, spec: spec, output: output, original: original, progress: progress)
        case "video": try await MediaEngine(env: availability.media).compressVideo(
            source: source, output: output, format: format, strength: spec.strength, progress: progress)
        default:
            guard format == "PDF" else { throw ConversionError.custom("This file can't be compressed.") }
            try PDFTools.compress(source: source, output: output, strong: spec.isStrong)
        }
        let after = ImageOps.fileSize(output)
        guard after > 0, after < original else {
            throw ConversionError.custom("Compressing wouldn't make this file smaller, so it was left alone.")
        }
        progress(1)
        return [output]
    }

    // MARK: - Audio

    private func compressAudio(
        source: URL, format: String, spec: CompressionSpec, output: URL, original: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let engine = MediaEngine(env: availability.media)
        guard availability.media.hasFFmpeg else { throw ConversionError.toolMissing("ffmpeg") }
        var kbps: Int
        switch spec.mode {
        case .preset(let strong): kbps = strong ? 96 : 128
        case .percentage(let percent):
            let info = await engine.probe(source)
            let current = Double(original) * 8 / max(info.duration ?? 1, 1) / 1000
            kbps = Int((current * (1 - min(max(percent, 0), 95) / 100)).rounded())
            kbps = min(max(kbps, 32), 320)
        }
        try await engine.compressAudio(source: source, output: output, format: format, kbps: kbps, progress: progress)
    }

    // MARK: - Images

    private func compressImage(source: URL, format: String, spec: CompressionSpec, output: URL, original: Int) async throws {
        var decoded = try ImageEngine.decode(source, dpi: 72, flattenOnWhite: false)
        if let scale = spec.scale { decoded.image = try ImageOps.resize(decoded.image, scale: scale) }
        if let edge = spec.maxEdge { decoded.image = try ImageOps.resize(decoded.image, maxEdge: edge) }
        let target = spec.targetBytes(original: original)

        switch format {
        case "JPG", "HEIC", "AVIF":
            let fixed: Double = format == "JPG" ? (spec.isStrong ? 0.45 : 0.70) : (spec.isStrong ? 0.40 : 0.60)
            try await fit(target: target, fixed: fixed, output: output) { quality in
                try ImageEngine.encode(decoded, format: format, options: Self.options(format, quality), to: output)
            }
        case "WEBP":
            let fixed = spec.isStrong ? 0.45 : 0.70
            try await fit(target: target, fixed: fixed, output: output) { quality in
                let options = Self.options(format, quality)
                if ImageEngine.canEncode("WEBP") {
                    try ImageEngine.encode(decoded, format: "WEBP", options: options, to: output)
                } else {
                    try await ImageEngine(tools: availability.tools).encodeWebPWithTool(decoded, options: options, to: output)
                }
            }
        case "TIFF":
            try Self.writeTIFF(decoded.image, to: output)
        case "PNG":
            try await compressPNG(decoded, spec: spec, target: target, output: output)
        default:
            throw ConversionError.custom("Cannot compress \(format) images.")
        }
    }

    private static func options(_ format: String, _ quality: Double) -> ConversionOptions {
        ConversionOptions(sourceFormat: format, targetFormat: format, quality: quality, preserveMetadata: true)
    }

    /// Encodes once at `fixed` quality, or — with a target size — searches for the best quality that fits.
    private func fit(target: Int?, fixed: Double, output: URL, encode: (Double) async throws -> Void) async throws {
        guard let target else { return try await encode(fixed) }
        var low = 0.05, high = 0.95
        var best: Double?
        for _ in 0..<7 {
            try Task.checkCancellation()
            let middle = (low + high) / 2
            try await encode(middle)
            if ImageOps.fileSize(output) <= target { best = middle; low = middle } else { high = middle }
        }
        // Leave the best fitting encode on disk; if none fit, the lowest quality is the closest we can get.
        try await encode(best ?? 0.05)
    }

    private static func writeTIFF(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil) else {
            throw ConversionError.encodeFailed("TIFF")
        }
        let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]]  // LZW
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed("TIFF") }
    }

    /// PNG: quantise to a palette with ffmpeg (fewer colours until the target fits), else a plain re-encode.
    private func compressPNG(_ decoded: ImageEngine.DecodedImage, spec: CompressionSpec, target: Int?, output: URL) async throws {
        let engine = MediaEngine(env: availability.media)
        guard availability.media.hasFFmpeg else {
            try ImageEngine.encode(decoded, format: "PNG", options: Self.options("PNG", 1), to: output)
            return
        }
        let intermediate = output.deletingLastPathComponent().appendingPathComponent(".narengi-tmp-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        try ImageEngine.encode(decoded, format: "PNG", options: Self.options("PNG", 1), to: intermediate)
        let levels = target == nil ? [spec.isStrong ? 96 : 256] : [256, 128, 64, 32, 16]
        for colors in levels {
            try Task.checkCancellation()
            try await engine.run(
                args: ["-i", intermediate.path, "-filter_complex",
                       "[0:v]split[a][b];[a]palettegen=max_colors=\(colors):reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a:alpha_threshold=128",
                       "-frames:v", "1", "-compression_level", "9"],
                output: output, duration: nil, progress: { _ in })
            if let target, ImageOps.fileSize(output) > target { continue }
            break
        }
    }
}
