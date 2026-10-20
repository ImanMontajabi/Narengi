import AppKit
import PDFKit
import XCTest
@testable import Narengi

@MainActor
final class ToolPanelTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Models

    func testOrganizeModelReordersRotatesAndProtectsTheLastPage() {
        let model = OrganizeModel(pageCount: 4)
        XCTAssertTrue(model.isUnchanged)
        model.move(from: 0, to: 2)
        XCTAssertEqual(model.pages.map(\.index), [1, 2, 0, 3])
        model.rotate(at: 1)
        model.rotate(at: 1)
        model.rotate(at: 1)
        model.rotate(at: 1)
        XCTAssertEqual(model.pages[1].rotation, 0, "four quarter-turns come back to upright")
        model.rotate(at: 0)
        XCTAssertEqual(model.pages[0], PDFPageEdit(index: 1, rotation: 90))
        model.delete(at: 3)
        XCTAssertEqual(model.pages.map(\.index), [1, 2, 0])
        XCTAssertFalse(model.isUnchanged)
        model.reset()
        XCTAssertTrue(model.isUnchanged)
        let single = OrganizeModel(pageCount: 1)
        single.delete(at: 0)
        XCTAssertEqual(single.pages.count, 1, "the last page can't be deleted")
        model.move(from: 9, to: 0)  // out-of-range moves are ignored
        XCTAssertTrue(model.isUnchanged)
        model.sameWidth = true
        XCTAssertFalse(model.isUnchanged)
    }

    func testCompressModelEstimateAndSpec() {
        let model = CompressModel(fileName: "a.pdf", originalBytes: 3_300_000)
        XCTAssertEqual(model.reduceBy, 50)
        XCTAssertTrue(model.estimate.hasPrefix("Output will be at most"))
        XCTAssertEqual(model.spec, CompressionSpec(mode: .percentage(50)))
        model.mode = .strong
        XCTAssertEqual(model.spec, CompressionSpec(mode: .preset(strong: true)))
        model.mode = .balanced
        XCTAssertEqual(model.spec, CompressionSpec(mode: .preset(strong: false)))
    }

    func testMetadataModelSearchRemovalAndChanges() {
        let model = MetadataModel(fileName: "a.pdf", format: "PDF", canEdit: true)
        let title = MetadataEntry(id: "PDF:Title", group: "Document", label: "Title", value: "Hello", isEditable: true)
        let creator = MetadataEntry(id: "PDF:Creator", group: "Document", label: "Creator", value: "Chrome", isEditable: true)
        model.setGroups([MetadataGroup(name: "Document", entries: [title, creator])])
        XCTAssertFalse(model.hasChanges)

        model.search = "chrom"
        XCTAssertEqual(model.visibleGroups.flatMap(\.entries).map(\.id), ["PDF:Creator"])
        model.search = "nothing"
        XCTAssertTrue(model.visibleGroups.isEmpty)
        model.search = ""

        model.setValue("New title", for: title)
        model.remove(creator.id)
        XCTAssertTrue(model.hasChanges)
        XCTAssertEqual(model.changes["PDF:Title"] ?? "x", "New title")
        XCTAssertTrue(model.changes.keys.contains("PDF:Creator"))
        if case .some(.none) = model.changes["PDF:Creator"] {} else { XCTFail("removal is a nil value") }
        model.restore(creator.id)
        model.setValue("Hello", for: title)
        XCTAssertFalse(model.hasChanges, "putting a value back is no change")
    }

    // MARK: - Wheel → dispatcher

    private final class StubPanels: ToolPanelPresenting {
        var presented: [(ToolID, [URL])] = []
        func present(_ tool: ToolID, files: [URL], formats: [String], policy: OutputPolicy) { presented.append((tool, files)) }
    }

    func testCompressOpensAWindowForOneFileButRunsForABatch() async throws {
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        for url in [a, b] { try TestSupport.write(TestSupport.makeImage(width: 600, height: 400), as: "public.jpeg", to: url, properties: [kCGImageDestinationLossyCompressionQuality: 1.0]) }
        let queue = JobQueue()
        let stub = StubPanels()
        let dispatcher = JobDispatcher(queue: queue, settings: .shared, actions: nil, panels: stub)
        XCTAssertTrue(dispatcher.handle(.compress, files: [a], policy: OutputPolicy()).isEmpty)
        XCTAssertEqual(stub.presented.map(\.0), [.compress])
        let jobs = dispatcher.handle(.compress, files: [a, b], policy: OutputPolicy())
        XCTAssertEqual(jobs.count, 2, "a batch uses the Settings preset, one job per file")
        await queue.waitUntilIdle()
        XCTAssertEqual(stub.presented.count, 1)
    }

    func testMouseUpOnSplitPetalSplitsThePDF() async throws {
        let pdf = dir.appendingPathComponent("book.pdf")
        TestSupport.makePDF(pages: [[("One", 24)], [("Two", 24)]], at: pdf)
        let queue = JobQueue()
        let dispatcher = JobDispatcher(queue: queue, settings: .shared, actions: nil, panels: StubPanels())
        let wheel = WheelController(settings: .shared)
        wheel.isAvailable = { item, formats in Availability.shared.item(item, formats: formats) }
        wheel.onSelect = { item, urls in dispatcher.handle(item, files: urls, policy: OutputPolicy()) }
        wheel.prepare(files: [pdf])
        wheel.present(.tools)
        let ids = wheel.currentItems.map(\.id)
        XCTAssertEqual(ids, ["tool.compress", "tool.removeMetadata", "tool.readQR", "tool.organizePDF", "tool.splitPDF", "tool.annotatePDF", "tool.redactPDF"])
        let index = try XCTUnwrap(ids.firstIndex(of: "tool.splitPDF"))
        XCTAssertTrue(wheel.finishDrag(at: try XCTUnwrap(wheel.pointInside(petal: index))))
        await queue.waitUntilIdle()
        guard case .finished(let outputs)? = queue.jobs.first?.state else { return XCTFail("\(String(describing: queue.jobs.first?.state))") }
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["book Pages"])
        XCTAssertEqual(TestSupport.directoryContents(dir.appendingPathComponent("book Pages")), ["book 1.pdf", "book 2.pdf"].map { $0.replacingOccurrences(of: " 1", with: " 01").replacingOccurrences(of: " 2", with: " 02") })
        wheel.dismiss()
    }

    func testMouseUpOnMergePetalMergesTheSelection() async throws {
        let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf")
        TestSupport.makePDF(pages: [[("A", 24)]], at: a)
        TestSupport.makePDF(pages: [[("B", 24)]], at: b)
        let queue = JobQueue()
        let dispatcher = JobDispatcher(queue: queue, settings: .shared, actions: nil, panels: StubPanels())
        let wheel = WheelController(settings: .shared)
        wheel.isAvailable = { item, formats in Availability.shared.item(item, formats: formats) }
        wheel.onSelect = { item, urls in dispatcher.handle(item, files: urls, policy: OutputPolicy()) }
        wheel.prepare(files: [a, b])
        wheel.present(.tools)
        let index = try XCTUnwrap(wheel.currentItems.firstIndex { $0.id == "tool.mergePDF" })
        XCTAssertTrue(wheel.finishDrag(at: try XCTUnwrap(wheel.pointInside(petal: index))))
        await queue.waitUntilIdle()
        XCTAssertEqual(queue.jobs.count, 1, "merging is one job for the whole selection")
        XCTAssertEqual(PDFDocument(url: dir.appendingPathComponent("Merged.pdf"))?.pageCount, 2)
        wheel.dismiss()
    }

    func testActionsWheelShowsSixPetalsAndCopyPathUsesTheRunner() throws {
        let file = dir.appendingPathComponent("my file.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.narengi.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let queue = JobQueue()
        let runner = ActionRunner(settings: .shared, queue: queue, float: FloatShelfManager(), pasteboard: pasteboard)
        let dispatcher = JobDispatcher(queue: queue, settings: .shared, actions: runner, panels: nil)
        let wheel = WheelController(settings: .shared)
        wheel.isAvailable = { item, formats in Availability.shared.item(item, formats: formats) }
        wheel.onSelect = { item, urls in dispatcher.handle(item, files: urls, policy: OutputPolicy()) }
        wheel.prepare(files: [file])
        wheel.present(.actions)
        XCTAssertEqual(wheel.currentItems.map(\.id), ["action.airDrop", "action.float", "action.copy", "action.move", "action.copyPath", "action.terminal"])
        let index = try XCTUnwrap(wheel.currentItems.firstIndex { $0.id == "action.copyPath" })
        XCTAssertTrue(wheel.finishDrag(at: try XCTUnwrap(wheel.pointInside(petal: index))))
        XCTAssertEqual(pasteboard.string(forType: .string), file.path)
        XCTAssertTrue(queue.jobs.isEmpty, "copying a path needs no job")
        wheel.dismiss()
    }

    func testFloatPetalPutsTheFilesOnAShelf() throws {
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let float = FloatShelfManager()
        let queue = JobQueue()
        let runner = ActionRunner(settings: .shared, queue: queue, float: float, pasteboard: NSPasteboard(name: NSPasteboard.Name("app.narengi.tests.\(UUID().uuidString)")))
        let dispatcher = JobDispatcher(queue: queue, settings: .shared, actions: runner, panels: nil)
        dispatcher.handle(.action(.float), files: [file], policy: OutputPolicy())
        XCTAssertEqual(float.shelves.count, 1)
        XCTAssertEqual(float.shelves.first?.model.items.map(\.url.lastPathComponent), ["a.txt"])
        float.shelves.forEach { $0.panel.close() }
    }

    func testQRToolIsOnTheWheelForAnImageAndOpensAWindow() throws {
        let png = dir.appendingPathComponent("a.png")
        try TestSupport.write(TestSupport.makeImage(width: 50, height: 50), as: "public.png", to: png)
        let stub = StubPanels()
        let dispatcher = JobDispatcher(queue: JobQueue(), settings: .shared, actions: nil, panels: stub)
        dispatcher.handle(.readQR, files: [png], policy: OutputPolicy())
        XCTAssertEqual(stub.presented.map(\.0), [.readQR])
    }
}
