import PDFKit
import XCTest
@testable import Narengi

final class DocumentConversionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private let markdown = """
    # Quarterly Report

    Intro paragraph with **bold**, *italic* and a [link](https://example.com).

    ## Findings

    - First finding
    - Second finding

    1. Step one
    2. Step two

    | Name | Score |
    |------|-------|
    | Ann  | 10    |
    | Bob  | 7     |

    Closing words & a symbol: café ✓
    """

    @discardableResult
    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func convert(_ source: URL, to target: String) async throws -> [URL] {
        let from = try XCTUnwrap(FormatCatalog.format(for: source))
        return try await ConversionService.run(source: source, options: ConversionOptions(sourceFormat: from, targetFormat: target))
    }

    // MARK: Markdown source

    func testMarkdownToHTMLKeepsStructure() async throws {
        let md = try write("report.md", markdown)
        let html = try String(contentsOf: try await convert(md, to: "HTML")[0])
        XCTAssertTrue(html.contains("<h1>Quarterly Report</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<title>report</title>"))
        XCTAssertTrue(html.contains("café ✓"))
    }

    func testMarkdownToTextAndDocxAndBackToMarkdown() async throws {
        let md = try write("report.md", markdown)

        let txt = try String(contentsOf: try await convert(md, to: "TXT")[0])
        XCTAssertTrue(txt.contains("Quarterly Report"))
        XCTAssertTrue(txt.contains("First finding"))
        XCTAssertFalse(txt.contains("**"))
        XCTAssertTrue(txt.contains("café ✓"))

        let docx = try await convert(md, to: "DOCX")[0]
        XCTAssertEqual(docx.pathExtension, "docx")
        try TestSupport.run("/usr/bin/unzip", ["-tq", docx.path])

        // Reading the Word file back must keep the words, the emphasis and the headings.
        let back = try String(contentsOf: try await convert(docx, to: "MD")[0])
        XCTAssertTrue(back.contains("# Quarterly Report"), "heading must survive as a Markdown heading without bold markers:\n\(back)")
        XCTAssertFalse(back.contains("**Quarterly Report**"), back)
        XCTAssertTrue(back.contains("**bold**"), back)
        XCTAssertTrue(back.contains("First finding"), back)
        XCTAssertTrue(back.contains("café ✓"), back)
    }

    func testMarkdownToEPUBIsAValidPackageAndReadsBack() async throws {
        let md = try write("book.md", markdown)
        let epub = try await convert(md, to: "EPUB")[0]

        // The first entry must be `mimetype`, stored (method 0), per the EPUB spec.
        let header = try Data(contentsOf: epub).prefix(60)
        XCTAssertEqual(Array(header.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(header[8], 0, "mimetype must be stored, not deflated")
        XCTAssertEqual(String(decoding: header[30..<38], as: UTF8.self), "mimetype")
        XCTAssertEqual(String(decoding: header[38..<58], as: UTF8.self), "application/epub+zip")
        try TestSupport.run("/usr/bin/unzip", ["-tq", epub.path])

        let (title, html) = try await EPUB.read(epub)
        XCTAssertEqual(title, "book")
        XCTAssertTrue(html.contains("Quarterly Report"))

        // And through the engine: EPUB → MD, TXT, PDF.
        let epubMD = try String(contentsOf: try await convert(epub, to: "MD")[0])
        XCTAssertTrue(epubMD.contains("**bold**"), epubMD)
        let epubTXT = try String(contentsOf: try await convert(epub, to: "TXT")[0])
        XCTAssertTrue(epubTXT.contains("Second finding"), epubTXT)
        let pdf = try await convert(epub, to: "PDF")[0]
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Quarterly Report") == true)
    }

    func testMarkdownToPDFPaginatesAndRendersToNumberedPages() async throws {
        let long = (1...120).map { "Paragraph \($0): " + String(repeating: "lorem ipsum dolor sit amet ", count: 12) }.joined(separator: "\n\n")
        let md = try write("long.md", "# Long document\n\n" + long)

        let pdf = try await convert(md, to: "PDF")[0]
        let document = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(document.pageCount, 3)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        XCTAssertTrue(document.string?.contains("Paragraph 120") == true)

        // Document → images: a folder named after the document with `Page N.png` inside.
        let folder = try await convert(md, to: "PNG")[0]
        XCTAssertEqual(folder.lastPathComponent, "long")
        let pages = TestSupport.directoryContents(folder)
        XCTAssertEqual(pages.count, document.pageCount)
        XCTAssertTrue(pages.contains("Page 1.png"))
        XCTAssertEqual(TestSupport.info(folder.appendingPathComponent("Page 1.png"))?.type, "public.png")
    }

    func testListsAndTablesSurvivePrinting() async throws {
        let md = try write("lists.md", "- alpha\n- beta\n\n| A | B |\n|---|---|\n| 1 | 2 |\n")
        let listPDF = try await convert(md, to: "PDF")[0]
        let text = try XCTUnwrap(PDFDocument(url: listPDF)?.string)
        XCTAssertTrue(text.contains("•"), text)
        XCTAssertTrue(text.contains("alpha"), text)
        XCTAssertTrue(text.contains("A") && text.contains("B"), text)
    }

    // MARK: Other sources

    func testPlainTextToDocxMarkdownAndHTML() async throws {
        let txt = try write("note.txt", "First paragraph.\n\nSecond paragraph with café ✓.")
        let noteMD = try String(contentsOf: try await convert(txt, to: "MD")[0])
        XCTAssertTrue(noteMD.contains("Second paragraph with café ✓."), noteMD)
        let noteHTML = try String(contentsOf: try await convert(txt, to: "HTML")[0])
        XCTAssertTrue(noteHTML.contains("First paragraph."), noteHTML)
        let docx = try await convert(txt, to: "DOCX")[0]
        let roundTrip = try String(contentsOf: try await convert(docx, to: "TXT")[0])
        XCTAssertTrue(roundTrip.contains("café ✓"))
    }

    func testRTFAndRTFDSourcesAreRead() async throws {
        let html = try write("src.html", "<html><body><h1>Rich</h1><p>Some <b>bold</b> text</p></body></html>")
        let rtf = directory.appendingPathComponent("rich.rtf")
        try TestSupport.run("/usr/bin/textutil", ["-convert", "rtf", "-output", rtf.path, html.path])
        let rtfd = directory.appendingPathComponent("rich.rtfd")
        try TestSupport.run("/usr/bin/textutil", ["-convert", "rtfd", "-output", rtfd.path, html.path])

        for source in [rtf, rtfd] {
            let md = try String(contentsOf: try await convert(source, to: "MD")[0])
            XCTAssertTrue(md.contains("Some **bold** text"), "\(source.lastPathComponent): \(md)")
            XCTAssertTrue(md.contains("Rich"), md)
        }
        XCTAssertEqual(Availability.shared.conversion(from: "RTFD", to: "PDF"), true)
        XCTAssertFalse(FormatCatalog.conversionTargets(from: "RTF").contains("RTF"), "RTF is input-only")
    }

    func testTextClippingIsReadFromItsPropertyList() async throws {
        let clipping = directory.appendingPathComponent("snippet.textClipping")
        let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": Data("Clipped words ✓".utf8)]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: clipping)
        let txt = try String(contentsOf: try await convert(clipping, to: "TXT")[0])
        XCTAssertTrue(txt.contains("Clipped words ✓"), txt)
    }

    func testBrokenDocumentsFailWithAMessageAndLeaveNothing() async throws {
        let bad = directory.appendingPathComponent("bad.docx")
        try Data("this is not a docx".utf8).write(to: bad)
        do {
            _ = try await convert(bad, to: "PDF")
            XCTFail("expected a failure")
        } catch {
            XCTAssertFalse(((error as? LocalizedError)?.errorDescription ?? "").isEmpty)
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["bad.docx"])
    }

    // MARK: PDF → DOCX / EPUB

    func testPDFWithTextBecomesDocxAndEpub() async throws {
        let pdf = directory.appendingPathComponent("paper.pdf")
        TestSupport.makePDF(pages: [[("Findings", 24), ("The quick brown fox jumps over the lazy dog.", 12), ("Second sentence here.", 12)]], at: pdf)

        let docx = try await convert(pdf, to: "DOCX")[0]
        let words = try String(contentsOf: try await convert(docx, to: "TXT")[0])
        XCTAssertTrue(words.contains("quick brown fox"), words)

        let epub = try await convert(pdf, to: "EPUB")[0]
        let epubHTML = try await EPUB.read(epub).html
        XCTAssertTrue(epubHTML.contains("quick brown fox"), epubHTML)
    }

    // MARK: Capability

    func testUnimplementedOfficeFormatsStayHidden() {
        for (from, to) in [("DOCX", "PAGES"), ("PDF", "PAGES"), ("PDF", "PPTX"), ("PDF", "XLSX"), ("PPTX", "PDF"), ("PPT", "PNG")] {
            XCTAssertFalse(Availability.shared.conversion(from: from, to: to), "\(from)→\(to)")
        }
        XCTAssertTrue(Availability.shared.conversion(from: "DOCX", to: "PDF"))
        XCTAssertTrue(Availability.shared.conversion(from: "PDF", to: "DOCX"))
    }
}
