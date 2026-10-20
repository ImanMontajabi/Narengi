import AppKit
import CoreText
import Foundation

// MARK: - textutil

/// macOS `textutil`: reads and writes DOCX, RTF, RTFD, HTML and plain text.
enum TextUtil {
    static let executable = URL(fileURLWithPath: "/usr/bin/textutil")

    /// `textutil -convert <type> -output <output> <input>`; type is txt, html, rtf, rtfd, doc, docx or odt.
    static func convert(_ input: URL, to type: String, output: URL) async throws {
        var args = ["-convert", type]
        let ext = input.pathExtension.lowercased()
        if ["txt", "text", "md"].contains(ext) { args += ["-format", "txt", "-inputencoding", "UTF-8"] }
        if type == "txt" || type == "html" { args += ["-encoding", "UTF-8"] }
        args += ["-output", output.path, input.path]
        try await ProcessRunner.run(executable, arguments: args, tool: "textutil")
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.toolFailed(tool: "textutil", message: "no output file was produced")
        }
    }
}

// MARK: - DOCX

/// A minimal Word writer: paragraphs and an optional inline picture. Structure ported from Satsuma's
/// `docx.rs` (MIT, © sonatina-dream).
enum DOCXWriter {
    struct Picture {
        var png: Data
        var widthPx: Int
        var heightPx: Int
    }

    private static let emuPerInch = 914_400.0
    private static let textWidthInches = 6.5
    private static let textHeightInches = 9.0

    private static func paragraph(_ text: String) -> String {
        let runs = text.components(separatedBy: "\n").enumerated().map { index, line in
            (index > 0 ? "<w:r><w:br/></w:r>" : "") + "<w:r><w:t xml:space=\"preserve\">\(HTML.escape(line))</w:t></w:r>"
        }.joined()
        return "<w:p>\(runs)</w:p>"
    }

    private static func pictureXML(_ p: Picture) -> String {
        // Fit the page text area, never enlarging beyond 96 dpi.
        let (wIn, hIn) = (Double(p.widthPx) / 96, Double(p.heightPx) / 96)
        let scale = min(textWidthInches / wIn, textHeightInches / hIn, 1)
        let cx = Int(wIn * scale * emuPerInch), cy = Int(hIn * scale * emuPerInch)
        return """
        <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="1" name="Picture 1"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="1" name="image1.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="rIdImage1"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
        """
    }

    static func data(paragraphs: [String], picture: Picture? = nil) throws -> Data {
        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """)
        try zip.add("_rels/.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdDoc" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """)

        var body = paragraphs.map(paragraph).joined()
        if let picture {
            body += pictureXML(picture)
            try zip.add("word/_rels/document.xml.rels", text: """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdImage1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/image1.png"/></Relationships>
            """)
            try zip.add("word/media/image1.png", data: picture.png, compress: false)
        }
        if body.isEmpty { body = "<w:p/>" }
        try zip.add("word/document.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
        """)
        return zip.finalized()
    }

    static func write(to url: URL, paragraphs: [String], picture: Picture? = nil) throws {
        do { try data(paragraphs: paragraphs, picture: picture).write(to: url) }
        catch { throw ConversionError.outputUnwritable(url.deletingLastPathComponent().path) }
    }
}

// MARK: - EPUB

/// A minimal EPUB 3 writer and reader (one chapter). Ported from Satsuma's `epub.rs` (MIT, © sonatina-dream).
enum EPUB {
    /// Writes a single-chapter EPUB. `xhtmlBody` must be well-formed XHTML.
    static func write(to url: URL, title: String, xhtmlBody: String) throws {
        let escapedTitle = HTML.escape(title)
        var zip = ZipWriter()
        // `mimetype` must be the first entry and stored uncompressed.
        try zip.add("mimetype", text: "application/epub+zip", compress: false)
        try zip.add("META-INF/container.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
        try zip.add("OEBPS/content.opf", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="bookid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
            <dc:title>\(escapedTitle)</dc:title>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">\(modifiedStamp())</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """)
        try zip.add("OEBPS/nav.xhtml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <head><title>\(escapedTitle)</title></head>
        <body><nav epub:type="toc" id="toc"><ol><li><a href="chapter.xhtml">\(escapedTitle)</a></li></ol></nav></body>
        </html>
        """)
        try zip.add("OEBPS/chapter.xhtml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><meta charset="utf-8"/><title>\(escapedTitle)</title></head>
        <body>
        \(xhtmlBody)
        </body>
        </html>
        """)
        try zip.write(to: url)
    }

    private static func modifiedStamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    /// Reads an EPUB's spine into one HTML document. Returns (title, html).
    static func read(_ url: URL) async throws -> (title: String, html: String) {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("narengi-epub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            try await ArchiveEngine.extract(url, format: "ZIP", into: scratch)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConversionError.toolFailed(tool: "EPUB", message: "This EPUB file looks damaged.")
        }

        func readText(_ relative: String) -> String? {
            let file = scratch.appendingPathComponent(relative).standardizedFileURL
            // Stay inside the extraction folder even if the EPUB names a path with `..`.
            guard file.path.hasPrefix(scratch.standardizedFileURL.path) else { return nil }
            return (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) }
        }

        guard let container = readText("META-INF/container.xml"),
              let opfPath = HTML.tokenize(container).compactMap({ token -> String? in
                  if case .open(let name, let attrs, _) = token, name == "rootfile" { return HTML.attribute("full-path", in: attrs) }
                  return nil
              }).first,
              let opf = readText(opfPath)
        else { throw ConversionError.toolFailed(tool: "EPUB", message: "The EPUB has no package document.") }
        let opfDirectory = (opfPath as NSString).deletingLastPathComponent

        var items: [String: (href: String, media: String)] = [:]
        var spine: [String] = []
        var title = ""
        var inTitle = false
        for token in HTML.tokenize(opf) {
            switch token {
            case .open(let name, let attrs, _):
                let a = HTML.attributes(attrs)
                if name == "item", let id = a["id"], let href = a["href"] { items[id] = (href, a["media-type"] ?? "") }
                else if name == "itemref", let id = a["idref"] { spine.append(id) }
                else if name == "dc:title" { inTitle = title.isEmpty }
            case .close(let name) where name == "dc:title": inTitle = false
            case .text(let t) where inTitle: title += HTML.decodeEntities(t.trimmingCharacters(in: .whitespacesAndNewlines))
            default: break
            }
        }

        var body = ""
        for id in spine {
            guard let item = items[id], item.media.contains("html") || item.href.hasSuffix("html") || item.href.hasSuffix(".htm") else { continue }
            let relative = joinPath(opfDirectory, item.href.removingPercentEncoding ?? item.href)
            if let chapter = readText(relative) { body += HTML.bodyOf(chapter) + "\n" }
        }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.toolFailed(tool: "EPUB", message: "The EPUB has no readable chapters.")
        }
        return (title, HTML.document(title: title, body: body))
    }

    static func joinPath(_ base: String, _ href: String) -> String {
        var parts = base.isEmpty ? [] : base.split(separator: "/").map(String.init)
        for segment in href.split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(String(segment))
            }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - PDF pagination

/// Lays attributed text out on US Letter pages (1-inch margins) with CoreText.
enum PDFPaginator {
    static func write(rtf: URL, to output: URL) throws {
        guard let data = try? Data(contentsOf: rtf), let text = NSAttributedString(rtf: data, documentAttributes: nil) else {
            throw ConversionError.decodeFailed(rtf.lastPathComponent)
        }
        try write(text, to: output)
    }

    static func write(_ attributed: NSAttributedString, to output: URL) throws {
        let text = NSMutableAttributedString(attributedString: attributed)
        // CoreText reads colours from its own attribute as CGColor; copy AppKit's NSColor over.
        text.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let color = value as? NSColor {
                text.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: color.cgColor, range: range)
            }
        }

        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let body = CGRect(x: 72, y: 72, width: 468, height: 648)
        guard let context = CGContext(output as CFURL, mediaBox: &page, nil) else {
            throw ConversionError.outputUnwritable(output.deletingLastPathComponent().path)
        }
        let path = CGPath(rect: body, transform: nil)
        var position = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            if visible.length <= 0 { break }
            position += visible.length
        } while position < text.length
        context.closePDF()
    }

    /// Monospaced text (a spreadsheet table, say) as a PDF; the font size shrinks to fit the widest line.
    static func writeMonospaced(_ text: String, to output: URL) throws {
        let widest = max(1, text.components(separatedBy: "\n").map(\.count).max() ?? 1)
        let size = min(10, max(5, 468 / (CGFloat(widest) * 0.61)))
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        try write(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black]), to: output)
    }
}
