import AppKit
import ImageIO
import PDFKit

/// PDFKit-based conversions: PDF → images / text / Markdown / HTML, images → PDF. Scanned PDFs (no
/// selectable text) fall back to on-device OCR.
struct PDFEngine {
    /// Targets handled here; DOCX and EPUB go through `DocumentEngine`.
    static let outputFormats = ["PNG", "JPG", "TIFF", "TXT", "MD", "HTML"]

    func convert(
        source: URL,
        options: ConversionOptions,
        allocator: OutputAllocator,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let document = try Self.open(source)

        switch options.targetFormat {
        case "PNG", "JPG":
            return try Self.renderPages(document, source: source, options: options, allocator: allocator, progress: progress)
        case "TIFF":
            return try Self.renderMultipageTIFF(document, source: source, options: options, allocator: allocator, progress: progress)
        case "TXT", "MD", "HTML":
            let text = try await Self.formattedText(document, source: source, format: options.targetFormat)
            progress(0.8)
            let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: options.targetFormat))
            try text.write(to: output, atomically: false, encoding: .utf8)
            progress(1)
            return [output]
        default:
            throw ConversionError.unsupported(from: "PDF", to: options.targetFormat)
        }
    }

    static func open(_ source: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: source) else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        if document.isLocked { throw ConversionError.passwordProtected }
        guard document.pageCount > 0 else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        return document
    }

    // MARK: - Pages → images

    /// One image for a single-page PDF; a new folder of `Page N` images otherwise.
    static func renderPages(
        _ document: PDFDocument, source: URL, options: ConversionOptions,
        allocator: OutputAllocator, progress: @Sendable (Double) -> Void
    ) throws -> [URL] {
        let ext = options.targetFormat == "JPG" ? "jpg" : "png"
        let count = document.pageCount
        let folder = count > 1 ? try allocator.allocateFolder(for: source) : nil

        var outputs: [URL] = []
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let image = try render(page, dpi: options.dpi)
            let url: URL
            if let folder {
                url = try allocator.allocateFile(in: folder, baseName: "Page \(index + 1)", pathExtension: ext)
            } else {
                url = try allocator.allocateFile(for: source, pathExtension: ext)
            }
            try ImageEngine.encode(
                ImageEngine.DecodedImage(image: image, dpi: Double(options.dpi), metadata: [:]),
                format: options.targetFormat, options: options, to: url)
            outputs.append(url)
            progress(Double(index + 1) / Double(count))
        }
        return folder.map { [$0] } ?? outputs
    }

    private static func renderMultipageTIFF(
        _ document: PDFDocument, source: URL, options: ConversionOptions,
        allocator: OutputAllocator, progress: @Sendable (Double) -> Void
    ) throws -> [URL] {
        let output = try allocator.allocateFile(for: source, pathExtension: "tiff")
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, "public.tiff" as CFString, document.pageCount, nil)
        else { throw ConversionError.encodeFailed("TIFF") }

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: options.dpi,
                kCGImagePropertyDPIHeight: options.dpi,
            ]
            CGImageDestinationAddImage(destination, try render(page, dpi: options.dpi), properties as CFDictionary)
            progress(Double(index + 1) / Double(document.pageCount))
        }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encodeFailed("TIFF") }
        return [output]
    }

    /// Rasterizes one page on a white background.
    static func render(_ page: PDFPage, dpi: Int) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pointSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        var scale = Double(dpi) / 72
        scale = min(scale, 12_000 / Double(max(pointSize.width, pointSize.height, 1)))
        let size = NSSize(width: max(1, (pointSize.width * scale).rounded()),
                          height: max(1, (pointSize.height * scale).rounded()))

        let thumbnail = page.thumbnail(of: size, for: .cropBox)
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ConversionError.decodeFailed("page")
        }
        return ImageEngine.flatten(cgImage)
    }

    // MARK: - Images → PDF

    /// Writes one PDF page per image, sized so the image keeps its physical size at its own DPI.
    static func makePDF(from images: [(image: CGImage, dpi: Double)], to url: URL) throws {
        guard let first = images.first else { throw ConversionError.encodeFailed("PDF") }
        var firstBox = pageBox(for: first.image, dpi: first.dpi)
        guard let context = CGContext(url as CFURL, mediaBox: &firstBox, nil) else {
            throw ConversionError.encodeFailed("PDF")
        }
        for (image, dpi) in images {
            var box = pageBox(for: image, dpi: dpi)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func pageBox(for image: CGImage, dpi: Double) -> CGRect {
        let scale = 72 / (dpi > 0 ? dpi : 72)
        return CGRect(x: 0, y: 0, width: Double(image.width) * scale, height: Double(image.height) * scale)
    }

    // MARK: - Text, Markdown, HTML

    /// Selectable text of the whole document, or `nil` when there is none (a scan).
    static func selectableText(_ document: PDFDocument) -> String? {
        let text = document.string ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// OCR text of every page, paragraphs separated by blank lines. Pages render at 200 DPI.
    static func recognizedText(_ document: PDFDocument) async throws -> String {
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let paragraphs = OCREngine.paragraphs(try await OCREngine.recognizeAsync(try render(page, dpi: 200)))
            if !paragraphs.isEmpty { pages.append(paragraphs.joined(separator: "\n\n")) }
        }
        guard !pages.isEmpty else { throw ConversionError.noText }
        return pages.joined(separator: "\n\n")
    }

    /// Plain text of a PDF: selectable text, or OCR when the pages are images.
    static func text(of source: URL) async throws -> String {
        let document = try open(source)
        if let text = selectableText(document) { return text }
        return try await recognizedText(document)
    }

    /// TXT, Markdown or HTML for a PDF. Selectable text keeps headings (by font size); scans use OCR paragraphs.
    static func formattedText(_ document: PDFDocument, source: URL, format: String) async throws -> String {
        if selectableText(document) != nil {
            return try extractText(document, format: format)
        }
        let recognized = try await recognizedText(document)
        switch format {
        case "TXT": return recognized + "\n"
        case "MD": return HTML.textToMarkdown(recognized)
        default:
            let title = NamingRules.stem(of: source.lastPathComponent)
            return HTML.document(title: title, body: HTML.textToBody(recognized))
        }
    }

    private struct Line {
        var text: String
        var size: CGFloat
    }

    /// Pulls lines with their dominant font size so headings can be told apart from body text.
    private static func lines(of document: PDFDocument) -> [[Line]] {
        (0..<document.pageCount).map { index in
            guard let attributed = document.page(at: index)?.attributedString else { return [] }
            var result: [Line] = []
            let full = attributed.string as NSString
            full.enumerateSubstrings(in: NSRange(location: 0, length: full.length), options: .byLines) { text, range, _, _ in
                guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                    result.append(Line(text: "", size: 0))
                    return
                }
                var largest: CGFloat = 0
                attributed.enumerateAttribute(.font, in: range) { value, _, _ in
                    if let font = value as? NSFont { largest = max(largest, font.pointSize) }
                }
                result.append(Line(text: text.trimmingCharacters(in: .whitespaces), size: largest))
            }
            return result
        }
    }

    static func extractText(_ document: PDFDocument, format: String) throws -> String {
        let pages = lines(of: document)
        guard pages.contains(where: { $0.contains { !$0.text.isEmpty } }) else { throw ConversionError.noText }

        if format == "TXT" {
            return pages.map { $0.map(\.text).joined(separator: "\n") }
                .joined(separator: "\n\n")
                .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        // Median size of non-empty lines is "body"; clearly larger short lines become headings.
        let sizes = pages.flatMap { $0 }.filter { !$0.text.isEmpty }.map(\.size).sorted()
        let body = sizes.isEmpty ? 12 : sizes[sizes.count / 2]

        enum Block { case heading(Int, String), paragraph(String) }
        var blocks: [Block] = []
        var paragraph: [String] = []

        func flush() {
            guard !paragraph.isEmpty else { return }
            var joined = ""
            for line in paragraph {
                if joined.hasSuffix("-"), let first = line.first, first.isLowercase {
                    joined.removeLast()
                    joined += line
                } else {
                    joined += (joined.isEmpty ? "" : " ") + line
                }
            }
            blocks.append(.paragraph(joined))
            paragraph = []
        }

        for page in pages {
            for line in page {
                if line.text.isEmpty { flush(); continue }
                let ratio = body > 0 ? line.size / body : 1
                if ratio >= 1.25, line.text.count <= 120 {
                    flush()
                    blocks.append(.heading(ratio >= 1.8 ? 1 : ratio >= 1.45 ? 2 : 3, line.text))
                } else {
                    paragraph.append(line.text)
                }
            }
            flush()
        }

        if format == "MD" {
            return blocks.map { block in
                switch block {
                case .heading(let level, let text): return String(repeating: "#", count: level) + " " + text
                case .paragraph(let text): return text
                }
            }.joined(separator: "\n\n") + "\n"
        }

        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let htmlBody = blocks.map { block in
            switch block {
            case .heading(let level, let text): return "<h\(level)>\(HTML.escape(text))</h\(level)>"
            case .paragraph(let text): return "<p>\(HTML.escape(text))</p>"
            }
        }.joined(separator: "\n")
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(HTML.escape(title))</title>
        <style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:46rem;margin:2rem auto;padding:0 1rem;line-height:1.55}</style>
        </head>
        <body>
        \(htmlBody)
        </body>
        </html>

        """
    }
}
