import AppKit
import CoreImage
import ImageIO
import PDFKit
import XCTest
@testable import Narengi

@MainActor
final class EditorWindowTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    // MARK: - Models

    func testCropModelAspectDragAndTypedSize() {
        let model = CropModel(imageSize: CGSize(width: 2550, height: 3300), imageCount: 1)
        XCTAssertTrue(model.isFullImage)
        model.selectAspect(1)  // 1:1
        XCTAssertEqual(model.rect.width, 2550)
        XCTAssertEqual(model.rect.height, 2550)
        XCTAssertFalse(model.isFullImage)
        model.beginDrag(at: CGPoint(x: 1275, y: 1500), tolerance: 20)
        model.drag(dx: 100_000, dy: 100_000)  // can't leave the image
        XCTAssertLessThanOrEqual(model.rect.maxX, 2550)
        XCTAssertLessThanOrEqual(model.rect.maxY, 3300)
        model.endDrag()
        model.selectAspect(0)
        model.setSize(width: 1000, height: 500)
        XCTAssertEqual(model.rect.size, CGSize(width: 1000, height: 500))
        model.selectAspect(2)  // 16:9, then a typed width drives the height
        model.setSize(width: 1600, height: nil)
        XCTAssertEqual(model.rect.width, 1600, accuracy: 1)
        XCTAssertEqual(model.rect.height, 900, accuracy: 1)
        model.beginDrag(at: CGPoint(x: -500, y: -500), tolerance: 20)
        let before = model.rect
        model.drag(dx: 50, dy: 50)
        XCTAssertEqual(model.rect, before, "a drag that starts outside every handle does nothing")
        XCTAssertEqual(model.spec.pixels(in: model.imageSize).width, model.rect.width.rounded())
    }

    func testMarkupModelDrawingUndoAndText() {
        let model = MarkupModel(mode: .annotate, pageCount: 3)
        XCTAssertEqual(model.tools, [.rectangle, .ellipse, .arrow, .pen, .text])
        model.begin(at: CGPoint(x: 0.1, y: 0.1))
        model.update(to: CGPoint(x: 0.5, y: 0.6))
        XCTAssertNotNil(model.draft)
        model.end()
        XCTAssertEqual(model.items.count, 1)
        model.begin(at: CGPoint(x: 0.3, y: 0.3))
        model.end()
        XCTAssertEqual(model.items.count, 1, "a click without a drag draws nothing")

        model.kind = .pen
        model.begin(at: CGPoint(x: 0.1, y: 0.1))
        for i in 1...5 { model.update(to: CGPoint(x: 0.1 + 0.05 * Double(i), y: 0.2)) }
        model.end()
        XCTAssertEqual(model.items.last?.points.count, 6)

        model.kind = .text
        model.begin(at: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(model.pendingText, CGPoint(x: 0.4, y: 0.4))
        model.addText("   ")
        XCTAssertEqual(model.items.count, 2, "blank text is dropped")
        model.begin(at: CGPoint(x: 0.4, y: 0.4))
        model.addText("Hello")
        XCTAssertEqual(model.items.last?.text, "Hello")
        XCTAssertNil(model.pendingText)

        model.currentPage = 2
        XCTAssertTrue(model.items.isEmpty, "marks belong to their page")
        model.kind = .rectangle
        model.begin(at: CGPoint(x: -1, y: 2))
        model.update(to: CGPoint(x: 5, y: -5))
        XCTAssertEqual(model.draft?.points, [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)], "points stay inside the page")
        model.end()
        XCTAssertEqual(model.totalItems, 4)
        model.undo()
        XCTAssertTrue(model.items.isEmpty)
        model.currentPage = 0
        model.clearPage()
        XCTAssertFalse(model.hasItems)
    }

    func testRedactModelOffersCoverToolsAndCountsFlattenedPages() {
        let model = MarkupModel(mode: .redact, pageCount: 2)
        XCTAssertEqual(model.tools, [.blackout, .blur, .pixelate])
        XCTAssertEqual(model.kind, .blackout)
        model.begin(at: CGPoint(x: 0.1, y: 0.1))
        model.update(to: CGPoint(x: 0.4, y: 0.4))
        model.end()
        XCTAssertEqual(model.redactedPageCount, 1)
        XCTAssertTrue(model.items[0].isRedaction)
    }

    func testAdjustAndFrameModelsRenderPreviews() throws {
        let url = dir.appendingPathComponent("p.png")
        try TestSupport.write(TestSupport.makeImage(width: 640, height: 480), as: "public.png", to: url)
        let image = try EditorImage.load(url, previewEdge: 320)
        XCTAssertEqual(image.fullSize, CGSize(width: 640, height: 480))
        XCTAssertEqual(image.preview.width, 320)

        let adjust = AdjustModel(image: image)
        let before = adjust.preview
        adjust.adjustments[.exposure] = 80
        XCTAssertFalse(adjust.preview === before)
        adjust.reset()
        XCTAssertTrue(adjust.adjustments.isIdentity)

        let frame = FrameModel(image: image)
        let first = try XCTUnwrap(frame.preview)
        XCTAssertGreaterThan(first.width, 320, "the preview shows the padded canvas")
        let defaultsPadding = FrameSpec.defaults(for: image.fullSize).padding
        XCTAssertEqual(frame.spec.padding, defaultsPadding, "spec keeps full-resolution values")
        frame.spec.padding = 0
        frame.render()
        XCTAssertEqual(frame.preview?.width, 320)
    }

    // MARK: - Windows

    private func qrImage(_ text: String) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)!
    }

    /// Renders a window's content to a bitmap; optionally keeps it on disk for a visual check.
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

    /// True when the bitmap isn't a single flat colour.
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

    private func spin(_ seconds: TimeInterval = 0.6) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }

    func testEveryToolWindowOpensRendersAndCloses() async throws {
        let queue = JobQueue()
        let panels = ToolPanels(queue: queue, settings: .shared)
        defer { panels.closeAll() }

        let photo = dir.appendingPathComponent("photo.jpg")
        try TestSupport.write(TestSupport.makeImage(width: 800, height: 600), as: "public.jpeg", to: photo,
                              properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Someone"], kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Lens 50mm"]])
        let pdf = dir.appendingPathComponent("doc.pdf")
        TestSupport.makePDF(pages: (1...6).map { [("Page \($0)", 40)] }, at: pdf)
        let qr = dir.appendingPathComponent("qr.png")
        try TestSupport.write(qrImage("https://example.com/narengi"), as: "public.png", to: qr)

        let cases: [(ToolID, URL, String, String)] = [
            (.compress, pdf, "PDF", "compress"), (.removeMetadata, photo, "JPG", "metadata"), (.readQR, qr, "PNG", "qr"),
            (.organizePDF, pdf, "PDF", "organize"), (.cropImage, photo, "JPG", "crop"), (.frameImage, photo, "JPG", "frame"),
            (.editImage, photo, "JPG", "edit"), (.annotateImage, photo, "JPG", "annotate"), (.redactPDF, pdf, "PDF", "redact-pdf"),
        ]
        for (tool, url, format, name) in cases {
            let before = panels.openWindowCount
            panels.present(tool, files: [url], formats: [format], policy: OutputPolicy())
            XCTAssertEqual(panels.openWindowCount, before + 1, "\(tool) opens one window")
            await spin()
            let window = try XCTUnwrap(panels.windows.last)
            XCTAssertTrue(window.isVisible, "\(tool) window is on screen")
            XCTAssertTrue(hasContent(try snapshot(window, name: name)), "\(tool) window isn't blank")
        }
        XCTAssertTrue(queue.jobs.isEmpty, "opening windows queues nothing")
        panels.closeAll()
        XCTAssertEqual(panels.openWindowCount, 0)
    }

    func testCompressWindowSaveQueuesAJobWithTheChosenSpec() async throws {
        // The window's button calls `run`; drive the same path the button uses.
        let url = dir.appendingPathComponent("big.jpg")
        var grain = [UInt8](repeating: 255, count: 400 * 300 * 4)
        for i in 0..<(400 * 300) { for c in 0..<3 { grain[i * 4 + c] = .random(in: 0...255) } }
        let image = CGImage(width: 400, height: 300, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 1600, space: ImageOps.sRGB,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(grain) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        try TestSupport.write(image, as: "public.jpeg", to: url, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let queue = JobQueue()
        let panels = ToolPanels(queue: queue, settings: .shared)
        panels.run(.compress(CompressionSpec(mode: .percentage(60))), files: [url], formats: ["JPG"], policy: OutputPolicy())
        await queue.waitUntilIdle()
        guard case .finished(let outputs)? = queue.jobs.first?.state else { return XCTFail("\(String(describing: queue.jobs.first?.state))") }
        XCTAssertLessThanOrEqual(ImageOps.fileSize(outputs[0]), Int(Double(ImageOps.fileSize(url)) * 0.4))
    }
}
