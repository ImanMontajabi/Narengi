import ImageIO
import XCTest
@testable import Narengi

final class ImageConversionTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestSupport.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func convert(
        _ source: URL, from: String, to: String,
        quality: Double = 0.8, preserveMetadata: Bool = true, dpi: Int = 150,
        policy: OutputPolicy = OutputPolicy(), tools: BundledToolLocator = .shared
    ) async throws -> [URL] {
        let options = ConversionOptions(sourceFormat: from, targetFormat: to, quality: quality,
                                        preserveMetadata: preserveMetadata, dpi: dpi)
        return try await ConversionService.run(
            source: source, options: options, policy: policy,
            availability: Availability(media: .shared, tools: tools))
    }

    private func makePNG(_ name: String = "fixture.png", width: Int = 64, height: Int = 48, alpha: Bool = false) throws -> URL {
        try TestSupport.write(
            TestSupport.makeImage(width: width, height: height, transparentLeftHalf: alpha),
            as: "public.png", to: directory.appendingPathComponent(name))
    }

    // MARK: - Formats

    func testPNGToEveryWritableRasterFormatRoundTrips() async throws {
        let source = try makePNG()
        let expectations: [(format: String, ext: String, uti: String)] = [
            ("JPG", "jpg", "public.jpeg"), ("TIFF", "tiff", "public.tiff"), ("BMP", "bmp", "com.microsoft.bmp"),
            ("GIF", "gif", "com.compuserve.gif"), ("HEIC", "heic", "public.heic"), ("AVIF", "avif", "public.avif"),
        ]
        for (format, ext, uti) in expectations {
            guard ImageEngine.canEncode(format) else {
                print("note: this Mac can't encode \(format); skipped")
                continue
            }
            let outputs = try await convert(source, from: "PNG", to: format)
            XCTAssertEqual(outputs.count, 1, format)
            XCTAssertEqual(outputs[0].pathExtension, ext, format)
            let info = try XCTUnwrap(TestSupport.info(outputs[0]), "\(format) output must decode")
            XCTAssertEqual(info.type, uti, format)
            XCTAssertEqual(info.width, 64, format)
            XCTAssertEqual(info.height, 48, format)
        }
    }

    func testJPGToPNGKeepsDimensions() async throws {
        let jpg = try TestSupport.write(TestSupport.makeImage(width: 80, height: 30), as: "public.jpeg",
                                        to: directory.appendingPathComponent("photo.jpg"))
        let output = try await convert(jpg, from: "JPG", to: "PNG")[0]
        let info = try XCTUnwrap(TestSupport.info(output))
        XCTAssertEqual(info.type, "public.png")
        XCTAssertEqual([info.width, info.height], [80, 30])
        XCTAssertEqual(output.lastPathComponent, "photo.png")
    }

    func testTransparencyIsFlattenedOnWhiteForJPG() async throws {
        let source = try makePNG(alpha: true)
        let output = try await convert(source, from: "PNG", to: "JPG")[0]
        let corner = try XCTUnwrap(TestSupport.pixel(output, x: 2, y: 2))  // inside the transparent half
        XCTAssertGreaterThan(corner[0], 240)
        XCTAssertGreaterThan(corner[1], 240)
        XCTAssertGreaterThan(corner[2], 240)
    }

    func testTransparencyIsKeptForPNGToTIFF() async throws {
        let source = try makePNG(alpha: true)
        let output = try await convert(source, from: "PNG", to: "TIFF")[0]
        let corner = try XCTUnwrap(TestSupport.pixel(output, x: 2, y: 2))
        XCTAssertEqual(corner[3], 0)
    }

    func testEXIFOrientationIsAppliedToPixels() async throws {
        // 40×20 stored image tagged "rotate 90° CW" should come out 20×40.
        let jpg = try TestSupport.write(
            TestSupport.makeImage(width: 40, height: 20), as: "public.jpeg",
            to: directory.appendingPathComponent("rotated.jpg"),
            properties: [kCGImagePropertyOrientation: 6])
        let output = try await convert(jpg, from: "JPG", to: "PNG")[0]
        let info = try XCTUnwrap(TestSupport.info(output))
        XCTAssertEqual([info.width, info.height], [20, 40])
    }

    func testMetadataPreservedOrStrippedPerSetting() async throws {
        let jpg = try TestSupport.write(
            TestSupport.makeImage(width: 32, height: 32), as: "public.jpeg",
            to: directory.appendingPathComponent("camera.jpg"),
            properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "NarengiCam"]])

        let kept = try await convert(jpg, from: "JPG", to: "TIFF", preserveMetadata: true)[0]
        let keptTIFF = TestSupport.info(kept)?.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(keptTIFF?[kCGImagePropertyTIFFMake] as? String, "NarengiCam")

        let stripped = try await convert(jpg, from: "JPG", to: "TIFF", preserveMetadata: false)[0]
        let strippedTIFF = TestSupport.info(stripped)?.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(strippedTIFF?[kCGImagePropertyTIFFMake])
    }

    func testLossyQualitySettingChangesFileSize() async throws {
        let source = try makePNG(width: 400, height: 300)
        let low = try await convert(source, from: "PNG", to: "JPG", quality: 0.2)[0]
        let high = try await convert(source, from: "PNG", to: "JPG", quality: 0.95)[0]
        let lowSize = try FileManager.default.attributesOfItem(atPath: low.path)[.size] as! Int
        let highSize = try FileManager.default.attributesOfItem(atPath: high.path)[.size] as! Int
        XCTAssertLessThan(lowSize, highSize)
    }

    func testICNSOutputIsASquareIcon() async throws {
        guard ImageEngine.canEncode("ICNS") else { throw XCTSkip("ICNS encoding unavailable") }
        let output = try await convert(try makePNG(width: 100, height: 60), from: "PNG", to: "ICNS")[0]
        let info = try XCTUnwrap(TestSupport.info(output))
        XCTAssertEqual(info.width, info.height)
        XCTAssertEqual(output.pathExtension, "icns")
    }

    // MARK: - WebP

    func testWebPOutputIsDecodable() async throws {
        let source = try makePNG(width: 96, height: 64)
        if !ImageEngine.canEncode("WEBP"), BundledToolLocator.shared.locate(.cwebp) == nil {
            throw XCTSkip("neither ImageIO nor cwebp can write WebP here")
        }
        let output = try await convert(source, from: "PNG", to: "WEBP")[0]
        let header = try Data(contentsOf: output).prefix(12)
        XCTAssertEqual(String(decoding: header.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: header.suffix(4), as: UTF8.self), "WEBP")
        let info = try XCTUnwrap(TestSupport.info(output))
        XCTAssertEqual([info.width, info.height], [96, 64])
    }

    /// Exercises the `cwebp` helper directly, even on Macs where ImageIO could write WebP itself.
    func testCwebpHelperPathProducesValidWebP() async throws {
        guard let cwebp = BundledToolLocator.shared.locate(.cwebp) else { throw XCTSkip("cwebp not installed; run scripts/setup-vendor.sh") }
        let decoded = try ImageEngine.decode(try makePNG(width: 80, height: 40, alpha: true), dpi: 150, flattenOnWhite: false)
        let output = directory.appendingPathComponent("tool.webp")
        let engine = ImageEngine(tools: BundledToolLocator(vendorDirectory: cwebp.deletingLastPathComponent(), fallbackDirectories: []))
        try await engine.encodeWebPWithTool(
            decoded, options: ConversionOptions(sourceFormat: "PNG", targetFormat: "WEBP", quality: 0.8), to: output)

        let header = try Data(contentsOf: output).prefix(12)
        XCTAssertEqual(String(decoding: header.suffix(4), as: UTF8.self), "WEBP")
        let info = try XCTUnwrap(TestSupport.info(output))
        XCTAssertEqual([info.width, info.height], [80, 40])
        // The transparent half must survive the trip through cwebp.
        XCTAssertEqual(TestSupport.pixel(output, x: 2, y: 2)?[3], 0)
        XCTAssertTrue(TestSupport.directoryContents(FileManager.default.temporaryDirectory)
            .filter { $0.hasPrefix("narengi-") && $0.hasSuffix(".png") }.isEmpty, "intermediate PNG must be removed")
    }

    func testWebPWithoutAnyEncoderReportsMissingTool() async throws {
        if ImageEngine.canEncode("WEBP") { throw XCTSkip("ImageIO can encode WebP here; the cwebp path isn't used") }
        let source = try makePNG()
        let none = BundledToolLocator(vendorDirectory: nil, fallbackDirectories: [])
        do {
            _ = try await convert(source, from: "PNG", to: "WEBP", tools: none)
            XCTFail("expected toolMissing")
        } catch {
            XCTAssertEqual(error as? ConversionError, .toolMissing("cwebp"))
        }
    }

    // MARK: - SVG

    func testSVGRasterizesToPNG() async throws {
        let svg = directory.appendingPathComponent("shape.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50">
          <rect width="100" height="50" fill="#ff0000"/>
        </svg>
        """.write(to: svg, atomically: true, encoding: .utf8)

        let output = try await convert(svg, from: "SVG", to: "PNG", dpi: 150)[0]
        let info = try XCTUnwrap(TestSupport.info(output))
        XCTAssertGreaterThanOrEqual(info.width, 1024)
        XCTAssertEqual(Double(info.width) / Double(info.height), 2, accuracy: 0.05)
        let center = try XCTUnwrap(TestSupport.pixel(output, x: info.width / 2, y: info.height / 2))
        XCTAssertGreaterThan(center[0], 200)
        XCTAssertLessThan(center[1], 60)
        XCTAssertLessThan(center[2], 60)
    }

    // MARK: - Service behaviour

    func testRepeatedConversionNeverOverwrites() async throws {
        let source = try makePNG(width: 32, height: 32)
        let first = try await convert(source, from: "PNG", to: "JPG")[0]
        let second = try await convert(source, from: "PNG", to: "JPG")[0]
        XCTAssertEqual(first.lastPathComponent, "fixture.jpg")
        XCTAssertEqual(second.lastPathComponent, "fixture 2.jpg")
    }

    func testFailedConversionLeavesNoPartialFiles() async throws {
        let garbage = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: garbage)
        let work = ConversionService.work(
            source: garbage,
            options: ConversionOptions(sourceFormat: "PNG", targetFormat: "JPG"),
            policy: OutputPolicy())
        do {
            _ = try await work(JobContext(reportProgress: { _ in }))
            XCTFail("expected a decode failure")
        } catch {
            XCTAssertEqual(error as? ConversionError, .decodeFailed("broken.png"))
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["broken.png"])
    }

    func testUnsupportedRouteIsRejected() async throws {
        let source = try makePNG()
        do {
            _ = try await convert(source, from: "PNG", to: "MP3")
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? ConversionError, .unsupported(from: "PNG", to: "MP3"))
        }
    }

    @MainActor
    func testConversionThroughTheJobQueueEndToEnd() async throws {
        let source = try makePNG(width: 50, height: 50)
        let queue = JobQueue()
        let job = queue.enqueue(
            title: "fixture.png → JPG",
            work: ConversionService.work(
                source: source,
                options: ConversionOptions(sourceFormat: "PNG", targetFormat: "JPG"),
                policy: OutputPolicy()))
        await queue.waitUntilIdle()

        guard case .finished(let outputs) = job.state else { return XCTFail("state was \(job.state)") }
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["fixture.jpg"])
        XCTAssertEqual(TestSupport.info(outputs[0])?.type, "public.jpeg")
    }
}
