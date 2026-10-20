import AppKit
import SwiftUI
import XCTest
@testable import Narengi

/// Renders Narengi's own UI for the README. It only writes files when `NARENGI_DOCS_IMAGES` names a folder:
///
///     TEST_RUNNER_NARENGI_DOCS_IMAGES=docs/images xcodebuild test -only-testing:NarengiTests/DocsImageTests …
@MainActor
final class DocsImageTests: XCTestCase {
    private var output: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["NARENGI_DOCS_IMAGES"] else { throw XCTSkip("set NARENGI_DOCS_IMAGES to render documentation images") }
        output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent("\(name).png"))
    }

    private func snapshot(_ view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func spin(_ seconds: Double = 0.8) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func testRenderWelcomeGuideAndPanels() async throws {
        let defaults = UserDefaults(suiteName: "app.narengi.tests.docs.\(UUID().uuidString)")!
        let guide = OnboardingController(settings: .shared, defaults: defaults)
        defer { guide.window?.close() }
        guide.show()
        for (step, name) in [(OnboardingStep.how, "welcome-how-it-works"), (.practice, "welcome-practice")] {
            guide.model.go(to: step)
            await spin()
            try write(try snapshot(try XCTUnwrap(guide.window?.contentView)), name)
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let panels = ToolPanels(queue: JobQueue(), settings: .shared)
        defer { panels.closeAll() }
        let photo = try XCTUnwrap(OnboardingSample.makeFile())
        panels.present(.frameImage, files: [photo], formats: ["PNG"], policy: OutputPolicy())
        await spin()
        try write(try snapshot(try XCTUnwrap(panels.windows.last?.contentView)), "tool-add-background")
        let pdf = dir.appendingPathComponent("Report.pdf")
        TestSupport.makePDF(pages: (1...8).map { [("Page \($0)", 40)] }, at: pdf)
        panels.present(.organizePDF, files: [pdf], formats: ["PDF"], policy: OutputPolicy())
        await spin()
        try write(try snapshot(try XCTUnwrap(panels.windows.last?.contentView)), "tool-organize-pdf")
    }

    func testRenderTheWheelAndSettings() async throws {
        let photo = try XCTUnwrap(OnboardingSample.makeFile())
        let wheel = WheelController(settings: .shared)
        wheel.isAvailable = { item, formats in Availability.shared.item(item, formats: formats) }
        wheel.prepare(files: [photo])
        wheel.present(.conversion)
        await spin(1.0)
        let content = try XCTUnwrap(wheel.contentViewForSnapshot)
        let rep = try snapshot(content)
        // Composite onto a dark desktop-like backdrop so the translucent glass reads on any README theme.
        let size = NSSize(width: content.bounds.width + 60, height: content.bounds.height + 60)
        let canvas = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        canvas.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        NSGradient(starting: NSColor(white: 0.16, alpha: 1), ending: NSColor(white: 0.07, alpha: 1))?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        // The snapshot has an opaque backdrop; keep only the wheel's own disc.
        let radius = WheelGeometry().backdrop - 1.5
        NSBezierPath(ovalIn: NSRect(x: size.width / 2 - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2)).addClip()
        rep.draw(in: NSRect(x: 30, y: 30, width: content.bounds.width, height: content.bounds.height))
        NSGraphicsContext.restoreGraphicsState()
        try write(canvas, "conversion-wheel")
        wheel.dismiss()

        let guide = OnboardingController(settings: .shared, defaults: UserDefaults(suiteName: "app.narengi.tests.docs.\(UUID().uuidString)")!)
        defer { guide.window?.close() }
        guide.show()
        guide.model.go(to: .setup)
        await spin()
        try write(try snapshot(try XCTUnwrap(guide.window?.contentView)), "welcome-quick-setup")
    }
}
