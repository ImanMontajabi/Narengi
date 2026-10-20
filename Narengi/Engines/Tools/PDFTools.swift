import AppKit
import PDFKit
import Quartz

/// A page in the Organize window: which original page, and how far it is turned.
struct PDFPageEdit: Equatable, Sendable {
    var index: Int
    /// Extra clockwise rotation in degrees (0, 90, 180, 270) on top of the page's own.
    var rotation: Int = 0
}

/// PDF tools built on PDFKit and CoreGraphics. Split, merge and compress follow Satsuma's `pdf.rs`
/// (MIT, © sonatina-dream); Organize is Narengi's own.
enum PDFTools {
    // MARK: - Split / merge

    /// One PDF per page in `directory`, named `<stem> 01.pdf`, `<stem> 02.pdf`, …
    static func split(source: URL, directory: URL, stem: String, progress: @Sendable (Double) -> Void) throws {
        let document = try PDFEngine.open(source)
        let count = document.pageCount
        let width = max(String(count).count, 2)
        for index in 0..<count {
            try Task.checkCancellation()
            let single = PDFDocument()
            if let page = document.page(at: index)?.copy() as? PDFPage { single.insert(page, at: 0) }
            let url = directory.appendingPathComponent("\(stem) \(String(format: "%0\(width)d", index + 1)).pdf")
            guard single.write(to: url) else { throw ConversionError.outputUnwritable(directory.path) }
            progress(Double(index + 1) / Double(count))
        }
    }

    static func merge(sources: [URL], output: URL, progress: @Sendable (Double) -> Void = { _ in }) throws {
        let merged = PDFDocument()
        for (n, source) in sources.enumerated() {
            try Task.checkCancellation()
            let document = try PDFEngine.open(source)
            for index in 0..<document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
            progress(Double(n + 1) / Double(sources.count))
        }
        guard merged.pageCount > 0 else { throw ConversionError.custom("The selected PDFs have no pages.") }
        guard merged.write(to: output) else { throw ConversionError.encodeFailed("PDF") }
    }

    /// One page per image, in order; each page keeps the picture's physical size at its own DPI.
    static func createPDF(from images: [URL], output: URL, progress: @Sendable (Double) -> Void) throws {
        var decoded: [(image: CGImage, dpi: Double)] = []
        for (n, url) in images.enumerated() {
            try Task.checkCancellation()
            let result = try ImageEngine.decode(url, dpi: 150, flattenOnWhite: false)
            decoded.append((result.image, result.dpi))
            progress(Double(n + 1) / Double(images.count + 1))
        }
        try PDFEngine.makePDF(from: decoded, to: output)
    }

    // MARK: - Compress

    /// Recompresses embedded images. PDFKit's own JPEG option goes first (it keeps links and outlines intact);
    /// when that barely helps — or `strong` is asked for — Apple's "Reduce File Size" Quartz filter is applied
    /// to a redraw of every page (text stays vector, images are downsampled and recompressed).
    static func compress(source: URL, output: URL, strong: Bool) throws {
        let document = try PDFEngine.open(source)
        let original = ImageOps.fileSize(source)
        if !strong {
            let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: false]
            if document.write(to: output, withOptions: options), ImageOps.fileSize(output) < Int(Double(original) * 0.95) { return }
            try? FileManager.default.removeItem(at: output)
        }
        try compressWithQuartzFilter(source: source, output: output)
    }

    static let quartzFilterURL = URL(fileURLWithPath: "/System/Library/Filters/Reduce File Size.qfilter")

    static func compressWithQuartzFilter(source: URL, output: URL) throws {
        guard let filter = QuartzFilter(url: quartzFilterURL) else {
            throw ConversionError.custom("This Mac's PDF size-reduction filter is missing.")
        }
        guard let input = CGPDFDocument(source as CFURL), input.numberOfPages > 0 else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        var first = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &first, nil) else { throw ConversionError.encodeFailed("PDF") }
        filter.apply(to: context)
        for number in 1...input.numberOfPages {
            try Task.checkCancellation()
            guard let page = input.page(at: number) else { continue }
            let crop = page.getBoxRect(.cropBox)
            let turned = page.rotationAngle % 180 != 0
            var box = CGRect(x: 0, y: 0, width: turned ? crop.height : crop.width, height: turned ? crop.width : crop.height)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
    }

    // MARK: - Organize

    /// Writes the pages in `edits` order (deleted pages are simply absent). With `sameWidth`, every page is
    /// scaled to the widest page's width, so a mixed-size scan reads evenly.
    static func organize(source: URL, output: URL, edits: [PDFPageEdit], sameWidth: Bool) throws {
        let document = try PDFEngine.open(source)
        guard !edits.isEmpty else { throw ConversionError.custom("Keep at least one page.") }
        let pages: [(PDFPage, Int)] = try edits.map { edit in
            guard let page = document.page(at: edit.index) else { throw ConversionError.decodeFailed(source.lastPathComponent) }
            return (page, edit.rotation)
        }
        if !sameWidth {
            let result = PDFDocument()
            for (page, rotation) in pages {
                guard let copy = page.copy() as? PDFPage else { continue }
                copy.rotation = ((copy.rotation + rotation) % 360 + 360) % 360
                result.insert(copy, at: result.pageCount)
            }
            guard result.write(to: output) else { throw ConversionError.encodeFailed("PDF") }
            return
        }
        // Same width: redraw each page, vectors intact, scaled to the widest displayed page.
        func displayed(_ page: PDFPage, _ rotation: Int) -> CGSize {
            let box = page.bounds(for: .cropBox)
            return (page.rotation + rotation) % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        }
        let target = pages.map { displayed($0.0, $0.1).width }.max() ?? 612
        var first = CGRect(x: 0, y: 0, width: target, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &first, nil) else { throw ConversionError.encodeFailed("PDF") }
        for (page, rotation) in pages {
            let size = displayed(page, rotation)
            let scale = target / max(size.width, 1)
            var box = CGRect(x: 0, y: 0, width: target, height: max(1, (size.height * scale).rounded()))
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            if let cgPage = page.pageRef {
                // The transform accounts for the page's own /Rotate, the extra turn and the scaling.
                context.saveGState()
                context.concatenate(cgPage.getDrawingTransform(.cropBox, rect: box, rotate: Int32(rotation), preserveAspectRatio: true))
                context.drawPDFPage(cgPage)
                context.restoreGState()
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
