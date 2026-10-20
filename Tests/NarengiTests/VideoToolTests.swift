import CoreGraphics
import XCTest
@testable import Narengi

final class VideoToolTests: XCTestCase {
    private var dir: URL!
    private let availability = Availability.shared
    private var engine: MediaEngine { MediaEngine(env: availability.media) }

    override func setUpWithError() throws { dir = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func requireVideo() throws {
        guard availability.media.hasFFmpeg else { throw XCTSkip("ffmpeg isn't installed") }
        guard (try? engine.h264Arguments(crf: 20)) != nil else { throw XCTSkip("no H.264 encoder") }
    }

    private func run(_ operation: ToolOperation, _ source: URL, format: String? = nil) async throws -> [URL] {
        let format = format ?? FormatCatalog.detect(source) ?? "?"
        return try await ToolService.work(operation, sources: [source], formats: [format], policy: OutputPolicy(), availability: availability)(JobContext(reportProgress: { _ in }))
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
        let context = try! ImageOps.makeContext(width: 1, height: 1)
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let d = context.data!.assumingMemoryBound(to: UInt8.self)
        return [Int(d[0]), Int(d[1]), Int(d[2])]
    }

    private func clip(seconds: Int = 4) throws -> URL { try TestSupport.makeMP4(in: dir, seconds: seconds, size: "320x240") }

    // MARK: - Pure helpers

    func testIntervalsAreSortedClampedAndMerged() {
        let list = MediaEngine.normalized([
            BleepInterval(start: 5, end: 3), BleepInterval(start: 1, end: 2), BleepInterval(start: 1.5, end: 2.5),
            BleepInterval(start: 9, end: 20), BleepInterval(start: 4, end: 4.001),
        ], duration: 10)
        XCTAssertEqual(list.map { [$0.start, $0.end] }, [[1, 2.5], [3, 5], [9, 10]])
        XCTAssertEqual(MediaEngine.bleepCondition(list), "between(t,1.000,2.500)+between(t,3.000,5.000)+between(t,9.000,10.000)")
        XCTAssertTrue(MediaEngine.normalized([], duration: 5).isEmpty)
    }

    func testCropRectIsEvenAndInsideTheFrame() {
        let box = MediaEngine.croppedRect(CropSpec(rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)), video: (161, 121))
        XCTAssertEqual(box.w % 2, 0)
        XCTAssertEqual(box.h % 2, 0)
        XCTAssertLessThanOrEqual(box.x + box.w, 161)
        XCTAssertLessThanOrEqual(box.y + box.h, 121)
        let full = MediaEngine.croppedRect(CropSpec(rect: CGRect(x: 0, y: 0, width: 1, height: 1)), video: (161, 121))
        XCTAssertEqual(full.w, 160)
        XCTAssertEqual(full.h, 120)
        let tiny = MediaEngine.croppedRect(CropSpec(rect: CGRect(x: 0.99, y: 0.99, width: 0.001, height: 0.001)), video: (100, 100))
        XCTAssertGreaterThanOrEqual(tiny.w, 2)
        XCTAssertLessThanOrEqual(tiny.x + tiny.w, 100)
    }

    func testRedactionGraphShape() {
        let regions = [VideoRedaction(rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4), style: .blackout),
                       VideoRedaction(rect: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3), style: .pixelate)]
        let graph = MediaEngine.redactionGraph(regions: regions, video: (320, 240), start: 1, end: 2)
        XCTAssertTrue(graph.contains("drawbox=x=32:y=48:w="), graph)
        XCTAssertTrue(graph.contains("enable='between(t,1.000,2.000)'"))
        XCTAssertTrue(graph.contains("[s1]crop="))
        XCTAssertTrue(graph.hasSuffix("[out]"))
        XCTAssertFalse(MediaEngine.redactionGraph(regions: regions, video: (320, 240), start: nil, end: nil).contains("enable"))
    }

    func testWaveformPeaksPerBin() {
        var data = Data()
        for value in [Int16](repeating: 0, count: 100) + [Int16](repeating: 16384, count: 100) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        let peaks = MediaEngine.peaks(of: data, bins: 2)
        XCTAssertEqual(peaks[0], 0)
        XCTAssertEqual(peaks[1], 0.5, accuracy: 0.001)
        XCTAssertTrue(MediaEngine.peaks(of: Data(), bins: 4).isEmpty)
    }

    // MARK: - Trim

    func testTrimKeepsTheChosenStretchWithoutBlackLeadIn() async throws {
        try requireVideo()
        let source = try clip(seconds: 4)
        let out = try await run(.trimVideo(start: 1, end: 3), source)
        XCTAssertEqual(out.map(\.lastPathComponent), ["clip Trimmed.mp4"])
        let info = await engine.probe(out[0])
        XCTAssertEqual(info.duration ?? 0, 2, accuracy: 0.35)
        XCTAssertNotNil(info.audio)
        let first = try await engine.frame(of: out[0], at: 0)
        let p = pixel(first, 40, 30)
        XCTAssertGreaterThan(p[0] + p[1] + p[2], 60, "the first frame isn't black")
        do { _ = try await run(.trimVideo(start: 2, end: 2.01), source); XCTFail("expected an error") } catch {}
    }

    // MARK: - Crop

    func testCropVideoToAnEvenRectangle() async throws {
        try requireVideo()
        let source = try clip()
        let spec = CropSpec(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let out = try await run(.cropVideo(spec), source)
        XCTAssertEqual(out.map(\.lastPathComponent), ["clip Cropped.mp4"])
        let info = await engine.probe(out[0])
        XCTAssertEqual(info.video?.width, 160)
        XCTAssertEqual(info.video?.height, 120)
        // The crop shows the middle of the source, so its top-left matches the source at (80, 60).
        let original = try await engine.frame(of: source, at: 0.5)
        let cropped = try await engine.frame(of: out[0], at: 0.5)
        let a = pixel(original, 90, 70), b = pixel(cropped, 10, 10)
        for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 24) }
    }

    // MARK: - Redact

    func testRedactBlackoutPixelateAndBlurChangeOnlyTheirBoxes() async throws {
        try requireVideo()
        // Grain everywhere, so blur and pixelate visibly change what they cover.
        let source = try TestSupport.ffmpegFixture("grain.mp4", in: dir, arguments: [
            "-f", "lavfi", "-i", "color=c=0x8899aa:s=320x240:r=10:d=3,noise=alls=80:allf=t+u",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "12", "-pix_fmt", "yuv420p"])
        let original = try await engine.frame(of: source, at: 0.5)
        XCTAssertGreaterThan(pixel(original, 100, 80).reduce(0, +), 120, "fixture is bright where we cover it")
        for style in [VideoRedaction.Style.blackout, .pixelate, .blur] {
            let regions = [VideoRedaction(rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), style: style)]
            let out = try await run(.redactVideo(regions, start: nil, end: nil), source)
            XCTAssertEqual(out.map(\.lastPathComponent), ["grain Redacted.mp4"])
            let frame = try await engine.frame(of: out[0], at: 0.5)
            if style == .blackout {
                for (x, y) in [(100, 80), (160, 120), (220, 160)] {
                    XCTAssertLessThan(pixel(frame, x, y).reduce(0, +), 45, "blackout is black at \(x),\(y)")
                }
            } else {
                // Grain has a huge pixel-to-pixel spread; blur and pixelate flatten it.
                func spread(_ image: CGImage) -> Int {
                    let values = (0..<20).map { pixel(image, 100 + $0 * 2, 100)[0] }
                    return (values.max() ?? 0) - (values.min() ?? 0)
                }
                XCTAssertLessThan(spread(frame), spread(original) / 2, "\(style) flattens the covered grain")
            }
            for (x, y) in [(10, 10), (310, 230), (30, 200)] {
                let a = pixel(frame, x, y), b = pixel(original, x, y)
                for c in 0..<3 { XCTAssertEqual(a[c], b[c], accuracy: 40, "\(style) leaves (\(x),\(y)) alone") }
            }
            try? FileManager.default.removeItem(at: out[0])
        }
    }

    func testRedactHonoursTheTimeRangeAndStripsMetadata() async throws {
        try requireVideo()
        let source = try TestSupport.ffmpegFixture("tagged.mp4", in: dir, arguments: [
            "-f", "lavfi", "-i", "testsrc=size=320x240:rate=10:duration=4", "-f", "lavfi", "-i", "sine=frequency=330:duration=4",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-metadata", "title=Secret Title"])
        let regions = [VideoRedaction(rect: CGRect(x: 0, y: 0, width: 1, height: 1), style: .blackout)]
        let out = try await run(.redactVideo(regions, start: 1, end: 2), source)
        let before = try await engine.frame(of: out[0], at: 0.3)
        let during = try await engine.frame(of: out[0], at: 1.5)
        let after = try await engine.frame(of: out[0], at: 3.0)
        XCTAssertGreaterThan(pixel(before, 40, 30).reduce(0, +), 60, "before the range: untouched")
        XCTAssertLessThan(pixel(during, 40, 30).reduce(0, +), 40, "inside the range: covered")
        XCTAssertGreaterThan(pixel(after, 40, 30).reduce(0, +), 60, "after the range: untouched")
        XCTAssertNil(try Data(contentsOf: out[0]).range(of: Data("Secret Title".utf8)), "metadata is stripped")
        do { _ = try await run(.redactVideo([], start: nil, end: nil), source); XCTFail("expected an error") } catch {}
    }

    // MARK: - Bleep

    func testBleepReplacesOnlyTheChosenStretchWithATone() async throws {
        try requireVideo()
        let silent = try TestSupport.ffmpegFixture("quiet.wav", in: dir, arguments: ["-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "3"])
        let out = try await run(.bleep([BleepInterval(start: 1, end: 2)]), silent)
        XCTAssertEqual(out.map(\.lastPathComponent), ["quiet Bleeped.wav"])
        let info = await engine.probe(out[0])
        XCTAssertEqual(info.duration ?? 0, 3, accuracy: 0.2)
        let peaks = try await engine.waveform(of: out[0], bins: 30)
        XCTAssertEqual(peaks.count, 30)
        XCTAssertLessThan(peaks[2], 0.02, "before the interval: silence")
        XCTAssertGreaterThan(peaks[15], 0.2, "inside the interval: the bleep")
        XCTAssertLessThan(peaks[27], 0.02, "after the interval: silence")
    }

    func testBleepMutesTheOriginalSoundInsideTheInterval() async throws {
        try requireVideo()
        // A loud 440 Hz tone at full volume; the bleep (0.35) must be quieter than that, proving the original is gone.
        let loud = try TestSupport.ffmpegFixture("loud.wav", in: dir, arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-af", "volume=6"])
        let before = try await engine.waveform(of: loud, bins: 30)
        XCTAssertGreaterThan(before[15], 0.6)
        let out = try await run(.bleep([BleepInterval(start: 1, end: 2)]), loud)
        let peaks = try await engine.waveform(of: out[0], bins: 30)
        XCTAssertLessThan(peaks[15], 0.45, "the original sound is muted and replaced by the quieter tone")
        XCTAssertGreaterThan(peaks[5], 0.6, "outside the interval the original is untouched")
    }

    func testBleepOnAVideoKeepsTheVideoStream() async throws {
        try requireVideo()
        let source = try clip(seconds: 3)
        let out = try await run(.bleep([BleepInterval(start: 0.5, end: 1.5)]), source)
        XCTAssertEqual(out.map(\.lastPathComponent), ["clip Bleeped.mp4"])
        let info = await engine.probe(out[0])
        XCTAssertEqual(info.video?.width, 320)
        XCTAssertNotNil(info.audio)
        do { _ = try await run(.bleep([]), source); XCTFail("expected an error") } catch {}
    }

    // MARK: - Previews and availability

    func testFramePreviewAndWaveform() async throws {
        try requireVideo()
        let source = try clip()
        let frame = try await engine.frame(of: source, at: 1, maxEdge: 160)
        XCTAssertEqual(frame.width, 160)
        XCTAssertGreaterThan(pixel(frame, 20, 15).reduce(0, +), 60, "the preview has real picture content, not a blank image")
        let peaks = try await engine.waveform(of: source, bins: 50)
        XCTAssertEqual(peaks.count, 50)
        XCTAssertGreaterThan(peaks.max() ?? 0, 0.05)
    }

    func testToolsAreAvailableOnlyWhereTheyWork() {
        for tool in [ToolID.trimVideo, .cropVideo, .redactVideo] {
            XCTAssertEqual(ToolService.supports(tool, input: "MP4", availability: availability), availability.media.hasFFmpeg)
            XCTAssertFalse(ToolService.supports(tool, input: "WAV", availability: availability))
            XCTAssertFalse(ToolService.supports(tool, input: "MP4", availability: .withoutFFmpeg()))
        }
        XCTAssertEqual(ToolService.supports(.redactAudio, input: "WAV", availability: availability), availability.media.hasFFmpeg)
        XCTAssertEqual(ToolService.supports(.redactAudio, input: "MP4", availability: availability), availability.media.hasFFmpeg)
        XCTAssertFalse(ToolService.supports(.redactAudio, input: "JPG", availability: availability))
        XCTAssertFalse(ToolService.supports(.redactAudio, input: "WAV", availability: .withoutFFmpeg()))
    }
}
