import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image → image / PDF conversion on top of ImageIO. WebP uses ImageIO when the OS can encode it,
/// otherwise the `cwebp` helper.
struct ImageEngine {
    var tools: BundledToolLocator = .shared

    /// Output formats the engine can write (a superset of what the wheel offers).
    static let writableFormats = ["JPG", "PNG", "TIFF", "BMP", "HEIC", "AVIF", "GIF", "ICNS", "WEBP", "PDF"]

    private static func identifier(for format: String) -> String? {
        switch format {
        case "JPG": return "public.jpeg"
        case "PNG": return "public.png"
        case "TIFF": return "public.tiff"
        case "BMP": return "com.microsoft.bmp"
        case "HEIC": return "public.heic"
        case "AVIF": return "public.avif"
        case "GIF": return "com.compuserve.gif"
        case "ICNS": return "com.apple.icns"
        case "WEBP": return "org.webmproject.webp"
        default: return nil
        }
    }

    static func canEncode(_ format: String) -> Bool {
        guard let id = identifier(for: format) else { return false }
        let supported = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return supported.contains(id)
    }

    // MARK: - Conversion

    func convert(
        source: URL,
        options: ConversionOptions,
        allocator: OutputAllocator,
        progress: @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let target = options.targetFormat
        if Self.textFormats.contains(target) {
            return try await recognizeText(source: source, options: options, allocator: allocator, progress: progress)
        }
        guard target == "PDF" || Self.identifier(for: target) != nil else {
            throw ConversionError.unsupported(from: options.sourceFormat, to: target)
        }

        let decoded = try Self.decode(source, dpi: options.dpi, flattenOnWhite: false)
        progress(0.25)
        try Task.checkCancellation()

        let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: target))

        switch target {
        case "PDF":
            try PDFEngine.makePDF(from: [(decoded.image, decoded.dpi)], to: output)

        case "WEBP" where !Self.canEncode("WEBP"):
            try await encodeWebPWithTool(decoded, options: options, to: output)

        default:
            try Self.encode(decoded, format: target, options: options, to: output)
        }
        progress(1)
        return [output]
    }

    // MARK: - Text recognition (image → DOCX / TXT / MD)

    /// Targets produced from recognised text rather than pixels.
    static let textFormats: Set<String> = ["DOCX", "TXT", "MD"]

    /// Reads the text in the picture with Vision. An image without text still becomes a DOCX holding the picture.
    private func recognizeText(
        source: URL, options: ConversionOptions, allocator: OutputAllocator,
        progress: @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let decoded = try Self.decode(source, dpi: options.dpi, flattenOnWhite: true)
        progress(0.2)
        try Task.checkCancellation()
        let paragraphs = OCREngine.paragraphs(try await OCREngine.recognizeAsync(decoded.image))
        progress(0.8)

        let target = options.targetFormat
        let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: target))
        switch target {
        case "DOCX":
            if paragraphs.isEmpty {
                guard let png = Self.pngData(decoded.image) else { throw ConversionError.encodeFailed("DOCX") }
                try DOCXWriter.write(to: output, paragraphs: [],
                                     picture: .init(png: png, widthPx: decoded.image.width, heightPx: decoded.image.height))
            } else {
                try DOCXWriter.write(to: output, paragraphs: paragraphs)
            }
        case "TXT":
            guard !paragraphs.isEmpty else { throw ConversionError.noText }
            try (paragraphs.joined(separator: "\n\n") + "\n").write(to: output, atomically: false, encoding: .utf8)
        default:
            guard !paragraphs.isEmpty else { throw ConversionError.noText }
            try HTML.textToMarkdown(paragraphs.joined(separator: "\n\n")).write(to: output, atomically: false, encoding: .utf8)
        }
        progress(1)
        return [output]
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: - Decoding

    struct DecodedImage {
        var image: CGImage
        var dpi: Double
        /// EXIF/GPS/TIFF/IPTC from the source, with orientation already applied to the pixels.
        var metadata: [CFString: Any]
    }

    static func decode(_ url: URL, dpi renderDPI: Int, flattenOnWhite: Bool) throws -> DecodedImage {
        if url.pathExtension.lowercased() == "svg" {
            let image = try SVGRasterizer.render(url, dpi: renderDPI)
            return DecodedImage(image: image, dpi: 72, metadata: [:])
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.decodeFailed(url.lastPathComponent)
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0

        // The thumbnail path applies EXIF orientation to the pixels, so we never write a stale rotation tag.
        let decodeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.decodeFailed(url.lastPathComponent)
        }

        var metadata: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary] {
            if var dictionary = properties[key] as? [CFString: Any] {
                dictionary[kCGImagePropertyTIFFOrientation] = nil
                dictionary[kCGImagePropertyExifPixelXDimension] = nil
                dictionary[kCGImagePropertyExifPixelYDimension] = nil
                metadata[key] = dictionary
            }
        }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let result = DecodedImage(image: image, dpi: dpi, metadata: metadata)
        return flattenOnWhite ? DecodedImage(image: flatten(image), dpi: dpi, metadata: metadata) : result
    }

    // MARK: - Encoding

    static func encode(_ decoded: DecodedImage, format: String, options: ConversionOptions, to url: URL) throws {
        guard let id = identifier(for: format), canEncode(format) else {
            throw ConversionError.encodeFailed(format)
        }
        var image = decoded.image
        if !formatSupportsAlpha(format), hasAlpha(image) { image = flatten(image) }
        if format == "ICNS" { image = squareIconCanvas(image) }

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, id as CFString, 1, nil) else {
            throw ConversionError.encodeFailed(format)
        }
        var properties: [CFString: Any] = [:]
        if ["JPG", "HEIC", "AVIF", "WEBP"].contains(format) {
            properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        }
        if options.preserveMetadata {
            decoded.metadata.forEach { properties[$0.key] = $0.value }
        }
        properties[kCGImagePropertyDPIWidth] = decoded.dpi
        properties[kCGImagePropertyDPIHeight] = decoded.dpi

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed(format) }
    }

    func encodeWebPWithTool(_ decoded: DecodedImage, options: ConversionOptions, to output: URL) async throws {
        let cwebp = try tools.require(.cwebp)
        // cwebp can't read most formats, so hand it a lossless PNG intermediate.
        let intermediate = FileManager.default.temporaryDirectory
            .appendingPathComponent("narengi-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        var pngOptions = options
        pngOptions.preserveMetadata = false
        try Self.encode(decoded, format: "PNG", options: pngOptions, to: intermediate)

        let quality = String(Int((options.quality * 100).rounded()))
        try await ProcessRunner.run(
            cwebp,
            arguments: ["-quiet", "-q", quality, "-m", "4", "-alpha_q", "100", intermediate.path, "-o", output.path],
            tool: "cwebp")
    }

    // MARK: - Pixel helpers

    static func formatSupportsAlpha(_ format: String) -> Bool {
        !["JPG", "BMP"].contains(format)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Composites onto white, for formats without transparency.
    static func flatten(_ image: CGImage) -> CGImage {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    /// ICNS only stores specific square sizes, so fit the image onto the nearest one.
    private static func squareIconCanvas(_ image: CGImage) -> CGImage {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        let longest = max(image.width, image.height)
        let side = sizes.first { $0 >= longest } ?? 1024
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        let scale = min(1, Double(side) / Double(longest))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        return context.makeImage() ?? image
    }
}

/// Renders SVG through AppKit's built-in SVG support.
enum SVGRasterizer {
    static func render(_ url: URL, dpi: Int) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw ConversionError.decodeFailed(url.lastPathComponent)
        }
        let longest = max(image.size.width, image.size.height)
        // Scale up to the requested DPI, and never leave small icons tiny.
        var scale = max(Double(dpi) / 72, 1024 / Double(longest))
        scale = min(scale, 8192 / Double(longest))
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw ConversionError.decodeFailed(url.lastPathComponent) }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let cgImage = bitmap.cgImage else { throw ConversionError.decodeFailed(url.lastPathComponent) }
        return cgImage
    }
}
