import XCTest
@testable import Narengi

@MainActor
final class WheelContentTests: XCTestCase {
    private let all = Availability.shared

    private func titles(_ kind: WheelKind, _ formats: [String?], availability: Availability? = nil) -> [String] {
        let a = availability ?? all
        return WheelItems.items(for: kind, formats: formats) { a.item($0, formats: formats) }.map(\.title)
    }

    func testPDFConversionWheelShowsOnlyWorkingRoutes() {
        XCTAssertEqual(titles(.conversion, ["PDF"]), ["DOCX", "JPG", "PNG", "EPUB", "TXT", "MD", "HTML", "TIFF"])
    }

    func testImageWheelMatchesTheRecordingPlusText() {
        let jpg = titles(.conversion, ["JPG"])
        XCTAssertEqual(Array(jpg.prefix(2)), ["PNG", "WEBP"])
        XCTAssertTrue(jpg.contains("DOCX"))
        XCTAssertFalse(jpg.contains("JPG"))
    }

    func testFoldersAndUnknownFilesGetOnlyActions() {
        XCTAssertTrue(titles(.conversion, [nil]).isEmpty)
        XCTAssertTrue(titles(.tools, ["JPG", nil]).isEmpty)
        XCTAssertEqual(titles(.actions, [nil]), ["AIRDROP", "FLOAT", "COPY", "MOVE", "COPY PATH", "TERMINAL"])
    }

    func testToolsWheelOnlyListsImplementedTools() {
        XCTAssertEqual(titles(.tools, ["ZIP"]), ["EXTRACT"])
        XCTAssertTrue(titles(.tools, ["DOCX"]).isEmpty)
    }

    func testMultipleFilesUseTheSelectionRule() {
        let mixed = titles(.conversion, ["JPG", "PNG"])
        XCTAssertTrue(mixed.contains("PNG") && mixed.contains("JPG"), "\(mixed)")
        XCTAssertTrue(titles(.conversion, ["JPG", "MP3"]).isEmpty)
    }

    func testPetalsCarrySymbolsOnlyForToolsAndActions() {
        let tools = WheelItems.items(for: .tools, formats: ["ZIP"]) { _ in true }
        XCTAssertEqual(tools.first?.symbol, "archivebox")
        XCTAssertNil(WheelItems.items(for: .conversion, formats: ["PDF"]) { _ in true }.first?.symbol)
        XCTAssertEqual(WheelItem.convert("MP3").name, "Convert to MP3")
        XCTAssertEqual(WheelItem.action(.copyPath).symbol, "doc.text")
    }

    func testKeyboardModeOpensOnConversionsOrFallsBackToActions() {
        XCTAssertEqual(WheelItems.initialKeyboardKind(hasConversions: true), .conversion)
        XCTAssertEqual(WheelItems.initialKeyboardKind(hasConversions: false), .actions)
    }

    func testEmptyWheelMessagesUseTheUsersOwnKeys() {
        let settings = SettingsStore.shared
        let saved = (settings.conversionModifier, settings.toolsModifier, settings.actionsModifier)
        defer { (settings.conversionModifier, settings.toolsModifier, settings.actionsModifier) = saved }

        settings.conversionModifier = .shift
        settings.toolsModifier = .command
        settings.actionsModifier = .control
        XCTAssertEqual(WheelItems.emptyMessage(for: .conversion, settings: settings),
                       "No conversions for this format. Tap Control for file actions.")
        XCTAssertEqual(WheelItems.emptyMessage(for: .tools, settings: settings),
                       "No tools for this format. Tap Shift to convert or Control for file actions.")

        settings.conversionModifier = .shiftOption
        settings.actionsModifier = .option
        XCTAssertEqual(WheelItems.emptyMessage(for: .conversion, settings: settings),
                       "No conversions for this format. Tap Option for file actions.")
        XCTAssertEqual(WheelItems.emptyMessage(for: .actions, settings: settings), "")
    }

    func testDraggedFilesDescribeThemselves() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.txt"), b = dir.appendingPathComponent("b.txt"), folder = dir.appendingPathComponent("F")
        try Data(count: 1_200_000).write(to: a)
        try Data(count: 300_000).write(to: b)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertEqual(DraggedFiles(urls: [a]).captionLines, ["1.2 MB"])
        XCTAssertEqual(DraggedFiles(urls: [a, b]).captionLines, ["2 ITEMS", "1.5 MB"])
        XCTAssertEqual(DraggedFiles(urls: [folder]).captionLines, ["FOLDER"])
        XCTAssertEqual(DraggedFiles(urls: [a, folder]).formats, ["TXT", nil])
    }

    func testModifierConflictIsReported() {
        let settings = SettingsStore.shared
        let saved = (settings.conversionModifier, settings.toolsModifier, settings.actionsModifier)
        defer { (settings.conversionModifier, settings.toolsModifier, settings.actionsModifier) = saved }
        settings.conversionModifier = .shift
        settings.toolsModifier = .shift
        XCTAssertNotNil(settings.modifierConflict)
        settings.toolsModifier = .shiftOption
        XCTAssertNil(settings.modifierConflict)
    }
}
