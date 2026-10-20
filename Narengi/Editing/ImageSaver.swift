import CoreGraphics
import Foundation

/// Writes an edited picture in its original format (or PNG), going through cwebp for WebP when ImageIO can't.
enum ImageSaver {
    /// Quality for edited lossy pictures: high, because the user chose to edit, not to shrink.
    static let editQuality = 0.92

    static func save(
        _ image: CGImage, format: String, to url: URL, preserving metadata: [CFString: Any] = [:], dpi: Double = 72,
        availability: Availability
    ) async throws {
        let decoded = ImageEngine.DecodedImage(image: image, dpi: dpi, metadata: metadata)
        let options = ConversionOptions(sourceFormat: format, targetFormat: format, quality: editQuality, preserveMetadata: !metadata.isEmpty)
        if format == "WEBP", !ImageEngine.canEncode("WEBP") {
            try await ImageEngine(tools: availability.tools).encodeWebPWithTool(decoded, options: options, to: url)
        } else {
            try ImageEngine.encode(decoded, format: format, options: options, to: url)
        }
    }
}
