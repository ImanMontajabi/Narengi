import AppKit
import CoreGraphics

/// Combines images into one grid picture. Layout choice (a near-square grid, cells sized to the largest
/// picture's short side) follows the behaviour of Satsuma's `image::collage`.
enum CollageEngine {
    /// Columns × rows for `count` pictures: as square as possible, wider than tall.
    static func grid(count: Int) -> (columns: Int, rows: Int) {
        let columns = Int(ceil(sqrt(Double(max(count, 1)))))
        return (columns, Int(ceil(Double(count) / Double(columns))))
    }

    static func make(images: [CGImage], cell: Int = 800, gap: Int = 8) throws -> CGImage {
        guard !images.isEmpty else { throw ConversionError.encodeFailed("PNG") }
        let (columns, rows) = grid(count: images.count)
        let width = columns * cell + (columns + 1) * gap
        let height = rows * cell + (rows + 1) * gap
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.encodeFailed("PNG") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            let slot = CGRect(
                x: gap + column * (cell + gap), y: height - (gap + (row + 1) * cell + row * gap), width: cell, height: cell)
            // Fill the cell: scale to cover, crop the overflow (centred).
            let scale = max(CGFloat(cell) / CGFloat(image.width), CGFloat(cell) / CGFloat(image.height))
            let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.saveGState()
            context.clip(to: slot)
            context.draw(image, in: CGRect(x: slot.midX - drawn.width / 2, y: slot.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed("PNG") }
        return result
    }
}
