import AppKit
import XCTest
@testable import Narengi

@MainActor
final class MediaEditorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Models

    func testTimeFormattingAndParsing() {
        XCTAssertEqual(TimeFormat.string(0), "0:00.0")
        XCTAssertEqual(TimeFormat.string(65.34), "1:05.3")
        XCTAssertEqual(TimeFormat.string(3725.5), "1:02:05.5")
        XCTAssertEqual(TimeFormat.seconds(from: "12"), 12)
        XCTAssertEqual(TimeFormat.seconds(from: "12,5"), 12.5)
        XCTAssertEqual(TimeFormat.seconds(from: "1:05.5"), 65.5)
        XCTAssertEqual(TimeFormat.seconds(from: "1:02:05"), 3725)
        XCTAssertNil(TimeFormat.seconds(from: "abc"))
        XCTAssertNil(TimeFormat.seconds(from: "1:2:3:4"))
        XCTAssertNil(TimeFormat.seconds(from: "-3"))
    }

    func testTrimModelKeepsAValidRange() {
        let model = TrimModel(duration: 10)
        XCTAssertTrue(model.isFullRange)
        model.setStart(4)
        XCTAssertEqual(model.previewTime, 4)
        model.setEnd(2)  // can't end before the start
        XCTAssertEqual(model.end, 4 + TrimModel.minimumLength, accuracy: 1e-9)
        model.setEnd(99)
        XCTAssertEqual(model.end, 10)
        model.setStart(-5)
        XCTAssertEqual(model.start, 0)
        model.setStart(50)  // can't start after the end
        XCTAssertEqual(model.start, 10 - TrimModel.minimumLength, accuracy: 1e-9)
        model.setStart(2)
        model.setEnd(5)
        XCTAssertEqual(model.keptLength, 3)
        XCTAssertEqual(model.summary, "Keeping 0:03.0 of 0:10.0")
        XCTAssertFalse(model.isFullRange)
    }

    func testBleepModelMergesAndRemovesStretches() {
        let model = BleepModel(duration: 10)
        XCTAssertFalse(model.add(start: 3, end: 3.001), "too short")
        XCTAssertTrue(model.add(start: 1, end: 2))
        XCTAssertTrue(model.add(start: 5, end: 6))
        XCTAssertTrue(model.add(start: 1.5, end: 5.5), "bridging stretch merges both")
        XCTAssertEqual(model.intervals.map { [$0.start, $0.end] }, [[1, 6]])
        XCTAssertTrue(model.add(start: 9, end: 40), "clamped to the length")
        XCTAssertEqual(model.intervals.last?.end, 10)
        XCTAssertEqual(model.totalBleeped, 6)
        model.selection = 7...8
        model.addSelection()
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.intervals.count, 3)
        model.remove(model.intervals[1].id)
        XCTAssertEqual(model.intervals.count, 2)
        XCTAssertTrue(model.summary.contains("2 stretches"))
        model.clear()
        XCTAssertTrue(model.summary.hasPrefix("Drag across"))
        XCTAssertFalse(model.add(start: 5, end: 5), "empty")
    }

    func testRedactVideoModelMapsMarksAndRange() {
        let model = VideoRedactModel(duration: 8)
        XCTAssertTrue(model.redactions.isEmpty)
        model.markup.kind = .pixelate
        model.markup.begin(at: CGPoint(x: 0.6, y: 0.2))
        model.markup.update(to: CGPoint(x: 0.2, y: 0.5))
        model.markup.end()
        model.markup.kind = .blackout
        model.markup.begin(at: CGPoint(x: 0.1, y: 0.1))
        model.markup.update(to: CGPoint(x: 0.3, y: 0.3))
        model.markup.end()
        XCTAssertEqual(model.redactions.map(\.style), [.pixelate, .blackout])
        XCTAssertEqual(model.redactions[0].rect.minX, 0.2, accuracy: 1e-9, "corners are normalised")
        XCTAssertEqual(model.range.start, nil)
        XCTAssertEqual(model.range.end, nil)
        model.limitToRange = true
        XCTAssertNil(model.range.start)
        model.setStart(2)
        model.setEnd(5)
        XCTAssertEqual(model.range.start, 2)
        XCTAssertEqual(model.range.end, 5)
        model.setPreview(99)
        XCTAssertEqual(model.previewTime, 8)
    }

    // MARK: - Windows

    private func spin(until condition: @MainActor () -> Bool, timeout: TimeInterval = 6) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 100_000_000) }
        try? await Task.sleep(nanoseconds: 700_000_000)  // let frames and waveforms arrive
    }

    private func snapshot(_ window: NSWindow, name: String) throws -> NSBitmapImageRep {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        if let out = ProcessInfo.processInfo.environment["NARENGI_SNAPSHOT_DIR"], let png = rep.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    private func hasContent(_ rep: NSBitmapImageRep) -> Bool {
        var colors = Set<UInt32>()
        for x in stride(from: 0, to: rep.pixelsWide, by: 9) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 9) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        return colors.count > 8
    }

    func testTheFourMediaToolWindowsOpenAndRender() async throws {
        guard Availability.shared.media.hasFFmpeg, (try? MediaEngine().h264Arguments(crf: 20)) != nil else { throw XCTSkip("ffmpeg with H.264 isn't available") }
        let clip = try TestSupport.makeMP4(in: dir, seconds: 6, size: "320x240")
        let queue = JobQueue()
        let panels = ToolPanels(queue: queue, settings: .shared)
        defer { panels.closeAll() }
        for (tool, name) in [(ToolID.trimVideo, "trim-video"), (.cropVideo, "crop-video"), (.redactVideo, "redact-video"), (.redactAudio, "bleep-audio")] {
            let before = panels.openWindowCount
            panels.present(tool, files: [clip], formats: ["MP4"], policy: OutputPolicy())
            await spin(until: { panels.openWindowCount > before })
            XCTAssertEqual(panels.openWindowCount, before + 1, "\(tool) opens one window")
            let window = try XCTUnwrap(panels.windows.last)
            XCTAssertTrue(window.isVisible)
            XCTAssertTrue(hasContent(try snapshot(window, name: name)), "\(tool) window isn't blank")
        }
        XCTAssertTrue(queue.jobs.isEmpty, "opening a window queues nothing")
    }

    func testBleepWindowSaveRunsTheJobFromTheWheel() async throws {
        guard Availability.shared.media.hasFFmpeg, (try? MediaEngine().h264Arguments(crf: 20)) != nil else { throw XCTSkip("ffmpeg with H.264 isn't available") }
        let wav = try TestSupport.makeWAV(in: dir, seconds: 3)
        let queue = JobQueue()
        // The tool's petal opens a window (a stub records it); the window's Save runs the configured job.
        final class Stub: ToolPanelPresenting {
            var tools: [ToolID] = []
            func present(_ tool: ToolID, files: [URL], formats: [String], policy: OutputPolicy) { tools.append(tool) }
        }
        let stub = Stub()
        let dispatcher = JobDispatcher(queue: queue, settings: .shared, actions: nil, panels: stub)
        XCTAssertTrue(dispatcher.handle(.redactAudio, files: [wav], policy: OutputPolicy()).isEmpty)
        XCTAssertEqual(stub.tools, [.redactAudio])
        let job = dispatcher.run(.bleep([BleepInterval(start: 1, end: 2)]), files: [wav], formats: ["WAV"], policy: OutputPolicy())
        await queue.waitUntilIdle()
        guard case .finished(let outputs) = job.state else { return XCTFail("\(job.state)") }
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["tone Bleeped.wav"])
    }
}
