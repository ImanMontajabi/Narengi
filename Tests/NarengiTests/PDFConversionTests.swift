import PDFKit
import XCTest
@testable import Narengi

final class PDFConversionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestSupport.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func body(_ page: Int) -> [(String, CGFloat)] {
        [("Hello page \(page) first line", 12), ("and the second line of page \(page)", 12),
         ("Tom & Jerry <3 quotes", 12), ("Another body line here", 12), ("Yet another body line", 12)]
    }

    private func makeThreePagePDF(name: String = "report.pdf") -> URL {
        let url = directory.appendingPathComponent(name)
        TestSupport.makePDF(pages: [
            [("Big Title", 28)] + body(1),
            body(2),
            body(3),
        ], at: url)
        return url
    }

    private func convert(_ source: URL, to target: String, dpi: Int = 72) async throws -> [URL] {
        let options = ConversionOptions(sourceFormat: "PDF", targetFormat: target, quality: 0.8, preserveMetadata: true, dpi: dpi)
        return try await ConversionService.run(source: source, options: options)
    }

    // MARK: - PDF → images

    func testMultiPagePDFToPNGMakesNumberedFolder() async throws {
        let pdf = makeThreePagePDF()
        let outputs = try await convert(pdf, to: "PNG")
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].lastPathComponent, "report")
        XCTAssertEqual(TestSupport.directoryContents(outputs[0]), ["Page 1.png", "Page 2.png", "Page 3.png"])

        let first = try XCTUnwrap(TestSupport.info(outputs[0].appendingPathComponent("Page 1.png")))
        XCTAssertEqual(first.type, "public.png")
        XCTAssertEqual([first.width, first.height], [612, 792])
    }

    func testSinglePagePDFToJPGMakesOneFileBesideSource() async throws {
        let url = directory.appendingPathComponent("one.pdf")
        TestSupport.makePDF(pages: [body(1)], at: url)
        let outputs = try await convert(url, to: "JPG")
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["one.jpg"])
        XCTAssertEqual(TestSupport.info(outputs[0])?.type, "public.jpeg")
    }

    func testRenderDPIScalesThePixelSize() async throws {
        let url = directory.appendingPathComponent("dpi.pdf")
        TestSupport.makePDF(pages: [body(1)], at: url)
        let low = try await convert(url, to: "PNG", dpi: 72)[0]
        let high = try await convert(url, to: "PNG", dpi: 144)[0]
        XCTAssertEqual(TestSupport.info(low)?.width, 612)
        XCTAssertEqual(TestSupport.info(high)?.width, 1224)
        XCTAssertEqual(TestSupport.info(high)?.height, 1584)
    }

    func testPageBackgroundIsWhiteNotTransparent() async throws {
        let url = directory.appendingPathComponent("white.pdf")
        TestSupport.makePDF(pages: [body(1)], at: url)
        let output = try await convert(url, to: "PNG")[0]
        let corner = try XCTUnwrap(TestSupport.pixel(output, x: 3, y: 3))
        XCTAssertEqual(corner, [255, 255, 255, 255])
    }

    func testPDFToTIFFIsOneMultipageFile() async throws {
        let outputs = try await convert(makeThreePagePDF(), to: "TIFF")
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["report.tiff"])
        XCTAssertEqual(TestSupport.info(outputs[0])?.frames, 3)
    }

    // MARK: - PDF → text

    func testPDFToTXTKeepsTextAndPageOrder() async throws {
        let output = try await convert(makeThreePagePDF(), to: "TXT")[0]
        let text = try String(contentsOf: output)
        XCTAssertTrue(text.contains("Big Title"))
        let one = try XCTUnwrap(text.range(of: "page 1"))
        let three = try XCTUnwrap(text.range(of: "page 3"))
        XCTAssertLessThan(one.lowerBound, three.lowerBound)
    }

    func testPDFToMarkdownDetectsHeadingsAndJoinsLines() async throws {
        let output = try await convert(makeThreePagePDF(), to: "MD")[0]
        let markdown = try String(contentsOf: output)
        XCTAssertTrue(markdown.hasPrefix("# Big Title"), markdown)
        XCTAssertTrue(markdown.contains("Hello page 1 first line and the second line of page 1"), markdown)
    }

    func testPDFToHTMLIsEscapedAndStructured() async throws {
        let output = try await convert(makeThreePagePDF(), to: "HTML")[0]
        let html = try String(contentsOf: output)
        XCTAssertTrue(html.contains("<h1>Big Title</h1>"), html)
        XCTAssertTrue(html.contains("<p>"))
        XCTAssertTrue(html.contains("Tom &amp; Jerry &lt;3 quotes"), html)
        XCTAssertFalse(html.contains("Tom & Jerry"))
        XCTAssertTrue(html.contains("<meta charset=\"utf-8\">"))
    }

    func testPDFWithoutTextReportsNoText() async throws {
        let url = directory.appendingPathComponent("blank.pdf")
        TestSupport.makePDF(pages: [[]], at: url)
        do {
            _ = try await convert(url, to: "TXT")
            XCTFail("expected noText")
        } catch {
            XCTAssertEqual(error as? ConversionError, .noText)
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["blank.pdf"], "failed output must not be left behind")
    }

    func testUnreadablePDFFailsCleanly() async throws {
        let url = directory.appendingPathComponent("junk.pdf")
        try Data("%PDF-nope".utf8).write(to: url)
        do {
            _ = try await convert(url, to: "PNG")
            XCTFail("expected decodeFailed")
        } catch {
            XCTAssertEqual(error as? ConversionError, .decodeFailed("junk.pdf"))
        }
    }

    // MARK: - Images → PDF

    func testImageToPDFProducesOnePagePage() async throws {
        let png = try TestSupport.write(TestSupport.makeImage(width: 144, height: 72), as: "public.png",
                                        to: directory.appendingPathComponent("pic.png"))
        let options = ConversionOptions(sourceFormat: "PNG", targetFormat: "PDF")
        let outputs = try await ConversionService.run(source: png, options: options)

        let document = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertEqual(document.pageCount, 1)
        // 144×72 px at the default 72 dpi is 144×72 pt.
        let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 144, accuracy: 0.5)
        XCTAssertEqual(bounds.height, 72, accuracy: 0.5)
    }

    func testHighDPIImageKeepsItsPhysicalSizeInPDF() throws {
        let image = TestSupport.makeImage(width: 300, height: 600)
        let url = directory.appendingPathComponent("hi.pdf")
        try PDFEngine.makePDF(from: [(image, 300)], to: url)
        let bounds = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 72, accuracy: 0.5)   // 300 px at 300 dpi = 1 inch
        XCTAssertEqual(bounds.height, 144, accuracy: 0.5)
    }

    func testSeveralImagesBecomeSeveralPages() throws {
        let url = directory.appendingPathComponent("many.pdf")
        try PDFEngine.makePDF(
            from: [(TestSupport.makeImage(width: 100, height: 100), 72),
                   (TestSupport.makeImage(width: 200, height: 50), 72),
                   (TestSupport.makeImage(width: 50, height: 200), 72)],
            to: url)
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 3)
        XCTAssertEqual(try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox).width, 200, accuracy: 0.5)
    }

    func testPDFRoundTripThroughPNGAndBack() async throws {
        let pdf = directory.appendingPathComponent("one.pdf")
        TestSupport.makePDF(pages: [body(1)], at: pdf)
        let png = try await convert(pdf, to: "PNG", dpi: 72)[0]

        let options = ConversionOptions(sourceFormat: "PNG", targetFormat: "PDF")
        let back = try await ConversionService.run(source: png, options: options)[0]
        let page = try XCTUnwrap(PDFDocument(url: back)?.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 612, accuracy: 0.5)
    }
}
