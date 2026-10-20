import AppKit
import CoreGraphics
import CoreImage
import PDFKit

/// One drawn mark in the Annotate and Redact windows. Coordinates are fractions of the page or image
/// (0…1, origin top-left), so the same marks apply at preview size and at full resolution.
struct MarkupItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable, CaseIterable {
        case rectangle, ellipse, arrow, pen, text
        case blackout, blur, pixelate

        var isRedaction: Bool { self == .blackout || self == .blur || self == .pixelate }
    }

    let id = UUID()
    var kind: Kind
    /// Rectangle/ellipse/redaction: two opposite corners. Arrow: tail then head. Pen: the path. Text: the anchor.
    var points: [CGPoint]
    var color = RGB(255, 59, 48)
    /// Stroke width as a fraction of the shorter side.
    var width = 0.006
    var text = ""
    /// Text height as a fraction of the shorter side.
    var fontSize = 0.045

    var isRedaction: Bool { kind.isRedaction }

    /// The box spanned by the first two points.
    var box: CGRect {
        guard points.count >= 2 else { return .zero }
        return CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                      width: abs(points[0].x - points[1].x), height: abs(points[0].y - points[1].y))
    }
}

/// Draws marks. Redactions are burned into the pixels (or into a rasterised PDF page), so nothing underneath
/// can be recovered from the saved file.
enum MarkupRenderer {
    private static let ciContext = CIContext()

    // MARK: - Images

    static func render(_ image: CGImage, items: [MarkupItem]) throws -> CGImage {
        let context = try ImageOps.makeContext(width: image.width, height: image.height)
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        drawAnnotations(items.filter { !$0.isRedaction }, in: context, size: size)
        for item in items where item.isRedaction { try redact(item, image: image, in: context, size: size) }
        guard let result = context.makeImage() else { throw ConversionError.encodeFailed("image") }
        return result
    }

    private static func redact(_ item: MarkupItem, image: CGImage, in context: CGContext, size: CGSize) throws {
        let box = item.box
        // Pixel rectangle with a top-left origin, then the bottom-left one CoreGraphics draws in.
        let top = CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height).integral
        let rect = CGRect(x: top.minX, y: size.height - top.maxY, width: top.width, height: top.height)
            .intersection(CGRect(origin: .zero, size: size))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return }

        switch item.kind {
        case .blackout:
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(rect)
        case .blur, .pixelate:
            let source = CIImage(cgImage: image)
            let filtered: CIImage
            if item.kind == .blur {
                let radius = max(8, min(rect.width, rect.height) * 0.2)
                filtered = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            } else {
                let scale = max(6, min(rect.width, rect.height) / 8)
                filtered = source.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale])
            }
            guard let piece = ciContext.createCGImage(filtered, from: rect) else { throw ConversionError.encodeFailed("image") }
            context.draw(piece, in: rect)
            // A blur still shows shapes; a dark veil makes the cover-up unambiguous and unreadable.
            context.setFillColor(CGColor(gray: 0, alpha: 0.25))
            context.fill(rect)
        default: break
        }
    }

    // MARK: - Annotations

    /// Draws non-redaction marks into a bottom-left-origin context of `size`.
    static func drawAnnotations(_ items: [MarkupItem], in context: CGContext, size: CGSize) {
        let short = min(size.width, size.height)
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height) }
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for item in items {
            context.setStrokeColor(item.color.cgColor)
            context.setFillColor(item.color.cgColor)
            context.setLineWidth(max(1, item.width * short))
            switch item.kind {
            case .rectangle, .ellipse:
                let a = point(item.points.first ?? .zero), b = point(item.points.dropFirst().first ?? .zero)
                let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                if item.kind == .rectangle { context.stroke(rect) } else { context.strokeEllipse(in: rect) }
            case .arrow:
                guard item.points.count >= 2 else { continue }
                let tail = point(item.points[0]), head = point(item.points[1])
                let angle = atan2(head.y - tail.y, head.x - tail.x)
                let length = max(12, item.width * short * 5), spread = CGFloat.pi / 7
                context.move(to: tail)
                context.addLine(to: head)
                for side in [CGFloat(-1), CGFloat(1)] {
                    // All in Double, converted once: mixing CGFloat and Double here is ambiguous for older compilers.
                    let theta = Double(angle) + Double(side) * Double(spread)
                    let dx = Double(length) * cos(theta), dy = Double(length) * sin(theta)
                    context.move(to: head)
                    context.addLine(to: CGPoint(x: head.x - CGFloat(dx), y: head.y - CGFloat(dy)))
                }
                context.strokePath()
            case .pen:
                guard let first = item.points.first else { continue }
                context.move(to: point(first))
                for p in item.points.dropFirst() { context.addLine(to: point(p)) }
                context.strokePath()
            case .text:
                guard let anchor = item.points.first, !item.text.isEmpty else { continue }
                let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(8, item.fontSize * short), nil)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor(cgColor: item.color.cgColor) ?? .red]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: item.text, attributes: attributes))
                let origin = point(anchor)
                context.textPosition = CGPoint(x: origin.x, y: origin.y - CTFontGetAscent(font))
                CTLineDraw(line, context)
            default: break
            }
        }
        context.restoreGState()
    }

    // MARK: - PDF

    /// Writes `source` with marks on each page. A page with a redaction is rasterised (at `dpi`) with every mark
    /// burned in, so its text layer is gone too; other pages stay vector with the marks drawn on top.
    static func renderPDF(source: URL, output: URL, itemsByPage: [Int: [MarkupItem]], dpi: Int = 200) throws {
        let document = try PDFEngine.open(source)
        guard let first = document.page(at: 0) else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        var firstBox = CGRect(origin: .zero, size: displayedSize(first))
        guard let context = CGContext(output as CFURL, mediaBox: &firstBox, nil) else { throw ConversionError.encodeFailed("PDF") }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let items = itemsByPage[index] ?? []
            var box = CGRect(origin: .zero, size: displayedSize(page))
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            if items.contains(where: \.isRedaction) {
                let raster = try PDFEngine.render(page, dpi: dpi)
                context.draw(try render(raster, items: items), in: box)
            } else {
                if let cgPage = page.pageRef {
                    context.saveGState()
                    context.concatenate(cgPage.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(cgPage)
                    context.restoreGState()
                }
                drawAnnotations(items, in: context, size: box.size)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func displayedSize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }
}
