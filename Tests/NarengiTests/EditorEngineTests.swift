import CoreGraphics
import ImageIO
import PDFKit
import XCTest
@testable import Narengi

final class EditorEngineTests: XCTestCase {
    private var dir: URL!
    private let availability = Availability.shared
    private let page = CGSize(width: 2550, height: 3300)

    override func setUpWithError() throws { dir = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func close(_ a: CGRect, _ b: CGRect, accuracy: Double = 1e-6) -> Bool {
        abs(a.minX - b.minX) < accuracy && abs(a.minY - b.minY) < accuracy && abs(a.width - b.width) < accuracy && abs(a.height - b.height) < accuracy
    }

    /// RGBA of one pixel (top-left origin) of an in-memory image.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let context = try! ImageOps.makeContext(width: 1, height: 1)
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return [Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3])]
    }

    private func solid(_ width: Int, _ height: Int, r: Double, g: Double, b: Double) -> CGImage {
        let context = try! ImageOps.makeContext(width: width, height: height)
        context.setFillColor(CGColor(colorSpace: ImageOps.sRGB, components: [r, g, b, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func grain(_ width: Int, _ height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) { for c in 0..<3 { bytes[i * 4 + c] = .random(in: 0...255) } }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: ImageOps.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: CGDataProvider(data: Data(bytes) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    // MARK: - Crop geometry (ported from Satsuma's tests)

    func testHandlesAreFoundAtEdgesAndCorners() {
        let r = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(CropGeometry.hitHandle(r, at: CGPoint(x: 100, y: 100), tolerance: 10), .topLeft)
        XCTAssertEqual(CropGeometry.hitHandle(r, at: CGPoint(x: 500, y: 400), tolerance: 10), .bottomRight)
        XCTAssertEqual(CropGeometry.hitHandle(r, at: CGPoint(x: 300, y: 95), tolerance: 10), .top)
        XCTAssertEqual(CropGeometry.hitHandle(r, at: CGPoint(x: 505, y: 250), tolerance: 10), .right)
        XCTAssertEqual(CropGeometry.hitHandle(r, at: CGPoint(x: 300, y: 250), tolerance: 10), .move)
        XCTAssertNil(CropGeometry.hitHandle(r, at: CGPoint(x: 50, y: 50), tolerance: 10))
    }

    func testFreeDragOfBottomEdge() {
        let full = CGRect(origin: .zero, size: page)
        let r = CropGeometry.drag(full, handle: .bottom, dx: 0, dy: 1677 - 3300, aspect: nil, bounds: page, min: 20)
        XCTAssertTrue(close(r, CGRect(x: 0, y: 0, width: 2550, height: 1677)))
    }

    func testDragsStayInsideAndAboveMinimum() {
        let r = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertTrue(close(CropGeometry.drag(r, handle: .topLeft, dx: -500, dy: -500, aspect: nil, bounds: page, min: 20), CGRect(x: 0, y: 0, width: 500, height: 400)))
        XCTAssertEqual(CropGeometry.drag(r, handle: .right, dx: -1000, dy: 0, aspect: nil, bounds: page, min: 20).width, 20)
        XCTAssertTrue(close(CropGeometry.drag(r, handle: .move, dx: 10_000, dy: -10_000, aspect: nil, bounds: page, min: 20),
                            CGRect(x: page.width - 400, y: 0, width: 400, height: 300)))
    }

    func testAspectPresetsFitTheImage() {
        let full = CGRect(origin: .zero, size: page)
        let square = CropGeometry.fitAspect(full, aspect: 1, bounds: page)
        XCTAssertEqual(square.width, 2550)
        XCTAssertEqual(square.height, 2550)
        XCTAssertEqual(square.minY, 375)
        let wide = CropGeometry.fitAspect(full, aspect: 16.0 / 9.0, bounds: page)
        XCTAssertEqual(wide.width, 2550, accuracy: 1e-9)
        XCTAssertEqual(wide.height, 2550 * 9 / 16, accuracy: 1e-9)
        let tall = CropGeometry.fitAspect(full, aspect: 9.0 / 16.0, bounds: page)
        XCTAssertEqual(tall.height, 3300, accuracy: 1e-9)
        XCTAssertLessThan(tall.width, 2550)
    }

    func testAspectDragsKeepTheRatioInsideTheImage() {
        let start = CGRect(x: 500, y: 500, width: 1000, height: 1000)
        for handle in CropGeometry.Handle.allCases where handle != .move {
            for (dx, dy) in [(300.0, 120.0), (-400.0, -900.0), (2000.0, 2000.0), (-2000.0, 50.0)] {
                let r = CropGeometry.drag(start, handle: handle, dx: dx, dy: dy, aspect: 1, bounds: page, min: 20)
                XCTAssertEqual(r.width, r.height, accuracy: 1e-6, "\(handle) \(dx),\(dy) -> \(r)")
                XCTAssertGreaterThanOrEqual(r.minX, -1e-6)
                XCTAssertGreaterThanOrEqual(r.minY, -1e-6)
                XCTAssertLessThanOrEqual(r.maxX, page.width + 1e-6)
                XCTAssertLessThanOrEqual(r.maxY, page.height + 1e-6)
            }
        }
    }

    func testTypedSizesAndFractionalSpecs() {
        let r = CropGeometry.setSize(CGRect(origin: .zero, size: page), width: 1000, height: 500, bounds: page)
        XCTAssertTrue(close(r, CGRect(x: 775, y: 1400, width: 1000, height: 500)))
        let spec = CropSpec.fromPixels(r, image: page)
        XCTAssertTrue(close(spec.pixels(in: page), r))
        let other = spec.pixels(in: CGSize(width: 1275, height: 1650))
        XCTAssertEqual(other.width, 500)
        XCTAssertEqual(other.height, 250)
    }

    func testFrameLayouts() {
        var layout = FrameSpec.layout(image: CGSize(width: 1000, height: 500), padding: 100, ratio: nil)
        XCTAssertEqual(layout.canvas, CGSize(width: 1200, height: 700))
        XCTAssertEqual(layout.photo.origin, CGPoint(x: 100, y: 100))
        layout = FrameSpec.layout(image: CGSize(width: 1000, height: 500), padding: 100, ratio: (1, 1))
        XCTAssertEqual(layout.canvas, CGSize(width: 1200, height: 1200))
        XCTAssertEqual(layout.photo.origin, CGPoint(x: 100, y: 350))
        layout = FrameSpec.layout(image: CGSize(width: 500, height: 1000), padding: 50, ratio: (16, 9))
        XCTAssertEqual(layout.canvas.height, 1100)
        XCTAssertEqual(layout.canvas.width, (1100.0 * 16 / 9).rounded())
        let defaults = FrameSpec.defaults(for: CGSize(width: 1000, height: 500))
        XCTAssertEqual(defaults.padding, 80)
        XCTAssertEqual(defaults.corners, 15)
        XCTAssertEqual(defaults.shadow, 12)
    }

    // MARK: - Crop through the service

    func testCropAppliesTheSameFractionsToEveryImage() async throws {
        let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
        try TestSupport.write(solid(400, 200, r: 1, g: 0, b: 0), as: "public.png", to: a)
        try TestSupport.write(solid(800, 400, r: 0, g: 0, b: 1), as: "public.png", to: b)
        let spec = CropSpec(rect: CGRect(x: 0.25, y: 0, width: 0.5, height: 1))
        let outputs = try await ToolService.work(.crop(spec), sources: [a, b], formats: ["PNG", "PNG"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["a Cropped.png", "b Cropped.png"])
        XCTAssertEqual(TestSupport.info(outputs[0])?.width, 200)
        XCTAssertEqual(TestSupport.info(outputs[1])?.width, 400)
        XCTAssertEqual(TestSupport.info(outputs[1])?.height, 400)
    }

    func testCropCanScaleToAnExactSize() async throws {
        let a = dir.appendingPathComponent("a.jpg")
        try TestSupport.write(solid(400, 200, r: 0, g: 1, b: 0), as: "public.jpeg", to: a)
        let spec = CropSpec(rect: CGRect(x: 0, y: 0, width: 0.5, height: 1), output: CGSize(width: 64, height: 64))
        let outputs = try await ToolService.work(.crop(spec), sources: [a], formats: ["JPG"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(TestSupport.info(outputs[0])?.width, 64)
        XCTAssertEqual(TestSupport.info(outputs[0])?.height, 64)
    }

    // MARK: - Add Background

    func testFrameDrawsBackgroundCornersAndPhoto() throws {
        let photo = solid(200, 100, r: 0, g: 0, b: 1)
        var spec = FrameSpec(background: .solid(RGB(255, 255, 0)), padding: 50, corners: 30, shadow: 0, ratio: nil)
        let framed = try FrameRenderer.render(photo, spec: spec)
        XCTAssertEqual(framed.width, 300)
        XCTAssertEqual(framed.height, 200)
        XCTAssertEqual(pixel(framed, 5, 5), [255, 255, 0, 255], "padding shows the background")
        XCTAssertEqual(pixel(framed, 150, 100), [0, 0, 255, 255], "the photo sits in the middle")
        XCTAssertEqual(pixel(framed, 52, 52), [255, 255, 0, 255], "rounded corners expose the background")

        spec.shadow = 20
        let shadowed = try FrameRenderer.render(photo, spec: spec)
        let below = pixel(shadowed, 150, 158)  // just under the photo's bottom edge
        XCTAssertLessThan(below[2], 255 - 1, "a shadow darkens the background below the photo")

        spec.background = .gradient(0)
        let gradient = try FrameRenderer.render(photo, spec: spec)
        XCTAssertNotEqual(pixel(gradient, 2, 2), pixel(gradient, 297, 197), "gradients change across the canvas")
    }

    func testFrameToolWritesAPNGWithTheSourceName() async throws {
        let a = dir.appendingPathComponent("photo.jpg")
        try TestSupport.write(solid(200, 100, r: 1, g: 0, b: 0), as: "public.jpeg", to: a)
        let spec = FrameSpec(background: .gradient(2), padding: 40, corners: 10, shadow: 8, ratio: (1, 1))
        let outputs = try await ToolService.work(.frame(spec), sources: [a], formats: ["JPG"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["photo With Background.png"])
        XCTAssertEqual(TestSupport.info(outputs[0])?.width, TestSupport.info(outputs[0])?.height)
    }

    // MARK: - Edit Photo

    func testAdjustmentsMapToCoreImageEffects() throws {
        let grey = solid(80, 80, r: 0.4, g: 0.4, b: 0.4)
        var a = Adjustments()
        XCTAssertTrue(a.isIdentity)
        XCTAssertEqual(try PhotoAdjuster.apply(a, to: grey).width, 80)

        a[.exposure] = 60
        let brighter = try PhotoAdjuster.apply(a, to: grey)
        XCTAssertGreaterThan(pixel(brighter, 40, 40)[0], pixel(grey, 40, 40)[0] + 20)

        a = Adjustments()
        a[.saturation] = -100
        let tinted = solid(40, 40, r: 0.9, g: 0.2, b: 0.2)
        let flat = try PhotoAdjuster.apply(a, to: tinted)
        let p = pixel(flat, 20, 20)
        XCTAssertEqual(p[0], p[1], accuracy: 6)
        XCTAssertEqual(p[1], p[2], accuracy: 6)

        a = Adjustments()
        a[.warmth] = 80
        let warm = pixel(try PhotoAdjuster.apply(a, to: grey), 40, 40)
        XCTAssertGreaterThan(warm[0] - warm[2], 15, "warmth shifts red up and blue down")
        a[.warmth] = -80
        let cool = pixel(try PhotoAdjuster.apply(a, to: grey), 40, 40)
        XCTAssertLessThan(cool[0] - cool[2], -15)

        a = Adjustments()
        a[.vignette] = 100
        let vignetted = try PhotoAdjuster.apply(a, to: solid(200, 200, r: 0.8, g: 0.8, b: 0.8))
        XCTAssertLessThan(pixel(vignetted, 2, 2)[0], pixel(vignetted, 100, 100)[0] - 20, "corners darken")

        a = Adjustments()
        a[.contrast] = 100
        let low = pixel(try PhotoAdjuster.apply(a, to: grey), 40, 40)[0]
        XCTAssertLessThan(low, pixel(grey, 40, 40)[0], "more contrast pushes mid-dark values darker")

        a = Adjustments()
        a[.sharpness] = 100
        XCTAssertEqual(try PhotoAdjuster.apply(a, to: grain(60, 60)).width, 60)
        a[.exposure] = 500
        XCTAssertEqual(a[.exposure], 100, "sliders clamp to their range")
        a[.exposure] = 0
        a[.sharpness] = 0
        XCTAssertTrue(a.isIdentity)
    }

    func testAdjustToolKeepsFormatAndName() async throws {
        let a = dir.appendingPathComponent("photo.jpg")
        try TestSupport.write(solid(120, 80, r: 0.5, g: 0.5, b: 0.5), as: "public.jpeg", to: a)
        var adjustments = Adjustments()
        adjustments[.exposure] = 40
        let outputs = try await ToolService.work(.adjust(adjustments), sources: [a], formats: ["JPG"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["photo Edited.jpg"])
        XCTAssertEqual(TestSupport.info(outputs[0])?.width, 120)
    }

    // MARK: - Annotate and redact

    private func box(_ kind: MarkupItem.Kind, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> MarkupItem {
        MarkupItem(kind: kind, points: [CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1)])
    }

    func testBlackoutOverwritesPixelsAndNothingElse() throws {
        let image = grain(200, 100)
        let result = try MarkupRenderer.render(image, items: [box(.blackout, 0.25, 0.25, 0.75, 0.75)])
        for (x, y) in [(60, 30), (100, 50), (140, 70)] { XCTAssertEqual(pixel(result, x, y)[0...2].reduce(0, +), 0, "inside is black at \(x),\(y)") }
        for (x, y) in [(10, 10), (190, 90), (60, 10), (150, 90)] { XCTAssertEqual(pixel(result, x, y), pixel(image, x, y), "outside is untouched at \(x),\(y)") }
    }

    func testBlurAndPixelateDestroyDetail() throws {
        let image = grain(200, 100)
        for kind in [MarkupItem.Kind.blur, .pixelate] {
            let result = try MarkupRenderer.render(image, items: [box(kind, 0.1, 0.1, 0.9, 0.9)])
            var changed = 0
            for x in stride(from: 30, to: 170, by: 7) { for y in stride(from: 20, to: 80, by: 7) where pixel(result, x, y) != pixel(image, x, y) { changed += 1 } }
            XCTAssertGreaterThan(changed, 100, "\(kind) changed the covered pixels")
            XCTAssertEqual(pixel(result, 2, 2), pixel(image, 2, 2))
        }
    }

    func testAnnotationsDrawShapesArrowsPenAndText() throws {
        let white = solid(200, 200, r: 1, g: 1, b: 1)
        var rect = box(.rectangle, 0.2, 0.2, 0.8, 0.8)
        rect.width = 0.03
        let out = try MarkupRenderer.render(white, items: [rect])
        XCTAssertEqual(pixel(out, 100, 40)[0...2].map { $0 }, [255, 59, 48], "the rectangle's top edge is drawn in the mark colour")
        XCTAssertEqual(pixel(out, 100, 100), [255, 255, 255, 255], "the inside stays clear")

        var pen = MarkupItem(kind: .pen, points: (0...20).map { CGPoint(x: 0.1 + 0.04 * Double($0), y: 0.5) })
        pen.width = 0.04
        pen.color = RGB(0, 0, 255)
        XCTAssertEqual(pixel(try MarkupRenderer.render(white, items: [pen]), 100, 100)[2], 255)
        XCTAssertLessThan(pixel(try MarkupRenderer.render(white, items: [pen]), 100, 100)[0], 30)

        var arrow = MarkupItem(kind: .arrow, points: [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.1)])
        arrow.width = 0.03
        XCTAssertNotEqual(pixel(try MarkupRenderer.render(white, items: [arrow]), 100, 100), [255, 255, 255, 255])

        var text = MarkupItem(kind: .text, points: [CGPoint(x: 0.1, y: 0.1)], text: "HELLO")
        text.fontSize = 0.2
        let texted = try MarkupRenderer.render(white, items: [text])
        var inked = 0
        for x in 15..<190 { for y in 15..<80 where pixel(texted, x, y) != [255, 255, 255, 255] { inked += 1 } }
        XCTAssertGreaterThan(inked, 100, "text leaves ink")
    }

    func testRedactingAPhotoThroughTheServiceStripsMetadataToo() async throws {
        let a = dir.appendingPathComponent("id card.jpg")
        try TestSupport.write(grain(300, 200), as: "public.jpeg", to: a, properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretCam"]])
        let items: [Int: [MarkupItem]] = [0: [box(.blackout, 0, 0, 1, 1)]]
        let outputs = try await ToolService.work(.markup(.redactImage, items), sources: [a], formats: ["JPG"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["id card Redacted.jpg"])
        XCTAssertNil(try Data(contentsOf: outputs[0]).range(of: Data("SecretCam".utf8)))
        let info = try XCTUnwrap(TestSupport.info(outputs[0]))
        XCTAssertEqual(info.width, 300)
        let px = try XCTUnwrap(TestSupport.pixel(outputs[0], x: 150, y: 100))
        XCTAssertLessThan(Int(px[0]) + Int(px[1]) + Int(px[2]), 30, "the whole picture is black")
    }

    func testAnnotatedPhotoIsSavedAsPNG() async throws {
        let a = dir.appendingPathComponent("photo.jpg")
        try TestSupport.write(solid(100, 100, r: 1, g: 1, b: 1), as: "public.jpeg", to: a)
        var rect = box(.rectangle, 0.1, 0.1, 0.9, 0.9)
        rect.width = 0.05
        let outputs = try await ToolService.work(.markup(.annotateImage, [0: [rect]]), sources: [a], formats: ["JPG"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["photo Annotated.png"])
    }

    func testRedactingAPDFPageRemovesItsTextButKeepsOtherPagesSearchable() async throws {
        let source = dir.appendingPathComponent("contract.pdf")
        TestSupport.makePDF(pages: [[("SECRET account 12345", 28)], [("Public page two", 28)]], at: source)
        XCTAssertTrue(PDFDocument(url: source)?.string?.contains("SECRET") ?? false)

        let items: [Int: [MarkupItem]] = [0: [box(.blackout, 0.05, 0.05, 0.95, 0.4)]]
        let outputs = try await ToolService.work(.markup(.redactPDF, items), sources: [source], formats: ["PDF"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["contract Redacted.pdf"])
        let result = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertFalse(result.page(at: 0)?.string?.contains("SECRET") ?? false, "the redacted page has no text layer left")
        XCTAssertFalse(result.page(at: 0)?.string?.contains("12345") ?? false)
        XCTAssertTrue(result.page(at: 1)?.string?.contains("Public page two") ?? false, "untouched pages stay vector and searchable")
        // The raw bytes must not hold the secret either.
        XCTAssertNil(try Data(contentsOf: outputs[0]).range(of: Data("SECRET".utf8)))
    }

    func testAnnotatingAPDFKeepsTheTextLayer() async throws {
        let source = dir.appendingPathComponent("notes.pdf")
        TestSupport.makePDF(pages: [[("Keep this text", 28)]], at: source)
        var rect = box(.rectangle, 0.1, 0.1, 0.9, 0.5)
        rect.width = 0.01
        let outputs = try await ToolService.work(.markup(.annotatePDF, [0: [rect]]), sources: [source], formats: ["PDF"], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["notes Annotated.pdf"])
        XCTAssertTrue(PDFDocument(url: outputs[0])?.string?.contains("Keep this text") ?? false)
    }
}
