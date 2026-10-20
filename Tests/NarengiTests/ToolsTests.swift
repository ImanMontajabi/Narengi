import XCTest
@testable import Narengi

final class ToolsTests: XCTestCase {
    func testThereAre29ToolsWithUniqueIDs() {
        XCTAssertEqual(ToolID.allCases.count, 29)
        XCTAssertEqual(Set(ToolID.allCases.map(\.info.id)).count, 29)
    }

    func testSingleImageGetsAllEightTools() {
        XCTAssertEqual(ToolID.tools(for: "JPG", count: 1),
                       [.compress, .removeMetadata, .readQR, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage])
    }

    func testManyImagesKeepOnlyBatchCapableTools() {
        XCTAssertEqual(ToolID.tools(for: "PNG", count: 3), [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage])
        XCTAssertEqual(ToolID.tools(for: "SVG", count: 1), [])
        XCTAssertEqual(ToolID.tools(for: "SVG", count: 2), [.createPDF, .createCollage])
    }

    func testVideoAudioPDFAndArchiveLists() {
        XCTAssertEqual(ToolID.tools(for: "MP4", count: 1).count, 10)
        XCTAssertTrue(ToolID.tools(for: "MOV", count: 1).contains(.redactAudio), "video files with sound can be bleeped")
        XCTAssertEqual(ToolID.tools(for: "MP4", count: 2), [.compress, .removeMetadata, .muteVideo, .joinVideos])
        XCTAssertEqual(ToolID.tools(for: "WAV", count: 1),
                       [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio])
        XCTAssertEqual(ToolID.tools(for: "WAV", count: 2), [.compress, .removeMetadata, .normalizeAudio])
        XCTAssertEqual(ToolID.tools(for: "PDF", count: 1), [.compress, .removeMetadata, .readQR, .organizePDF, .splitPDF, .annotatePDF, .redactPDF])
        XCTAssertEqual(ToolID.tools(for: "PDF", count: 2), [.compress, .removeMetadata, .splitPDF, .mergePDF])
        XCTAssertEqual(ToolID.tools(for: "GIF", count: 1), [.removeMetadata])
        XCTAssertEqual(ToolID.tools(for: "RAR", count: 1), [.extractArchive])
        XCTAssertEqual(ToolID.tools(for: "DOCX", count: 1), [])
    }

    func testMixedSelectionsIntersectInFirstFilesOrder() {
        XCTAssertEqual(ToolID.tools(forSelection: ["JPG", "PNG"]), [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage])
        XCTAssertEqual(ToolID.tools(forSelection: ["JPG", "MP3"]), [.compress, .removeMetadata])
        XCTAssertEqual(ToolID.tools(forSelection: ["JPG", "PDF"]), [.compress, .removeMetadata])
        XCTAssertTrue(ToolID.tools(forSelection: []).isEmpty)
    }

    func testInteractiveAndCombiningFlags() {
        XCTAssertTrue(ToolID.cropImage.isInteractive)
        XCTAssertFalse(ToolID.compress.isInteractive)
        XCTAssertTrue(ToolID.mergePDF.combinesInputs)
        XCTAssertFalse(ToolID.compress.combinesInputs)
    }

    func testWhichToolsOpenWindows() {
        XCTAssertTrue(ToolID.compress.opensPanel(forCount: 1))
        XCTAssertFalse(ToolID.compress.opensPanel(forCount: 3))
        XCTAssertTrue(ToolID.removeMetadata.opensPanel(forCount: 1))
        XCTAssertFalse(ToolID.removeMetadata.opensPanel(forCount: 2))
        XCTAssertTrue(ToolID.readQR.opensPanel(forCount: 1))
        XCTAssertTrue(ToolID.organizePDF.opensPanel(forCount: 1))
        XCTAssertFalse(ToolID.splitPDF.opensPanel(forCount: 1))
        XCTAssertFalse(ToolID.mergePDF.opensPanel(forCount: 2))
    }

    func testActionsAreTheSixInWheelOrder() {
        XCTAssertEqual(ActionID.allCases.map(\.rawValue), ["airDrop", "float", "copy", "move", "copyPath", "terminal"])
        XCTAssertEqual(ActionID.pathsAsText([URL(fileURLWithPath: "/a/b c.txt"), URL(fileURLWithPath: "/d")]), "/a/b c.txt\n/d")
        XCTAssertEqual(ActionID.terminalDirectory(for: URL(fileURLWithPath: "/x/y/z.txt"), isDirectory: false).path, "/x/y")
        XCTAssertEqual(ActionID.terminalDirectory(for: URL(fileURLWithPath: "/x/y"), isDirectory: true).path, "/x/y")
    }
}
