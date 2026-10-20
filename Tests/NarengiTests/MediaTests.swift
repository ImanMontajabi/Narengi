import XCTest
@testable import Narengi

final class MediaTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private let engine = MediaEngine(env: .shared)

    private func convert(_ source: URL, to target: String, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        let from = try XCTUnwrap(FormatCatalog.format(for: source))
        return try await ConversionService.run(
            source: source, options: ConversionOptions(sourceFormat: from, targetFormat: target), progress: progress)[0]
    }

    // MARK: Parsing (no ffmpeg needed)

    private let probeSample = """
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'clip.mov':
      Duration: 00:00:04.07, start: 0.000000, bitrate: 2359 kb/s
      Stream #0:0[0x1](und): Video: hevc (Main) (hvc1 / 0x31637668), yuv420p(tv), 3130x2160, 2343 kb/s, 60 fps
      Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, mono, fltp, 2 kb/s
    """

    func testProbeParsing() {
        let probe = MediaProbe.parse(probeSample)
        XCTAssertEqual(probe.duration, 4.07)
        XCTAssertEqual(probe.video?.width, 3130)
        XCTAssertEqual(probe.video?.height, 2160)
        XCTAssertEqual(probe.audio, .init(sampleRate: 44100, channels: 1))
    }

    func testProbeIgnoresCoverArt() {
        let text = "  Duration: 00:03:00.00, start: 0\n  Stream #0:0: Audio: mp3, 48000 Hz, stereo, fltp, 320 kb/s\n  Stream #0:1: Video: mjpeg (Baseline), yuvj420p, 600x600, 90k tbn (attached pic)\n"
        let probe = MediaProbe.parse(text)
        XCTAssertNil(probe.video)
        XCTAssertEqual(probe.audio?.channels, 2)
        XCTAssertEqual(probe.duration, 180)
    }

    func testProgressLinesAndClock() {
        XCTAssertEqual(MediaProbe.progressFraction(line: "out_time_us=2000000", duration: 4), 0.5)
        XCTAssertEqual(MediaProbe.progressFraction(line: "out_time_ms=8000000", duration: 4), 1)
        XCTAssertNil(MediaProbe.progressFraction(line: "frame=12", duration: 4))
        XCTAssertNil(MediaProbe.progressFraction(line: "out_time_us=1", duration: nil))
        XCTAssertEqual(MediaProbe.parseClock("01:00:01.5"), 3601.5)
        XCTAssertNil(MediaProbe.parseClock("N/A"))
    }

    func testEncoderListParsing() {
        let text = "Encoders:\n V..... = Video\n ------\n V....D libx264  libx264 H.264\n A....D libmp3lame  MP3\n"
        let set = MediaEnvironment.parseEncoders(text)
        XCTAssertTrue(set.contains("libx264"))
        XCTAssertTrue(set.contains("libmp3lame"))
        XCTAssertFalse(set.contains("V....."))
    }

    func testCodecChoicesFollowTheAvailableEncoders() throws {
        let full = MediaEngine(env: .init(ffmpeg: URL(fileURLWithPath: "/x/ffmpeg"), encoders: ["libmp3lame", "aac", "libx264", "libvpx-vp9", "wmv2", "wmav2", "libopus", "libvorbis"]))
        XCTAssertEqual(try full.audioCodecArguments(for: "MP3", kbps: 192), ["-c:a", "libmp3lame", "-b:a", "192k"])
        XCTAssertEqual(try full.audioCodecArguments(for: "OGG", kbps: 192), ["-c:a", "libvorbis", "-q:a", "6"])
        XCTAssertTrue(try full.videoCodecArguments(for: "MP4").contains("+faststart"))
        XCTAssertFalse(try full.videoCodecArguments(for: "MKV").contains("+faststart"))

        let bare = MediaEngine(env: .init(ffmpeg: URL(fileURLWithPath: "/x/ffmpeg"), encoders: ["aac"]))
        XCTAssertThrowsError(try bare.audioCodecArguments(for: "MP3", kbps: 192)) { XCTAssertEqual($0 as? ConversionError, .encoderMissing("MP3")) }
        XCTAssertThrowsError(try bare.videoCodecArguments(for: "WEBM"))
        XCTAssertTrue(bare.supports(source: "WAV", target: "M4A"))
        XCTAssertFalse(bare.supports(source: "WAV", target: "MP3"))
        XCTAssertFalse(bare.supports(source: "MP4", target: "MP3"))
        XCTAssertTrue(bare.supports(source: "MP4", target: "GIF"))
        XCTAssertFalse(MediaEngine(env: .none).supports(source: "WAV", target: "WAV"))
    }

    func testWithoutFFmpegAudioAndVideoRoutesAreHiddenButImagesStayAvailable() {
        let off = Availability.withoutFFmpeg()
        XCTAssertFalse(off.conversion(from: "WAV", to: "MP3"))
        XCTAssertFalse(off.conversion(from: "MP4", to: "GIF"))
        XCTAssertTrue(off.conversion(from: "PNG", to: "JPG"))
        XCTAssertTrue(off.conversion(from: "MD", to: "DOCX"))
    }

    func testMissingFFmpegGivesAHelpfulError() async throws {
        let wav = directory.appendingPathComponent("a.wav")
        try Data().write(to: wav)
        do {
            _ = try await ConversionService.run(
                source: wav, options: ConversionOptions(sourceFormat: "WAV", targetFormat: "MP3"),
                availability: .withoutFFmpeg())
            XCTFail("expected toolMissing")
        } catch {
            XCTAssertEqual(error as? ConversionError, .toolMissing("ffmpeg"))
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("brew install ffmpeg") == true)
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["a.wav"])
    }

    // MARK: Real conversions (need ffmpeg)

    func testAudioConvertsToEveryOfferedFormat() async throws {
        let wav = try TestSupport.makeWAV(in: directory)
        let expected: [String: String] = ["MP3": "mp3", "M4A": "m4a", "FLAC": "flac", "OGG": "ogg", "OPUS": "opus", "AIFF": "aiff", "WMA": "wma"]
        var converted = 0
        for target in FormatCatalog.conversionTargets(from: "WAV") {
            guard engine.supports(source: "WAV", target: target) else { continue }
            let out = try await convert(wav, to: target)
            XCTAssertEqual(out.pathExtension, expected[target], target)
            XCTAssertEqual(out.deletingPathExtension().lastPathComponent, "tone")
            let probe = await engine.probe(out)
            XCTAssertNotNil(probe.audio, "\(target) must contain an audio stream")
            XCTAssertEqual(probe.duration ?? 0, 1, accuracy: 0.35, target)
            converted += 1
        }
        XCTAssertGreaterThanOrEqual(converted, 4, "this Mac's ffmpeg should handle most audio formats")
    }

    func testVideoConvertsToContainersGIFAndMP3() async throws {
        let mp4 = try TestSupport.makeMP4(in: directory)
        for target in ["MOV", "MKV", "WEBM", "AVI", "WMV"] where engine.supports(source: "MP4", target: target) {
            let out = try await convert(mp4, to: target)
            let probe = await engine.probe(out)
            XCTAssertEqual(probe.video?.width, 160, target)
            XCTAssertEqual(probe.video?.height, 120, target)
            XCTAssertNotNil(probe.audio, target)
        }

        let gif = try await convert(mp4, to: "GIF")
        XCTAssertEqual(String(decoding: try Data(contentsOf: gif).prefix(6), as: UTF8.self), "GIF89a")
        let gifProbe = await engine.probe(gif)
        XCTAssertEqual(gifProbe.video?.width, 160)

        if engine.supports(source: "MP4", target: "MP3") {
            let mp3 = try await convert(mp4, to: "MP3")
            let probe = await engine.probe(mp3)
            XCTAssertNil(probe.video)
            XCTAssertNotNil(probe.audio)
        }
        // And GIF → video.
        if engine.supports(source: "GIF", target: "MP4") {
            let back = try await convert(gif, to: "MP4")
            let probe = await engine.probe(back)
            XCTAssertEqual(probe.video?.width, 160)
        }
    }

    func testOddSizedVideoIsPaddedToEvenDimensions() async throws {
        // x264 refuses odd sizes, so build the fixture with lossless FFV1 in Matroska.
        let odd = try TestSupport.ffmpegFixture("odd.mkv", in: directory, arguments: [
            "-f", "lavfi", "-i", "testsrc=size=161x121:rate=10:duration=1", "-c:v", "ffv1"])
        guard engine.supports(source: "MKV", target: "MP4") else { throw XCTSkip("no H.264 encoder") }
        let out = try await convert(odd, to: "MP4")
        let probe = await engine.probe(out)
        XCTAssertEqual(probe.video?.width, 160)
        XCTAssertEqual(probe.video?.height, 120)
    }

    func testMP3ExportFromAVideoWithoutAudioFailsClearly() async throws {
        guard engine.supports(source: "MP4", target: "MP3") else { throw XCTSkip("no MP3 encoder") }
        let silent = try TestSupport.makeMP4(in: directory, audio: false, name: "silent.mp4")
        do {
            _ = try await convert(silent, to: "MP3")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("no audio track") == true, "\(error)")
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["silent.mp4"])
    }

    func testProgressIsReportedBetweenZeroAndOne() async throws {
        let mp4 = try TestSupport.makeMP4(in: directory, seconds: 3)
        let values = Locked<[Double]>([])
        _ = try await convert(mp4, to: "MKV") { fraction in values.mutate { $0.append(fraction) } }
        let seen = values.value
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { (0...1).contains($0) }, "\(seen)")
        XCTAssertEqual(seen.last, 1)
    }

    func testCancellingStopsFFmpegAndLeavesNoPartialFile() async throws {
        let long = try TestSupport.makeMP4(in: directory, seconds: 60, size: "1280x720", name: "long.mp4")
        let work = ConversionService.work(
            source: long, options: ConversionOptions(sourceFormat: "MP4", targetFormat: "MKV"), policy: OutputPolicy())
        let task = Task { try await work(JobContext(reportProgress: { _ in })) }
        try await Task.sleep(nanoseconds: 700_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        XCTAssertEqual(TestSupport.directoryContents(directory), ["long.mp4"], "no .narengi-tmp file may remain")
    }
}

/// A tiny thread-safe box for collecting values from `@Sendable` callbacks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&stored); lock.unlock() }
}
