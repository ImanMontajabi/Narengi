import XCTest
@testable import Narengi

final class NamingRulesTests: XCTestCase {
    private func taken(_ names: [String]) -> (String) -> Bool {
        let set = Set(names.map { $0.lowercased() })
        return { set.contains($0.lowercased()) }
    }

    func testStems() {
        XCTAssertEqual(NamingRules.stem(of: "photo.jpg"), "photo")
        XCTAssertEqual(NamingRules.stem(of: "my.photo.JPG"), "my.photo")
        XCTAssertEqual(NamingRules.stem(of: "backup.tar.gz"), "backup")
        XCTAssertEqual(NamingRules.stem(of: "backup.TGZ"), "backup")
        XCTAssertEqual(NamingRules.stem(of: "README"), "README")
        XCTAssertEqual(NamingRules.stem(of: ".bashrc"), ".bashrc")
    }

    func testCollisionsTakeTheNextFreeNumberStartingAtTwo() {
        XCTAssertEqual(NamingRules.conversionOutputName(fileName: "sample.wav", target: "MP3", taken: taken(["sample.wav", "sample.mp3"])),
                       "sample 2.mp3")
        XCTAssertEqual(NamingRules.conversionOutputName(fileName: "sample.wav", target: "MP3", taken: taken(["sample.mp3", "sample 2.mp3"])),
                       "sample 3.mp3")
        XCTAssertEqual(NamingRules.conversionOutputName(fileName: "sample.wav", target: "FLAC", taken: taken([])), "sample.flac")
    }

    func testNameClashesIgnoreCase() {
        XCTAssertEqual(NamingRules.conversionOutputName(fileName: "Photo.PNG", target: "JPG", taken: taken(["photo.jpg"])), "Photo 2.jpg")
    }

    func testGZIPTargetWritesTarGz() {
        XCTAssertEqual(NamingRules.conversionOutputName(fileName: "project.zip", target: "GZIP", taken: taken([])), "project.tar.gz")
        XCTAssertEqual(NamingRules.conversionOutputName(fileName: "project.tar.gz", target: "ZIP", taken: taken([])), "project.zip")
    }

    func testToolNames() {
        XCTAssertEqual(NamingRules.toolOutputName(fileName: "photo.jpg", label: "Compressed", outputFormat: "JPG", taken: taken([])),
                       "photo Compressed.jpg")
        XCTAssertEqual(NamingRules.toolOutputName(fileName: "photo.jpg", label: "Compressed", outputFormat: "JPG",
                                                  taken: taken(["photo compressed.jpg"])), "photo Compressed 2.jpg")
        XCTAssertEqual(NamingRules.toolOutputName(fileName: "little-project.zip", label: "Extracted", outputFormat: nil, taken: taken([])),
                       "little-project Extracted")
    }

    func testEveryToolHasALabelAndANamedOutput() {
        for tool in ToolID.allCases {
            let info = tool.info
            XCTAssertFalse(info.label.isEmpty)
            let name = NamingRules.toolOutputName(fileName: "clip.mov", label: info.label,
                                                  outputFormat: tool.outputFormat(for: "MOV"), taken: { _ in false })
            XCTAssertTrue(name.hasPrefix("clip \(info.label)"), name)
        }
        XCTAssertEqual(ToolID.compress.outputFormat(for: "WAV"), "FLAC")
        XCTAssertEqual(ToolID.frameImage.outputFormat(for: "JPG"), "PNG")
        XCTAssertNil(ToolID.splitPDF.outputFormat(for: "PDF"))
    }
}
