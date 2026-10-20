import Foundation
import PDFKit

/// Document conversions. Every input is first turned into HTML (via `textutil`, the Markdown renderer,
/// the EPUB reader or PDF text/OCR), and every output is produced from that HTML. This hub-and-spoke
/// design is Satsuma's (`doc.rs`, MIT, © sonatina-dream).
struct DocumentEngine {
    /// Sources this engine reads (PDF only for DOCX/EPUB output; PDFEngine handles the rest of PDF).
    static let sources: Set<String> = ["DOCX", "MD", "TXT", "RTF", "RTFD", "TEXTCLIPPING", "EPUB", "PDF"]
    static let targets: Set<String> = ["DOCX", "TXT", "MD", "HTML", "EPUB", "PDF", "PNG", "JPG"]

    static func supports(source: String, target: String) -> Bool {
        if source == "PDF" { return target == "DOCX" || target == "EPUB" }
        return sources.contains(source) && targets.contains(target) && source != target
    }

    func convert(
        source: URL, options: ConversionOptions, allocator: OutputAllocator,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let format = options.sourceFormat, target = options.targetFormat
        guard Self.supports(source: format, target: target) else {
            throw ConversionError.unsupported(from: format, to: target)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("narengi-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let title = NamingRules.stem(of: source.lastPathComponent)
        try Self.validate(source, format: format)

        // Shortcut that keeps the Markdown source intact.
        if format == "MD", target == "HTML" {
            let output = try allocator.allocateFile(for: source, pathExtension: "html")
            let html = HTML.document(title: title, body: MarkdownRenderer.htmlBody(try Self.readText(source)))
            try html.write(to: output, atomically: false, encoding: .utf8)
            progress(1)
            return [output]
        }

        let html = try await loadHTML(source: source, format: format, title: title, scratch: scratch)
        progress(0.3)
        try Task.checkCancellation()

        switch target {
        case "HTML":
            let output = try allocator.allocateFile(for: source, pathExtension: "html")
            try html.write(to: output, atomically: false, encoding: .utf8)
            progress(1)
            return [output]

        case "MD":
            let output = try allocator.allocateFile(for: source, pathExtension: "md")
            try HTMLToMarkdown.convert(html).write(to: output, atomically: false, encoding: .utf8)
            progress(1)
            return [output]

        case "TXT", "DOCX":
            let htmlFile = scratch.appendingPathComponent("doc.html")
            try html.write(to: htmlFile, atomically: false, encoding: .utf8)
            let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: target))
            try await TextUtil.convert(htmlFile, to: target.lowercased(), output: output)
            progress(1)
            return [output]

        case "EPUB":
            // Normalise through Markdown so the chapter is well-formed XHTML.
            let body = MarkdownRenderer.htmlBody(HTMLToMarkdown.convert(html))
            let output = try allocator.allocateFile(for: source, pathExtension: "epub")
            try EPUB.write(to: output, title: title, xhtmlBody: body)
            progress(1)
            return [output]

        case "PDF":
            let output = try allocator.allocateFile(for: source, pathExtension: "pdf")
            try await htmlToPDF(html, output: output, scratch: scratch)
            progress(1)
            return [output]

        case "PNG", "JPG":
            let pdf = scratch.appendingPathComponent("doc.pdf")
            try await htmlToPDF(html, output: pdf, scratch: scratch)
            progress(0.6)
            guard let document = PDFDocument(url: pdf) else { throw ConversionError.decodeFailed(source.lastPathComponent) }
            var imageOptions = options
            imageOptions.dpi = 200
            return try PDFEngine.renderPages(
                document, source: source, options: imageOptions, allocator: allocator,
                progress: { progress(0.6 + $0 * 0.4) })

        default:
            throw ConversionError.unsupported(from: format, to: target)
        }
    }

    /// `textutil` quietly treats unknown files as plain text; catch files that merely carry the extension.
    static func validate(_ source: URL, format: String) throws {
        func head(_ count: Int) -> Data { (try? FileHandle(forReadingFrom: source))?.readData(ofLength: count) ?? Data() }
        switch format {
        case "DOCX", "EPUB":
            guard head(2) == Data("PK".utf8) else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        case "RTF":
            guard head(5) == Data("{\\rtf".utf8) else { throw ConversionError.decodeFailed(source.lastPathComponent) }
        default:
            break
        }
    }

    // MARK: - Loading

    func loadHTML(source: URL, format: String, title: String, scratch: URL) async throws -> String {
        switch format {
        case "MD":
            return HTML.document(title: title, body: MarkdownRenderer.htmlBody(try Self.readText(source)))
        case "EPUB":
            return try await EPUB.read(source).html
        case "PDF":
            let text = try await PDFEngine.text(of: source)
            return HTML.document(title: title, body: HTML.textToBody(text))
        case "TEXTCLIPPING":
            switch try Self.readTextClipping(source) {
            case .text(let text):
                return HTML.document(title: title, body: HTML.textToBody(text))
            case .rtf(let data):
                let rtf = scratch.appendingPathComponent("clipping.rtf")
                try data.write(to: rtf)
                return try await viaTextUtil(rtf, scratch: scratch)
            }
        case "DOCX", "RTF", "RTFD", "TXT":
            return try await viaTextUtil(source, scratch: scratch)
        default:
            throw ConversionError.unsupported(from: format, to: "HTML")
        }
    }

    private func viaTextUtil(_ input: URL, scratch: URL) async throws -> String {
        let output = scratch.appendingPathComponent("source-\(UUID().uuidString).html")
        try await TextUtil.convert(input, to: "html", output: output)
        return try Self.readText(output)
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        return String(decoding: bytes, as: UTF8.self)
    }

    enum Clipping {
        case rtf(Data)
        case text(String)
    }

    /// Finder text clippings keep their contents in a property list (`UTI-Data`).
    static func readTextClipping(_ url: URL) throws -> Clipping {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let uti = plist["UTI-Data"] as? [String: Any]
        else { throw ConversionError.decodeFailed(url.lastPathComponent) }
        if let rtf = uti["public.rtf"] as? Data { return .rtf(rtf) }
        if let s = uti["public.utf8-plain-text"] as? String { return .text(s) }
        if let d = uti["public.utf8-plain-text"] as? Data { return .text(String(decoding: d, as: UTF8.self)) }
        if let d = uti["public.utf16-plain-text"] as? Data {
            return .text(String(data: d, encoding: .utf16LittleEndian) ?? String(decoding: d, as: UTF8.self))
        }
        throw ConversionError.toolFailed(tool: "clipping", message: "The text clipping has no text.")
    }

    // MARK: - Printing

    /// HTML → printable HTML → RTF (textutil) → paginated PDF (CoreText).
    func htmlToPDF(_ html: String, output: URL, scratch: URL) async throws {
        let page = scratch.appendingPathComponent("page-\(UUID().uuidString).html")
        try PrintableHTML.rewrite(html).write(to: page, atomically: false, encoding: .utf8)
        let rtf = scratch.appendingPathComponent("page-\(UUID().uuidString).rtf")
        try await TextUtil.convert(page, to: "rtf", output: rtf)
        try PDFPaginator.write(rtf: rtf, to: output)
    }
}
