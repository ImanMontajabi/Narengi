import AppKit
import XCTest
@testable import Narengi

/// The full hand-off: wheel petal under the pointer → mouse-up → JobQueue → ConversionService → file on disk.
@MainActor
final class DropIntegrationTests: XCTestCase {
    private func makeFixture() throws -> (dir: URL, png: URL) {
        let dir = try TestSupport.makeTempDirectory()
        let png = try TestSupport.write(TestSupport.makeImage(width: 64, height: 48), as: "public.png", to: dir.appendingPathComponent("photo.png"))
        return (dir, png)
    }

    func testMouseUpOnPetalConvertsFileExactlyOnce() async throws {
        let (dir, png) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }

        let settings = SettingsStore.shared
        let queue = JobQueue()
        let dispatcher = JobDispatcher(queue: queue, settings: settings)
        let wheel = WheelController(settings: settings)
        wheel.isAvailable = { item, formats in Availability.shared.item(item, formats: formats) }
        let policy = OutputPolicy(location: .besideOriginal, customFolder: nil)
        var selections = 0
        wheel.onSelect = { item, urls in
            selections += 1
            dispatcher.handle(item, files: urls, policy: policy)
        }

        wheel.prepare(files: [png])
        wheel.present(.conversion)
        let items = wheel.currentItems
        let index = try XCTUnwrap(items.firstIndex { $0.id == "convert.JPG" }, "JPG petal missing: \(items.map(\.title))")
        let point = try XCTUnwrap(wheel.pointInside(petal: index))

        XCTAssertTrue(wheel.finishDrag(at: point), "mouse-up over a petal must apply it")
        XCTAssertFalse(wheel.finishDrag(at: point), "a second delivery must not run the job again")
        XCTAssertEqual(selections, 1)

        await queue.waitUntilIdle()
        XCTAssertEqual(queue.jobs.count, 1)
        guard case .finished(let outputs)? = queue.jobs.first?.state else { return XCTFail("job state: \(String(describing: queue.jobs.first?.state))") }
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["photo.jpg"])
        let output = dir.appendingPathComponent("photo.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), TestSupport.directoryContents(dir).joined(separator: ", "))
        XCTAssertEqual(TestSupport.info(output)?.width, 64)
        XCTAssertFalse(TestSupport.directoryContents(dir).contains { $0.hasPrefix(".narengi-tmp") })
    }

    func testMouseUpOutsidePetalsRunsNothing() async throws {
        let (dir, png) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = JobQueue()
        let wheel = WheelController(settings: .shared)
        wheel.isAvailable = { item, formats in Availability.shared.item(item, formats: formats) }
        var selections = 0
        wheel.onSelect = { _, _ in selections += 1 }
        wheel.prepare(files: [png])
        wheel.present(.conversion)
        XCTAssertFalse(wheel.finishDrag(at: NSPoint(x: wheel.panelCenter.x, y: wheel.panelCenter.y)))
        XCTAssertEqual(selections, 0)
        XCTAssertTrue(queue.jobs.isEmpty)
    }

    func testFileReferenceURLsResolveToPaths() throws {
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let reference = try XCTUnwrap((file as NSURL).fileReferenceURL())
        let resolved = (reference as NSURL).filePathURL ?? reference.standardizedFileURL
        XCTAssertEqual(resolved.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
    }
}
