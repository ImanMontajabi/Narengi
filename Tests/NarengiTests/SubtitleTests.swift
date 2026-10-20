import XCTest
@testable import Narengi

final class SubtitleTests: XCTestCase {
    private let srt = "1\n00:00:01,000 --> 00:00:03,500\nHello <i>there</i>\n\n2\n00:01:02,250 --> 00:01:04,000\nSecond\nline\n\n"

    func testParsesSRTCues() throws {
        let cues = try SubtitleEngine.parse(srt)
        XCTAssertEqual(cues, [
            .init(startMs: 1000, endMs: 3500, text: "Hello <i>there</i>"),
            .init(startMs: 62_250, endMs: 64_000, text: "Second\nline"),
        ])
    }

    func testTimeFormatsAcceptBothSeparatorsAndShortClocks() {
        XCTAssertEqual(SubtitleEngine.parseTime("01:02:03,456"), 3_723_456)
        XCTAssertEqual(SubtitleEngine.parseTime("01:02:03.456"), 3_723_456)
        XCTAssertEqual(SubtitleEngine.parseTime("02:03.5"), 123_500)
        XCTAssertNil(SubtitleEngine.parseTime("nonsense"))
        XCTAssertEqual(SubtitleEngine.formatTime(3_723_456, separator: ","), "01:02:03,456")
    }

    func testSRTToVTTAndBack() throws {
        let cues = try SubtitleEngine.parse(srt)
        let vtt = try SubtitleEngine.write(cues, as: "VTT")
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:03.500"))
        XCTAssertEqual(try SubtitleEngine.parse(vtt), cues)
        XCTAssertTrue(try SubtitleEngine.write(try SubtitleEngine.parse(vtt), as: "SRT").contains("1\n00:00:01,000 --> 00:00:03,500"))
    }

    func testVTTWithCueSettingsAndMinuteOnlyClocks() throws {
        let vtt = "WEBVTT\n\n00:01.000 --> 00:02.000 align:start position:0%\n<v Ann>Hi</v>\n\n"
        let cues = try SubtitleEngine.parse(vtt)
        XCTAssertEqual(cues.first?.startMs, 1000)
        XCTAssertEqual(cues.first?.endMs, 2000)
    }

    func testTXTDropsTagsAndRepeatedLines() throws {
        let cues = try SubtitleEngine.parse("1\n00:00:01,000 --> 00:00:02,000\n<i>Same</i>\n\n2\n00:00:02,000 --> 00:00:03,000\nSame\nNext\n\n")
        XCTAssertEqual(try SubtitleEngine.write(cues, as: "TXT"), "Same\nNext\n")
    }

    func testSRTKeepsBasicTagsButStripsTheRest() throws {
        let cues = try SubtitleEngine.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n<c.yellow><i>Hi</i></c>\n\n")
        XCTAssertTrue(try SubtitleEngine.write(cues, as: "SRT").contains("<i>Hi</i>"))
        XCTAssertFalse(try SubtitleEngine.write(cues, as: "SRT").contains("yellow"))
    }

    func testBOMIsStrippedAndGarbageIsRejected() throws {
        XCTAssertEqual(try SubtitleEngine.decode(Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8))), "hi")
        XCTAssertThrowsError(try SubtitleEngine.decode(Data([0xFF, 0xFE, 0x00])))
        XCTAssertThrowsError(try SubtitleEngine.parse("no cues in here"))
    }

    func testConvertsFilesThroughTheService() async throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("movie.srt")
        try srt.write(to: file, atomically: true, encoding: .utf8)
        for (target, expect) in [("VTT", "WEBVTT"), ("TXT", "Hello")] {
            let out = try await ConversionService.run(source: file, options: ConversionOptions(sourceFormat: "SRT", targetFormat: target))
            XCTAssertTrue(try String(contentsOf: out[0]).contains(expect), target)
        }
        XCTAssertEqual(TestSupport.directoryContents(dir), ["movie.srt", "movie.txt", "movie.vtt"])
    }
}
