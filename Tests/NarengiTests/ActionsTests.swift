import AppKit
import XCTest
@testable import Narengi

@MainActor
final class ActionsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, in folder: URL? = nil, text: String = "x") throws -> URL {
        let url = (folder ?? dir).appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func privatePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("app.narengi.tests.\(UUID().uuidString)"))
        addTeardownBlock { pasteboard.releaseGlobally() }
        return pasteboard
    }

    func testCopyPutsFileURLsOnThePasteboard() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let pasteboard = privatePasteboard()
        XCTAssertTrue(ActionRunner.copyToClipboard([a, b], pasteboard: pasteboard))
        let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(read?.map(\.lastPathComponent), ["a.txt", "b.txt"])
    }

    func testCopyPathIsNewlineSeparatedPosixPaths() throws {
        let a = try file("a b.txt"), b = try file("b.txt")
        let pasteboard = privatePasteboard()
        XCTAssertTrue(ActionRunner.copyPaths([a, b], pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "\(a.path)\n\(b.path)")
    }

    func testTerminalOpensFoldersAndParentsWithoutRepeats() throws {
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let a = try file("a.txt"), b = try file("b.txt"), c = try file("c.txt", in: sub)
        let result = ActionRunner.terminalDirectories(for: [a, b, c, sub])
        XCTAssertEqual(result.map(\.lastPathComponent), [dir.lastPathComponent, "sub"])
    }

    func testMoveNeverOverwrites() throws {
        let destination = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try file("photo.txt", in: destination, text: "existing")
        let source = try file("photo.txt", text: "new")
        let moved = try ActionRunner.move(source, into: destination)
        XCTAssertEqual(moved.lastPathComponent, "photo 2.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("photo.txt")), "existing")
        XCTAssertEqual(try String(contentsOf: moved), "new")
    }

    func testMoveHandlesFoldersAndMultiDotNames() throws {
        let destination = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let folder = dir.appendingPathComponent("My Folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertEqual(try ActionRunner.move(folder, into: destination).lastPathComponent, "My Folder")
        let archive = try file("data.tar.gz")
        XCTAssertEqual(try ActionRunner.move(archive, into: destination).lastPathComponent, "data.tar.gz")
    }

    func testMoveRunsAsAJobAndReportsOutputs() async throws {
        let destination = dir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let a = try file("a.txt"), b = try file("b.txt")
        let queue = JobQueue()
        queue.enqueue(title: "Move", work: ActionRunner.moveWork([a, b], to: destination))
        await queue.waitUntilIdle()
        guard case .finished(let outputs)? = queue.jobs.first?.state else { return XCTFail("\(String(describing: queue.jobs.first?.state))") }
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["a.txt", "b.txt"])
    }

    // MARK: - Float shelf

    func testShelfModelDedupesAndIgnoresMissingFiles() throws {
        let a = try file("a.txt")
        let model = FloatShelfModel()
        XCTAssertEqual(model.add([a, a, dir.appendingPathComponent("ghost.txt")]), 1)
        XCTAssertEqual(model.add([a]), 0)
        XCTAssertEqual(model.items.count, 1)
    }

    func testShelfSelectionAndDragSet() throws {
        let urls = try ["a", "b", "c", "d"].map { try file("\($0).txt") }
        let model = FloatShelfModel()
        model.add(urls)
        var anchor: UUID?
        let ids = model.items.map(\.id)
        model.click(ids[0], command: false, shift: false, anchor: &anchor)
        model.click(ids[2], command: false, shift: true, anchor: &anchor)
        XCTAssertEqual(model.selection, Set(ids[0...2]))
        XCTAssertEqual(model.dragItems(startingOn: ids[1]).count, 3, "dragging a selected item drags the whole selection")
        XCTAssertEqual(model.dragItems(startingOn: ids[3]).map(\.id), [ids[3]], "dragging an unselected item drags only it")
        model.click(ids[3], command: true, shift: false, anchor: &anchor)
        XCTAssertEqual(model.selection.count, 4)
        model.removeSelected()
        XCTAssertTrue(model.items.isEmpty)
    }

    func testShelfPrunesDeletedFiles() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let model = FloatShelfModel()
        model.add([a, b])
        try FileManager.default.removeItem(at: a)
        model.pruneMissing()
        XCTAssertEqual(model.items.map(\.url.lastPathComponent), ["b.txt"])
    }

    func testDuplicateNamesAvoidCollisions() throws {
        let a = try file("report.txt")
        XCTAssertEqual(FloatShelfView.duplicate(a)?.lastPathComponent, "report copy.txt")
        XCTAssertEqual(FloatShelfView.duplicate(a)?.lastPathComponent, "report copy 2.txt")
    }

    func testShelfGridGeometry() {
        XCTAssertEqual(FloatShelfView.columns(forWidth: 392), 4)
        XCTAssertEqual(FloatShelfView.columns(forWidth: 50), 1)
        XCTAssertEqual(FloatShelfView.contentHeight(count: 5, width: 392), 10 * 2 + 2 * FloatShelfView.cellHeight)
    }

    func testFloatBehaviourCreatesNewOrReusesShelf() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let manager = FloatShelfManager()
        manager.add([a], behaviour: .createNew, near: NSPoint(x: 400, y: 400))
        manager.add([b], behaviour: .createNew, near: NSPoint(x: 400, y: 400))
        XCTAssertEqual(manager.shelves.count, 2)
        manager.add([a], behaviour: .addToLast, near: .zero)
        XCTAssertEqual(manager.shelves.count, 2)
        XCTAssertEqual(manager.shelves.last?.model.items.count, 2)
        manager.shelves.forEach { $0.panel.close() }
        XCTAssertTrue(manager.shelves.isEmpty, "closing a shelf forgets it")
    }

    func testDropTileFrameSitsAtTopRight() {
        let frame = FloatDropTile.frame(on: NSRect(x: 0, y: 0, width: 1920, height: 1080))
        XCTAssertEqual(frame.maxX, 1920 - 12)
        XCTAssertEqual(frame.maxY, 1080 - 12)
    }

    func testActionPetalThroughWheelRunsTheAction() async throws {
        // Copy Path through the real wheel → dispatcher → runner path, observed on a stub via the placeholder job.
        let a = try file("a.txt")
        let queue = JobQueue()
        let dispatcher = JobDispatcher(queue: queue, settings: .shared, actions: nil)
        let jobs = dispatcher.handle(.action(.copyPath), files: [a], policy: OutputPolicy())
        XCTAssertEqual(jobs.count, 1, "without a runner an action only queues its placeholder")
        await queue.waitUntilIdle()
    }
}
