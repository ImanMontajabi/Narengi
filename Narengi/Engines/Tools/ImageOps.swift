import CoreGraphics
import Foundation

/// Small CoreGraphics helpers shared by the image tools.
enum ImageOps {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A transparent RGBA bitmap context, `top-left` flipping left to callers.
    static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.encodeFailed("image") }
        context.interpolationQuality = .high
        return context
    }

    /// Scales to fit within `maxEdge` px on the long side (never enlarges).
    static func resize(_ image: CGImage, maxEdge: Int) throws -> CGImage {
        let long = max(image.width, image.height)
        guard maxEdge > 0, long > maxEdge else { return image }
        return try resize(image, scale: Double(maxEdge) / Double(long))
    }

    static func resize(_ image: CGImage, scale: Double) throws -> CGImage {
        guard scale < 1 else { return image }
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        let context = try makeContext(width: width, height: height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed("image") }
        return result
    }

    /// Crops to `rect` (pixels, top-left origin), optionally scaling the result to an exact size.
    static func crop(_ image: CGImage, to rect: CGRect, output: (width: Int, height: Int)? = nil) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isEmpty, let cropped = image.cropping(to: clipped) else { throw ConversionError.encodeFailed("image") }
        guard let output, output.width > 0, output.height > 0, (output.width, output.height) != (cropped.width, cropped.height) else {
            return cropped
        }
        let context = try makeContext(width: output.width, height: output.height)
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
        return context.makeImage() ?? cropped
    }

    /// Size in bytes of a file, 0 if it doesn't exist.
    static func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
