import PDFKit
import XCTest
@testable import Narengi

final class OCRTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func textImage(_ name: String = "scan.png") throws -> URL {
        try TestSupport.write(TestSupport.makeTextImage(["Hello Narengi", "Second line"]), as: "public.png",
                              to: directory.appendingPathComponent(name))
    }

    private func convert(_ source: URL, from: String, to: String) async throws -> URL {
        try await ConversionService.run(source: source, options: ConversionOptions(sourceFormat: from, targetFormat: to))[0]
    }

    func testVisionReadsGeneratedText() throws {
        let lines = try OCREngine.recognize(TestSupport.makeTextImage(["Hello Narengi"]))
        XCTAssertTrue(lines.contains { $0.text.localizedCaseInsensitiveContains("Hello") }, "\(lines)")
    }

    func testParagraphGrouping() {
        func line(_ text: String, _ top: Double) -> OCREngine.Line { .init(text: text, x: 0.1, top: top, height: 0.02) }
        let lines = [line("second para", 0.30), line("Title", 0.05), line("first para starts and con-", 0.12), line("tinues here", 0.145)]
        XCTAssertEqual(OCREngine.paragraphs(lines), ["Title", "first para starts and continues here", "second para"])
        XCTAssertTrue(OCREngine.paragraphs([]).isEmpty)
    }

    func testImageToTextMarkdownAndDocx() async throws {
        let image = try textImage()
        let txt = try String(contentsOf: try await convert(image, from: "PNG", to: "TXT"))
        XCTAssertTrue(txt.localizedCaseInsensitiveContains("Hello"), txt)
        let md = try String(contentsOf: try await convert(image, from: "PNG", to: "MD"))
        XCTAssertTrue(md.localizedCaseInsensitiveContains("Narengi"), md)

        let docx = try await convert(image, from: "PNG", to: "DOCX")
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-tq", docx.path], tool: "unzip")  // async: no blocking wait on a user-initiated thread
        let words = try String(contentsOf: try await convert(docx, from: "DOCX", to: "TXT"))
        XCTAssertTrue(words.localizedCaseInsensitiveContains("Hello"), words)
    }

    func testImageWithoutTextBecomesADocxHoldingThePicture() async throws {
        let blank = try TestSupport.write(TestSupport.makeImage(width: 200, height: 120), as: "public.png",
                                          to: directory.appendingPathComponent("photo.png"))
        let docx = try await convert(blank, from: "PNG", to: "DOCX")
        let listing = try TestSupport.archiveListing(docx)
        XCTAssertTrue(listing.contains("word/media/image1.png"), "\(listing)")

        do {
            _ = try await convert(blank, from: "PNG", to: "TXT")
            XCTFail("expected noText")
        } catch {
            XCTAssertEqual(error as? ConversionError, .noText)
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["photo.docx", "photo.png"])
    }

    func testScannedPDFIsReadWithOCR() async throws {
        // A PDF made only of a picture of text: nothing selectable, so OCR must kick in.
        let scan = directory.appendingPathComponent("scan.pdf")
        try PDFEngine.makePDF(from: [(TestSupport.makeTextImage(["Scanned page text"]), 150)], to: scan)
        XCTAssertNil(PDFEngine.selectableText(try XCTUnwrap(PDFDocument(url: scan))))

        for target in ["TXT", "MD", "HTML"] {
            let out = try String(contentsOf: try await convert(scan, from: "PDF", to: target))
            XCTAssertTrue(out.localizedCaseInsensitiveContains("Scanned"), "\(target): \(out)")
        }
        let docx = try await convert(scan, from: "PDF", to: "DOCX")
        let docxText = try String(contentsOf: try await convert(docx, from: "DOCX", to: "TXT"))
        XCTAssertTrue(docxText.localizedCaseInsensitiveContains("Scanned"), docxText)
    }

    func testBlankScanReportsNoTextAndLeavesNothing() async throws {
        let blank = directory.appendingPathComponent("blank.pdf")
        try PDFEngine.makePDF(from: [(ImageEngine.flatten(TestSupport.makeImage(width: 300, height: 400, transparentLeftHalf: true)), 72)], to: blank)
        do {
            _ = try await convert(blank, from: "PDF", to: "TXT")
            XCTFail("expected noText")
        } catch {
            XCTAssertEqual(error as? ConversionError, .noText)
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["blank.pdf"])
    }
}
