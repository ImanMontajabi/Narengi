import XCTest
@testable import Narengi

/// Guards the self-contained helper tools in `Narengi/Resources/Vendor`: if someone re-runs a script badly or a
/// library goes missing, these fail instead of the app failing on a user's Mac.
final class VendorBundleTests: XCTestCase {
    private var vendor: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Narengi/Resources/Vendor")
    }

    /// The vendor folder is not in the repository; on a fresh clone these checks are skipped until the scripts have run.
    private func requireVendor() throws {
        guard FileManager.default.fileExists(atPath: vendor.appendingPathComponent("bin/ffmpeg").path) else {
            throw XCTSkip("Resources/Vendor is empty; run scripts/setup-vendor.sh and scripts/bundle-ffmpeg.sh")
        }
    }

    private func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.qualityOfService = .userInitiated  // we block on it from a user-initiated thread
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testTheLocatorFindsAllThreeBundledTools() throws {
        try requireVendor()
        let locator = BundledToolLocator(vendorDirectory: vendor, fallbackDirectories: [])
        for tool in ExternalTool.allCases {
            let url = locator.locate(tool)
            XCTAssertNotNil(url, "\(tool) is missing from Resources/Vendor")
            XCTAssertTrue(url?.path.hasPrefix(vendor.path) ?? false, "\(tool) must come from the bundle, not Homebrew")
        }
    }

    func testBundledBinariesAreArm64AndPointOnlyAtTheSystemOrTheirNeighbours() throws {
        try requireVendor()
        var files = [vendor.appendingPathComponent("bin/ffmpeg"), vendor.appendingPathComponent("cwebp")]
        files += (try FileManager.default.contentsOfDirectory(at: vendor.appendingPathComponent("lib"), includingPropertiesForKeys: nil)).filter { $0.pathExtension == "dylib" }
        XCTAssertGreaterThan(files.count, 5, "ffmpeg's libraries are bundled")
        for file in files {
            XCTAssertTrue(try run("/usr/bin/file", ["-b", file.path]).output.contains("arm64"), "\(file.lastPathComponent) is arm64")
            let deps = try run("/usr/bin/otool", ["-L", file.path]).output.split(separator: "\n").dropFirst().map {
                String($0).trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            }
            for dep in deps where !dep.isEmpty {
                XCTAssertTrue(dep.hasPrefix("/usr/lib/") || dep.hasPrefix("/System/") || dep.hasPrefix("@loader_path/"),
                              "\(file.lastPathComponent) depends on \(dep), which won't exist on another Mac")
                if dep.hasPrefix("@loader_path/") {
                    let target = file.deletingLastPathComponent().appendingPathComponent(String(dep.dropFirst("@loader_path/".count)))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "\(file.lastPathComponent) needs \(dep), which is missing")
                }
            }
        }
    }

    func testBundledFFmpegRunsOnItsOwnWithACleanEnvironment() throws {
        try requireVendor()
        let ffmpeg = vendor.appendingPathComponent("bin/ffmpeg").path
        let version = try run(ffmpeg, ["-version"], environment: [:])
        XCTAssertEqual(version.status, 0, version.output)
        XCTAssertTrue(version.output.hasPrefix("ffmpeg version"))
        let encoders = try run(ffmpeg, ["-hide_banner", "-encoders"], environment: [:]).output
        for encoder in ["libx264", "aac", "libmp3lame", "libvpx-vp9"] { XCTAssertTrue(encoders.contains(" \(encoder) "), "\(encoder) missing") }
        // The app's own capability check sees the same encoders through the bundle.
        let env = MediaEnvironment.discover(BundledToolLocator(vendorDirectory: vendor, fallbackDirectories: []))
        XCTAssertTrue(env.hasFFmpeg)
        XCTAssertTrue(env.hasEncoder("libx264"))
    }

    func testBundledFFmpegActuallyConvertsSomething() throws {
        try requireVendor()
        let dir = try TestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("tone.mp3")
        let result = try run(vendor.appendingPathComponent("bin/ffmpeg").path,
                             ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", out.path], environment: [:])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertGreaterThan(ImageOps.fileSize(out), 1000)
    }

    func testExifToolAndCwebpRunFromTheBundle() throws {
        try requireVendor()
        let exiftool = try run(vendor.appendingPathComponent("exiftool/exiftool").path, ["-ver"], environment: [:])
        XCTAssertEqual(exiftool.status, 0, exiftool.output)
        XCTAssertTrue(exiftool.output.trimmingCharacters(in: .whitespacesAndNewlines).first?.isNumber ?? false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: vendor.appendingPathComponent("exiftool/lib").path), "ExifTool's lib/ ships with it")
        let cwebp = try run(vendor.appendingPathComponent("cwebp").path, ["-version"], environment: [:])
        XCTAssertEqual(cwebp.status, 0, cwebp.output)
    }
}
