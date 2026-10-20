import XCTest
@testable import Narengi

final class FormatCatalogTests: XCTestCase {
    func testReferenceMatrixHasTheOriginalAppsPathCount() {
        // 275 paths on the original's website + image → DOCX for the 8 image inputs.
        XCTAssertEqual(FormatCatalog.referencePathCount(), 275 + 8)
    }

    func testJPGWheelMatchesTheScreenRecordingOrder() {
        XCTAssertEqual(Array(FormatCatalog.referenceTargets(from: "JPG")),
                       ["PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "DOCX"])
    }

    func testPDFWheelMatchesTheScreenshotOrderPlusNarengiExtras() {
        // Screenshot: DOCX, PAGES, PPTX, XLSX, JPG, PNG, EPUB, TXT, MD clockwise from the top.
        XCTAssertEqual(FormatCatalog.referenceTargets(from: "PDF"),
                       ["DOCX", "PAGES", "PPTX", "XLSX", "JPG", "PNG", "EPUB", "TXT", "MD"])
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "PDF"),
                       ["DOCX", "PAGES", "PPTX", "XLSX", "JPG", "PNG", "EPUB", "TXT", "MD", "HTML", "TIFF"])
    }

    func testWAVOffersTheOtherAudioFormatsInOrder() {
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "WAV"), ["MP3", "M4A", "FLAC", "OGG", "OPUS", "AIFF", "WMA"])
    }

    func testVideoOffersGIFAndMP3AndGIFOffersVideo() {
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "MOV"), ["MP4", "MKV", "WEBM", "AVI", "WMV", "GIF", "MP3"])
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "GIF"), ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV"])
    }

    func testInputOnlyFormatsAreNeverTargets() {
        for f in FormatCatalog.allFormats {
            for t in FormatCatalog.conversionTargets(from: f) {
                XCTAssertFalse(FormatCatalog.inputOnly.contains(t), "\(f)→\(t)")
                XCTAssertNotEqual(f, t)
            }
        }
        XCTAssertFalse(FormatCatalog.conversionTargets(from: "PNG").contains("SVG"))
    }

    func testSpreadsheetsArchivesAndSubtitles() {
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "XLS"), ["XLSX", "ODS", "CSV", "TSV", "PDF"])
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "CSV"), ["XLSX", "ODS", "TSV", "PDF"])
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "RAR"), ["ZIP", "TAR", "GZIP"])
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "GZIP"), ["ZIP", "TAR"])
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "SRT"), ["VTT", "TXT"])
        XCTAssertTrue(FormatCatalog.conversionTargets(from: "HTML").isEmpty)
    }

    func testImagesAlsoOfferRecognisedTextAsExtras() {
        XCTAssertEqual(FormatCatalog.conversionTargets(from: "PNG").suffix(3), ["DOCX", "TXT", "MD"])
        XCTAssertEqual(FormatCatalog.referenceTargets(from: "PNG").last, "DOCX")
    }

    // MARK: selections

    func testSameFormatSelectionEqualsTheSingleFileWheel() {
        XCTAssertEqual(FormatCatalog.targets(forSelection: ["JPG", "JPG"]), FormatCatalog.conversionTargets(from: "JPG"))
    }

    func testMixedImageSelectionKeepsSharedTargetsAndSkipsMatchingFiles() {
        // PNG is offered (the PNG file is skipped), and so is JPG.
        XCTAssertEqual(FormatCatalog.targets(forSelection: ["JPG", "PNG"]),
                       ["PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "DOCX", "TXT", "MD", "JPG"])
    }

    func testIncompatibleOrEmptySelectionsHaveNoTargets() {
        XCTAssertTrue(FormatCatalog.targets(forSelection: ["JPG", "MP3"]).isEmpty)
        XCTAssertTrue(FormatCatalog.targets(forSelection: []).isEmpty)
    }

    func testOutputsForURLsRequireKnownFormats() {
        let jpg = URL(fileURLWithPath: "/tmp/a.jpg")
        XCTAssertEqual(FormatCatalog.outputs(for: [jpg, URL(fileURLWithPath: "/tmp/x.unknown")]), [])
        XCTAssertFalse(FormatCatalog.outputs(for: [jpg]).isEmpty)
    }

    // MARK: detection

    func testExtensionMapping() {
        XCTAssertEqual(FormatCatalog.format(for: URL(fileURLWithPath: "/tmp/a.JPEG")), "JPG")
        XCTAssertEqual(FormatCatalog.format(for: URL(fileURLWithPath: "/tmp/a.tar.gz")), "GZIP")
        XCTAssertEqual(FormatCatalog.format(for: URL(fileURLWithPath: "/tmp/a.tgz")), "GZIP")
        XCTAssertNil(FormatCatalog.format(for: URL(fileURLWithPath: "/tmp/a.unknown")))
    }

    func testFoldersHaveNoFormatButDocumentPackagesDo() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("Stuff.jpg")   // a folder that merely looks like a file
        let package = dir.appendingPathComponent("Note.rtfd")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        XCTAssertNil(FormatCatalog.detect(plain))
        XCTAssertEqual(FormatCatalog.detect(package), "RTFD")
    }
}
