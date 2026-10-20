import Foundation

/// Everything an engine needs from Settings, captured as a plain value so it can cross threads.
struct ConversionOptions: Sendable, Equatable {
    var sourceFormat: String
    var targetFormat: String
    /// Lossy encoder quality, 0…1 (JPG, HEIC, AVIF, WebP).
    var quality: Double = 0.8
    var preserveMetadata = true
    /// Resolution used when rasterizing vector input (PDF pages, SVG).
    var dpi: Int = 150

    static func qualityValue(_ level: QualityLevel) -> Double {
        switch level {
        case .low: return 0.55
        case .balanced: return 0.8
        case .high: return 0.95
        }
    }

    /// Quality and metadata come from the *output* format's settings; DPI from the *input* format's.
    @MainActor
    static func make(source: String, target: String, settings: SettingsStore? = nil) -> ConversionOptions {
        let settings = settings ?? .shared
        let targetOptions = settings.options(for: target)
        let sourceOptions = settings.options(for: source)
        return ConversionOptions(
            sourceFormat: source,
            targetFormat: target,
            quality: qualityValue(targetOptions.quality),
            preserveMetadata: targetOptions.preserveMetadata,
            dpi: sourceOptions.dpi)
    }
}
