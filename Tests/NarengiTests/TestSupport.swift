import AppKit
import ImageIO
import XCTest
@testable import Narengi

/// Vision's barcode detector returns nothing on GitHub's virtual-machine runners (no neural engine), which says
/// nothing about the code. Locally, and on real Macs, these checks always run.
func skipVisionOnVirtualMachines() throws {
    if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil { throw XCTSkip("Vision barcode detection isn't available on virtualised CI runners") }
}

enum TestSupport {
    static func makeTempDirectory(file: StaticString = #filePath) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("narengi-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A diagonal gradient, optionally with a transparent left half.
    static func makeImage(width: Int, height: Int, transparentLeftHalf: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        if transparentLeftHalf {
            context.setBlendMode(.clear)
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        }
        return context.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, as uti: String, to url: URL, properties: [CFString: Any] = [:]) throws -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    struct ImageInfo {
        var width: Int
        var height: Int
        var type: String?
        var frames: Int
        var properties: [CFString: Any]
    }

    static func info(_ url: URL) -> ImageInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return ImageInfo(
            width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
            height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0,
            type: CGImageSourceGetType(source) as String?,
            frames: CGImageSourceGetCount(source),
            properties: properties)
    }

    /// RGBA of one pixel (top-left origin).
    static func pixel(_ url: URL, x: Int, y: Int) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = Optional(context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))),
              let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let offset = (y * image.width + x) * 4
        return [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
    }

    /// Writes a PDF whose pages each hold lines of (text, font size).
    static func makePDF(pages: [[(String, CGFloat)]], at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for lines in pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            var y: CGFloat = 700
            for (text, size) in lines {
                (text as NSString).draw(at: CGPoint(x: 72, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size)])
                y -= size * 1.7
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    static func directoryContents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: - Extra fixtures

    /// Black text on white, big enough for Vision to read reliably.
    static func makeTextImage(_ lines: [String], size: CGSize = CGSize(width: 1400, height: 500)) -> CGImage {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        var y = size.height - 120
        for line in lines {
            (line as NSString).draw(at: CGPoint(x: 60, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: 80, weight: .bold), .foregroundColor: NSColor.black])
            y -= 130
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    /// Runs a tool synchronously; returns its stdout.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.qualityOfService = .userInitiated  // we block on it from a user-initiated thread
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }

    static var ffmpegURL: URL? { BundledToolLocator.shared.locate(.ffmpeg) }

    /// Generates media with ffmpeg's test sources. Skips the test when ffmpeg isn't installed.
    static func ffmpegFixture(_ name: String, in directory: URL, arguments: [String]) throws -> URL {
        guard let ffmpeg = ffmpegURL else { throw XCTSkip("ffmpeg isn't installed") }
        let url = directory.appendingPathComponent(name)
        try run(ffmpeg.path, ["-hide_banner", "-loglevel", "error", "-y"] + arguments + [url.path])
        return url
    }

    static func makeWAV(in directory: URL, seconds: Int = 1, name: String = "tone.wav") throws -> URL {
        try ffmpegFixture(name, in: directory, arguments: ["-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)"])
    }

    static func makeMP4(in directory: URL, seconds: Int = 1, audio: Bool = true, size: String = "160x120", name: String = "clip.mp4") throws -> URL {
        var args = ["-f", "lavfi", "-i", "testsrc=size=\(size):rate=10:duration=\(seconds)"]
        if audio { args += ["-f", "lavfi", "-i", "sine=frequency=330:duration=\(seconds)"] }
        args += ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
        if audio { args += ["-c:a", "aac"] }
        return try ffmpegFixture(name, in: directory, arguments: args)
    }

    /// File names inside an archive, via bsdtar.
    static func archiveListing(_ url: URL) throws -> [String] {
        try run("/usr/bin/tar", ["-tf", url.path]).split(separator: "\n").map(String.init).sorted()
    }
}
