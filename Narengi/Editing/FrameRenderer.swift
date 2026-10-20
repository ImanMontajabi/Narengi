import CoreGraphics
import Foundation

/// Add Background: the photo on a gradient, colour or picture, with padding, rounded corners and a shadow.
enum FrameRenderer {
    static func render(_ image: CGImage, spec: FrameSpec, backgroundImage: CGImage? = nil) throws -> CGImage {
        let imageSize = CGSize(width: image.width, height: image.height)
        let (canvas, photo) = FrameSpec.layout(image: imageSize, padding: spec.padding, ratio: spec.ratio)
        let context = try ImageOps.makeContext(width: Int(canvas.width), height: Int(canvas.height))
        let full = CGRect(origin: .zero, size: canvas)

        switch spec.background {
        case .solid(let color):
            context.setFillColor(color.cgColor)
            context.fill(full)
        case .gradient(let index):
            let preset = FrameSpec.gradients[min(max(index, 0), FrameSpec.gradients.count - 1)]
            let colors = preset.stops.map(\.cgColor) as CFArray
            if let gradient = CGGradient(colorsSpace: ImageOps.sRGB, colors: colors, locations: [0, 0.5, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [.drawsAfterEndLocation, .drawsBeforeStartLocation])
            }
        case .image:
            if let backgroundImage {
                // Aspect-fill, centred.
                let scale = max(canvas.width / CGFloat(backgroundImage.width), canvas.height / CGFloat(backgroundImage.height))
                let size = CGSize(width: CGFloat(backgroundImage.width) * scale, height: CGFloat(backgroundImage.height) * scale)
                context.draw(backgroundImage, in: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2, width: size.width, height: size.height))
            } else {
                context.setFillColor(CGColor(gray: 0.9, alpha: 1))
                context.fill(full)
            }
        }

        // `photo` has a top-left origin; CoreGraphics draws from the bottom-left.
        let target = CGRect(x: photo.minX, y: canvas.height - photo.maxY, width: photo.width, height: photo.height)
        let radius = min(max(spec.corners, 0), min(target.width, target.height) / 2)
        let path = CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if spec.shadow > 0 {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -spec.shadow * 0.35), blur: spec.shadow, color: CGColor(gray: 0, alpha: 0.4))
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.draw(image, in: target)
        context.restoreGState()

        guard let result = context.makeImage() else { throw ConversionError.encodeFailed("PNG") }
        return result
    }
}
