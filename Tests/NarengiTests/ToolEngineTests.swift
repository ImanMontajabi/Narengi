import CoreImage
import ImageIO
import PDFKit
import XCTest
@testable import Narengi

final class ToolEngineTests: XCTestCase {
    private var dir: URL!
    private let availability = Availability.shared

    override func setUpWithError() throws { dir = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func runTool(_ operation: ToolOperation, _ sources: [URL], formats: [String]? = nil) async throws -> [URL] {
        let formats = formats ?? sources.map { FormatCatalog.detect($0) ?? "?" }
        return try await ToolService.work(operation, sources: sources, formats: formats, policy: OutputPolicy(), availability: availability)(
            JobContext(reportProgress: { _ in }))
    }

    private func plain(_ tool: ToolID, _ sources: [URL], options: ToolOptions = ToolOptions()) async throws -> [URL] {
        try await runTool(.plain(tool, options), sources)
    }

    private func requireFFmpeg() throws {
        guard availability.media.hasFFmpeg else { throw XCTSkip("ffmpeg isn't installed") }
    }

    private func noisyImage(_ width: Int = 600, _ height: Int = 400) -> CGImage {
        let context = try! ImageOps.makeContext(width: width, height: height)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2500 {
            context.setFillColor(CGColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                         blue: .random(in: 0...1, using: &generator), alpha: 1))
            context.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &generator), y: .random(in: 0..<CGFloat(height), using: &generator),
                                width: .random(in: 4...60, using: &generator), height: .random(in: 4...60, using: &generator)))
        }
        return context.makeImage()!
    }

    /// Per-pixel noise: hard for lossless coders, so palette/JPEG recompression visibly wins.
    private func grainyImage(_ width: Int, _ height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var generator = SystemRandomNumberGenerator()
        for i in 0..<(width * height) {
            bytes[i * 4] = .random(in: 0...255, using: &generator)
            bytes[i * 4 + 1] = .random(in: 0...255, using: &generator)
            bytes[i * 4 + 2] = .random(in: 0...255, using: &generator)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: ImageOps.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func pdf(pages: Int, name: String = "doc.pdf") -> URL {
        let url = dir.appendingPathComponent(name)
        TestSupport.makePDF(pages: (1...pages).map { [("Page \($0)", 24)] }, at: url)
        return url
    }

    // MARK: - Metadata stripping

    func testJPEGStripKeepsOrientationAndPixelsButDropsCameraData() throws {
        let url = dir.appendingPathComponent("photo.jpg")
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretCam", kCGImagePropertyTIFFArtist: "Someone"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private note"],
        ]
        try TestSupport.write(noisyImage(), as: "public.jpeg", to: url, properties: properties)
        let original = try Data(contentsOf: url)
        XCTAssertTrue(String(decoding: original, as: UTF8.self).contains("SecretCam"))

        let stripped = try MetadataStripper.stripJPEG(original)
        XCTAssertFalse(String(decoding: stripped, as: UTF8.self).contains("SecretCam"))
        XCTAssertFalse(String(decoding: stripped, as: UTF8.self).contains("private note"))
        let out = dir.appendingPathComponent("clean.jpg")
        try stripped.write(to: out)
        let info = try XCTUnwrap(TestSupport.info(out))
        XCTAssertEqual(info.properties[kCGImagePropertyOrientation] as? Int, 6, "orientation survives so the photo stays upright")
        XCTAssertEqual(info.width, 600)
        XCTAssertNil((info.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
    }

    func testPNGStripDropsTextChunksOnly() throws {
        let url = dir.appendingPathComponent("a.png")
        try TestSupport.write(noisyImage(100, 100), as: "public.png", to: url,
                              properties: [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: "secret description"]])
        let original = try Data(contentsOf: url)
        XCTAssertTrue(original.range(of: Data("secret description".utf8)) != nil)
        let stripped = try MetadataStripper.stripPNG(original)
        XCTAssertNil(stripped.range(of: Data("secret description".utf8)))
        let out = dir.appendingPathComponent("b.png")
        try stripped.write(to: out)
        XCTAssertEqual(TestSupport.info(out)?.width, 100)
    }

    func testWebPStripRemovesExifAndXmpChunksAndFlags() throws {
        func chunk(_ id: String, _ payload: [UInt8]) -> [UInt8] {
            var c = Array(id.utf8)
            c += [UInt8(payload.count & 255), UInt8(payload.count >> 8 & 255), 0, 0] + payload
            if payload.count % 2 == 1 { c.append(0) }
            return c
        }
        let body = chunk("VP8X", [0x2C, 0, 0, 0, 9, 0, 0, 9, 0, 0]) + chunk("VP8L", [1, 2, 3, 4]) + chunk("EXIF", Array("secret".utf8)) + chunk("XMP ", Array("xmp".utf8))
        let size = UInt32(body.count + 4)
        let file = Array("RIFF".utf8) + [UInt8(size & 255), UInt8(size >> 8 & 255), 0, 0] + Array("WEBP".utf8) + body
        let stripped = [UInt8](try MetadataStripper.stripWebP(Data(file)))
        XCTAssertNil(Data(stripped).range(of: Data("secret".utf8)))
        XCTAssertNil(Data(stripped).range(of: Data("EXIF".utf8)))
        XCTAssertEqual(stripped[20] & 0x0C, 0, "EXIF and XMP flags cleared")
        XCTAssertEqual(Int(stripped[4]) | Int(stripped[5]) << 8, stripped.count - 8)
    }

    func testGIFStripDropsCommentsKeepsAnimationLoop() throws {
        let url = dir.appendingPathComponent("a.gif")
        try TestSupport.write(noisyImage(20, 20), as: "com.compuserve.gif", to: url)
        var data = [UInt8](try Data(contentsOf: url))
        // Insert a comment extension right after the logical screen descriptor + colour table.
        let flags = data[10]
        var at = 13
        if flags & 0x80 != 0 { at += 3 * (1 << (Int(flags & 7) + 1)) }
        data.insert(contentsOf: [0x21, 0xFE, 6] + Array("secret".utf8) + [0], at: at)
        let stripped = try MetadataStripper.stripGIF(Data(data))
        XCTAssertNil(stripped.range(of: Data("secret".utf8)))
        let out = dir.appendingPathComponent("b.gif")
        try stripped.write(to: out)
        XCTAssertEqual(TestSupport.info(out)?.width, 20)
    }

    func testStrippersRejectGarbage() {
        XCTAssertThrowsError(try MetadataStripper.stripJPEG(Data("nope".utf8)))
        XCTAssertThrowsError(try MetadataStripper.stripPNG(Data("nope".utf8)))
        XCTAssertThrowsError(try MetadataStripper.stripWebP(Data("nope".utf8)))
        XCTAssertThrowsError(try MetadataStripper.stripGIF(Data("nope".utf8)))
    }

    func testRemoveMetadataToolThroughTheService() async throws {
        let url = dir.appendingPathComponent("photo.jpg")
        try TestSupport.write(noisyImage(), as: "public.jpeg", to: url,
                              properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SecretCam"]])
        let out = try await plain(.removeMetadata, [url])
        XCTAssertEqual(out.map(\.lastPathComponent), ["photo No Metadata.jpg"])
        XCTAssertNil(try Data(contentsOf: out[0]).range(of: Data("SecretCam".utf8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the original is untouched")
    }

    func testRemoveMetadataFromPDFClearsTheInfoDictionary() async throws {
        let source = pdf(pages: 1)
        let document = try XCTUnwrap(PDFDocument(url: source))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Secret Title", PDFDocumentAttribute.authorAttribute: "Somebody"]
        XCTAssertTrue(document.write(to: source))
        let out = try await plain(.removeMetadata, [source])
        let attributes = PDFDocument(url: out[0])?.documentAttributes ?? [:]
        XCTAssertNil(attributes[PDFDocumentAttribute.titleAttribute])
        XCTAssertNil(attributes[PDFDocumentAttribute.authorAttribute])
    }

    func testRemoveMetadataFromAudioWithFFmpeg() async throws {
        try requireFFmpeg()
        let wav = try TestSupport.ffmpegFixture("tagged.mp3", in: dir, arguments: [
            "-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-metadata", "title=Secret Song", "-metadata", "artist=Somebody"])
        let out = try await plain(.removeMetadata, [wav])
        XCTAssertNil(try Data(contentsOf: out[0]).range(of: Data("Secret Song".utf8)))
    }

    func testMetadataReadAndEditWithExifTool() async throws {
        guard availability.tools.locate(.exiftool) != nil else { throw XCTSkip("ExifTool isn't installed") }
        let url = dir.appendingPathComponent("photo.jpg")
        try TestSupport.write(noisyImage(), as: "public.jpeg", to: url,
                              properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Original Artist"]])
        let engine = MetadataEngine()
        let groups = try await engine.read(url, format: "JPG")
        let artist = try XCTUnwrap(groups.flatMap(\.entries).first { $0.label == "Artist" })
        XCTAssertEqual(artist.value, "Original Artist")
        XCTAssertFalse(groups.contains { $0.name == "System" || $0.name == "File" }, "file-system rows are hidden")

        let edited = dir.appendingPathComponent("edited.jpg")
        try await engine.save(source: url, output: edited, format: "JPG", changes: [artist.id: "New Artist"])
        let after = try await engine.read(edited, format: "JPG").flatMap(\.entries)
        XCTAssertEqual(after.first { $0.label == "Artist" }?.value, "New Artist")

        let removed = dir.appendingPathComponent("removed.jpg")
        try await engine.save(source: url, output: removed, format: "JPG", changes: [artist.id: nil])
        let awaited1 = try await engine.read(removed, format: "JPG").flatMap(\.entries)
        XCTAssertNil(awaited1.first { $0.label == "Artist" })
    }

    func testMetadataReadFallsBackToImageIOAndPDFKitWithoutExifTool() async throws {
        let engine = MetadataEngine(tools: BundledToolLocator(vendorDirectory: nil, fallbackDirectories: []))
        let url = dir.appendingPathComponent("photo.jpg")
        try TestSupport.write(noisyImage(), as: "public.jpeg", to: url,
                              properties: [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "Original Lens"]])
        let rows = try await engine.read(url, format: "JPG").flatMap(\.entries)
        XCTAssertTrue(rows.contains { $0.value == "Original Lens" }, "\(rows.map(\.id))")

        let source = pdf(pages: 1)
        let document = try XCTUnwrap(PDFDocument(url: source))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Hello"]
        XCTAssertTrue(document.write(to: source))
        let pdfRows = try await engine.read(source, format: "PDF").flatMap(\.entries)
        XCTAssertTrue(pdfRows.contains { $0.value == "Hello" && $0.isEditable })
        // Remove All still works with no ExifTool at all.
        let stripped = dir.appendingPathComponent("s.jpg")
        try await engine.strip(source: url, output: stripped, format: "JPG") { _ in }
        XCTAssertNil(try Data(contentsOf: stripped).range(of: Data("Original Lens".utf8)))
    }

    func testExifToolJSONParsingGroupsAndPrettifiesLabels() {
        let json = #"[{"SourceFile":"x.jpg","System:FileSize":"1 kB","IFD0:Make":"ACME","ExifIFD:CreateDate":"2026:10:01 11:05:02","GPS:GPSLatitude":"52 deg","PDF:Title":"T"}]"#
        let groups = MetadataEngine.parseExifTool(json) ?? []
        XCTAssertEqual(Set(groups.map(\.name)), ["Camera & Exif", "Location", "Document"])
        let all = groups.flatMap(\.entries)
        XCTAssertTrue(all.contains { $0.label == "Create Date" })
        XCTAssertFalse(all.contains { $0.label == "File Size" })
        XCTAssertEqual(MetadataEngine.prettyLabel("ISO"), "ISO")
        XCTAssertEqual(MetadataEngine.prettyLabel("ModDate"), "Mod Date")
    }

    // MARK: - Compress

    func testCompressJPEGPreset() async throws {
        let url = dir.appendingPathComponent("noise.jpg")
        try TestSupport.write(noisyImage(), as: "public.jpeg", to: url, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let out = try await runTool(.compress(CompressionSpec(mode: .preset(strong: true))), [url])
        XCTAssertEqual(out.map(\.lastPathComponent), ["noise Compressed.jpg"])
        XCTAssertLessThan(ImageOps.fileSize(out[0]), ImageOps.fileSize(url))
    }

    func testCompressJPEGPercentageHitsTheTarget() async throws {
        let url = dir.appendingPathComponent("noise.jpg")
        try TestSupport.write(noisyImage(900, 600), as: "public.jpeg", to: url, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let original = ImageOps.fileSize(url)
        let out = try await runTool(.compress(CompressionSpec(mode: .percentage(50))), [url])
        XCTAssertLessThanOrEqual(ImageOps.fileSize(out[0]), original / 2)
    }

    func testCompressResizesWhenSettingsAskForIt() async throws {
        let url = dir.appendingPathComponent("big.jpg")
        try TestSupport.write(noisyImage(1200, 800), as: "public.jpeg", to: url, properties: [kCGImageDestinationLossyCompressionQuality: 1.0])
        let out = try await runTool(.compress(CompressionSpec(mode: .preset(strong: false), maxEdge: 600)), [url])
        XCTAssertEqual(TestSupport.info(out[0])?.width, 600)
    }

    func testCompressPNGWithPalette() async throws {
        try requireFFmpeg()
        let url = dir.appendingPathComponent("noise.png")
        try TestSupport.write(grainyImage(500, 400), as: "public.png", to: url)
        let out = try await runTool(.compress(CompressionSpec(mode: .preset(strong: true))), [url])
        XCTAssertLessThan(ImageOps.fileSize(out[0]), ImageOps.fileSize(url))
        XCTAssertEqual(TestSupport.info(out[0])?.width, 500)
    }

    func testCompressRefusesToGrowAFile() async throws {
        let url = dir.appendingPathComponent("tiny.jpg")
        try TestSupport.write(TestSupport.makeImage(width: 8, height: 8), as: "public.jpeg", to: url, properties: [kCGImageDestinationLossyCompressionQuality: 0.1])
        do {
            _ = try await runTool(.compress(CompressionSpec(mode: .preset(strong: false))), [url])
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("smaller"))
        }
        XCTAssertEqual(TestSupport.directoryContents(dir), ["tiny.jpg"], "nothing left behind")
    }

    func testCompressWAVBecomesFLAC() async throws {
        try requireFFmpeg()
        let wav = try TestSupport.makeWAV(in: dir, seconds: 2)
        let out = try await runTool(.compress(CompressionSpec()), [wav])
        XCTAssertEqual(out.map(\.lastPathComponent), ["tone Compressed.flac"])
        XCTAssertLessThan(ImageOps.fileSize(out[0]), ImageOps.fileSize(wav))
    }

    func testCompressVideo() async throws {
        try requireFFmpeg()
        guard (try? MediaEngine(env: availability.media).h264Arguments(crf: 20)) != nil else { throw XCTSkip("no H.264 encoder") }
        let clip = try TestSupport.ffmpegFixture("big.mp4", in: dir, arguments: [
            "-f", "lavfi", "-i", "testsrc2=size=640x480:rate=25:duration=2", "-c:v", "libx264", "-crf", "10", "-preset", "ultrafast", "-pix_fmt", "yuv420p"])
        let out = try await runTool(.compress(CompressionSpec(mode: .preset(strong: true))), [clip])
        XCTAssertLessThan(ImageOps.fileSize(out[0]), ImageOps.fileSize(clip))
    }

    func testCompressPDFWithEmbeddedImages() async throws {
        let url = dir.appendingPathComponent("scan.pdf")
        try PDFEngine.makePDF(from: [(grainyImage(1400, 1000), 150), (grainyImage(1400, 1000), 150)], to: url)
        let out = try await runTool(.compress(CompressionSpec(mode: .preset(strong: true))), [url])
        XCTAssertLessThan(ImageOps.fileSize(out[0]), ImageOps.fileSize(url))
        XCTAssertEqual(PDFDocument(url: out[0])?.pageCount, 2)
    }

    func testCompressionSpecMath() {
        XCTAssertEqual(CompressionSpec(mode: .percentage(50)).targetBytes(original: 1000), 500)
        XCTAssertEqual(CompressionSpec(mode: .percentage(100)).targetBytes(original: 1000), 10, "never asks for zero bytes")
        XCTAssertNil(CompressionSpec().targetBytes(original: 1000))
        XCTAssertTrue(CompressionSpec(mode: .percentage(60)).isStrong)
        XCTAssertFalse(CompressionSpec(mode: .preset(strong: false)).isStrong)
    }

    // MARK: - Audio & video

    func testNormalizeTrimChannelsAndVisualize() async throws {
        try requireFFmpeg()
        let engine = MediaEngine(env: availability.media)
        let tone = try TestSupport.ffmpegFixture("padded.wav", in: dir, arguments: [
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
            "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-filter_complex",
            "[0:a]atrim=duration=1[a];[2:a]atrim=duration=1[c];[a][1:a][c]concat=n=3:v=0:a=1"])
        let awaited2 = await engine.probe(tone)
        let originalDuration = try XCTUnwrap(awaited2.duration)

        let normalized = try await plain(.normalizeAudio, [tone])
        XCTAssertEqual(normalized.map(\.lastPathComponent), ["padded Normalized.wav"])

        let trimmed = try await plain(.trimAudio, [tone])
        let awaited3 = await engine.probe(trimmed[0])
        let trimmedDuration = try XCTUnwrap(awaited3.duration)
        XCTAssertLessThan(trimmedDuration, originalDuration - 1, "leading and trailing silence removed")
        XCTAssertGreaterThan(trimmedDuration, 0.8)

        let mono = try await plain(.audioChannels, [tone])
        XCTAssertEqual(mono.map(\.lastPathComponent), ["padded Mono.wav"])
        let awaited4 = await engine.probe(mono[0])
        XCTAssertEqual(awaited4.audio?.channels, 1)
        let stereo = try await plain(.audioChannels, mono)
        XCTAssertEqual(stereo.map(\.lastPathComponent), ["padded Mono Stereo.wav"])
        let awaited5 = await engine.probe(stereo[0])
        XCTAssertEqual(awaited5.audio?.channels, 2)
    }

    func testVideoToolsMuteSpeedSnapshotSplitJoinVisualize() async throws {
        try requireFFmpeg()
        guard (try? MediaEngine(env: availability.media).h264Arguments(crf: 20)) != nil else { throw XCTSkip("no H.264 encoder") }
        let engine = MediaEngine(env: availability.media)
        let clip = try TestSupport.makeMP4(in: dir, seconds: 4)

        let muted = try await plain(.muteVideo, [clip])
        let awaited6 = await engine.probe(muted[0])
        XCTAssertNil(awaited6.audio)
        let awaited7 = await engine.probe(muted[0])
        XCTAssertNotNil(awaited7.video)

        let fast = try await plain(.changeVideoSpeed, [clip])
        XCTAssertEqual(fast.map(\.lastPathComponent), ["clip Speed 2x.mp4"])
        let awaited8 = await engine.probe(fast[0])
        let fastDuration = try XCTUnwrap(awaited8.duration)
        XCTAssertEqual(fastDuration, 2, accuracy: 0.5)

        let snapshot = try await plain(.videoSnapshots, [clip])
        XCTAssertEqual(snapshot.map(\.lastPathComponent), ["clip Snapshot.png"])
        XCTAssertEqual(TestSupport.info(snapshot[0])?.width, 160)

        var options = ToolOptions()
        options.splitParts = 3
        let split = try await plain(.splitVideo, [clip], options: options)
        XCTAssertEqual(split.map(\.lastPathComponent), ["clip Clips"])
        XCTAssertEqual(TestSupport.directoryContents(split[0]), ["clip 01.mp4", "clip 02.mp4", "clip 03.mp4"])

        let other = try TestSupport.makeMP4(in: dir, seconds: 2, audio: false, size: "320x240", name: "silent.mp4")
        let joined = try await plain(.joinVideos, [clip, other])
        XCTAssertEqual(joined.map(\.lastPathComponent), ["Joined.mp4"])
        let joinedInfo = await engine.probe(joined[0])
        XCTAssertEqual(joinedInfo.duration ?? 0, 6, accuracy: 0.7)
        XCTAssertEqual(joinedInfo.video?.width, 160, "the first clip sets the canvas")
        XCTAssertNotNil(joinedInfo.audio, "silent clips get silent audio")

        let wav = try TestSupport.makeWAV(in: dir)
        let viz = try await plain(.audioToVideo, [wav])
        XCTAssertEqual(viz.map(\.lastPathComponent), ["tone Visualizer.mp4"])
        let awaited9 = await engine.probe(viz[0])
        XCTAssertEqual(awaited9.video?.width, 1280)
    }

    func testAtempoChainStaysInRange() {
        XCTAssertEqual(MediaEngine.atempoChain(2), "atempo=2")
        XCTAssertEqual(MediaEngine.atempoChain(4), "atempo=2.0,atempo=2")
        XCTAssertEqual(MediaEngine.atempoChain(0.25), "atempo=0.5,atempo=0.5")
    }

    func testMediaToolsReportMissingFFmpeg() async throws {
        let wav = dir.appendingPathComponent("a.wav")
        try Data().write(to: wav)
        let none = Availability.withoutFFmpeg()
        do {
            _ = try await ToolService.work(.plain(.normalizeAudio), sources: [wav], formats: ["WAV"], policy: OutputPolicy(), availability: none)(JobContext(reportProgress: { _ in }))
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .toolMissing("ffmpeg"))
        }
        XCTAssertFalse(ToolService.supports(.normalizeAudio, input: "WAV", availability: none))
    }

    // MARK: - PDF, collage, QR

    func testSplitPDFWritesOnePagePDFsInAFolder() async throws {
        let source = pdf(pages: 3)
        let out = try await plain(.splitPDF, [source])
        XCTAssertEqual(out.map(\.lastPathComponent), ["doc Pages"])
        XCTAssertEqual(TestSupport.directoryContents(out[0]), ["doc 01.pdf", "doc 02.pdf", "doc 03.pdf"])
        for page in TestSupport.directoryContents(out[0]) {
            XCTAssertEqual(PDFDocument(url: out[0].appendingPathComponent(page))?.pageCount, 1)
        }
        XCTAssertTrue(PDFDocument(url: out[0].appendingPathComponent("doc 02.pdf"))?.string?.contains("Page 2") ?? false)
    }

    func testMergePDFsInSelectionOrderAndNeedsTwo() async throws {
        let a = pdf(pages: 2, name: "a.pdf"), b = pdf(pages: 3, name: "b.pdf")
        let out = try await plain(.mergePDF, [b, a])
        XCTAssertEqual(out.map(\.lastPathComponent), ["Merged.pdf"])
        let merged = try XCTUnwrap(PDFDocument(url: out[0]))
        XCTAssertEqual(merged.pageCount, 5)
        XCTAssertTrue(merged.page(at: 0)?.string?.contains("Page 1") ?? false)
        do { _ = try await plain(.mergePDF, [a]); XCTFail("expected an error") } catch {}
    }

    func testCreatePDFFromImages() async throws {
        let a = dir.appendingPathComponent("one.png"), b = dir.appendingPathComponent("two.jpg")
        try TestSupport.write(TestSupport.makeImage(width: 200, height: 100), as: "public.png", to: a)
        try TestSupport.write(TestSupport.makeImage(width: 100, height: 200), as: "public.jpeg", to: b)
        let out = try await plain(.createPDF, [a, b])
        XCTAssertEqual(out.map(\.lastPathComponent), ["one Images.pdf"])
        XCTAssertEqual(PDFDocument(url: out[0])?.pageCount, 2)
    }

    func testCollageGridAndOutput() async throws {
        XCTAssertEqual(CollageEngine.grid(count: 2).columns, 2)
        XCTAssertEqual(CollageEngine.grid(count: 5).columns, 3)
        XCTAssertEqual(CollageEngine.grid(count: 5).rows, 2)
        let urls = try (0..<3).map { index -> URL in
            let url = dir.appendingPathComponent("p\(index).png")
            try TestSupport.write(TestSupport.makeImage(width: 300, height: 200), as: "public.png", to: url)
            return url
        }
        let out = try await plain(.createCollage, urls)
        XCTAssertEqual(out.map(\.lastPathComponent), ["Collage.png"])
        let info = try XCTUnwrap(TestSupport.info(out[0]))
        XCTAssertEqual(info.width, 2 * 800 + 3 * 8)
        XCTAssertEqual(info.height, 2 * 800 + 3 * 8)
    }

    func testOrganizeReordersRotatesAndDeletesPages() async throws {
        let source = pdf(pages: 3)
        let edits = [PDFPageEdit(index: 2), PDFPageEdit(index: 0, rotation: 90)]
        let out = try await runTool(.organize(edits, sameWidth: false), [source])
        XCTAssertEqual(out.map(\.lastPathComponent), ["doc Organized.pdf"])
        let result = try XCTUnwrap(PDFDocument(url: out[0]))
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertTrue(result.page(at: 0)?.string?.contains("Page 3") ?? false)
        XCTAssertEqual(result.page(at: 1)?.rotation, 90)
        XCTAssertTrue(result.page(at: 1)?.string?.contains("Page 1") ?? false)
        do { _ = try await runTool(.organize([], sameWidth: false), [source]); XCTFail("expected an error") } catch {}
    }

    func testOrganizeSameWidthScalesEveryPage() async throws {
        let narrow = dir.appendingPathComponent("narrow.pdf"), wide = dir.appendingPathComponent("wide.pdf")
        try PDFEngine.makePDF(from: [(TestSupport.makeImage(width: 300, height: 400), 72)], to: narrow)
        try PDFEngine.makePDF(from: [(TestSupport.makeImage(width: 600, height: 300), 72)], to: wide)
        let merged = dir.appendingPathComponent("mixed.pdf")
        try PDFTools.merge(sources: [narrow, wide], output: merged)
        let out = try await runTool(.organize([PDFPageEdit(index: 0), PDFPageEdit(index: 1)], sameWidth: true), [merged])
        let result = try XCTUnwrap(PDFDocument(url: out[0]))
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).width, 600)
        XCTAssertEqual(result.page(at: 1)?.bounds(for: .mediaBox).width, 600)
        XCTAssertEqual(result.page(at: 0)?.bounds(for: .mediaBox).height, 800, "300×400 scaled 2×")
    }

    private func qrImage(_ text: String) -> CGImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        let scaled = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)!
    }

    func testReadQRFromImageAndPDF() throws {
        let png = dir.appendingPathComponent("qr.png")
        try TestSupport.write(qrImage("https://example.com/hello"), as: "public.png", to: png)
        let fromImage = try QREngine.scan(file: png, format: "PNG")
        XCTAssertEqual(fromImage.map(\.payload), ["https://example.com/hello"])
        XCTAssertEqual(fromImage.first?.kind, "QR")
        XCTAssertNotNil(fromImage.first?.url)

        let pdfURL = dir.appendingPathComponent("qr.pdf")
        try PDFEngine.makePDF(from: [(qrImage("first"), 72), (qrImage("second"), 72)], to: pdfURL)
        let fromPDF = try QREngine.scan(file: pdfURL, format: "PDF")
        XCTAssertEqual(Set(fromPDF.map(\.payload)), ["first", "second"])
        XCTAssertEqual(fromPDF.first { $0.payload == "second" }?.page, 2)
        XCTAssertNil(fromPDF.first?.url, "plain text isn't a link")

        let blank = dir.appendingPathComponent("blank.png")
        try TestSupport.write(TestSupport.makeImage(width: 100, height: 100), as: "public.png", to: blank)
        XCTAssertTrue(try QREngine.scan(file: blank, format: "PNG").isEmpty)
    }

    // MARK: - Availability

    func testAvailabilityMatchesImplementedTools() {
        XCTAssertTrue(ToolService.supports(.splitPDF, input: "PDF", availability: availability))
        XCTAssertTrue(ToolService.supports(.readQR, input: "JPG", availability: availability))
        XCTAssertTrue(ToolService.supports(.createCollage, input: "PNG", availability: availability))
        XCTAssertEqual(ToolService.supports(.trimVideo, input: "MP4", availability: availability), availability.media.hasFFmpeg)
        XCTAssertFalse(ToolService.supports(.trimVideo, input: "WAV", availability: availability))
        XCTAssertFalse(ToolService.supports(.splitPDF, input: "JPG", availability: availability))
    }
}
