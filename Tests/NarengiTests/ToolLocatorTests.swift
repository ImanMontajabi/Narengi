import XCTest
@testable import Narengi

final class ToolLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestSupport.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeExecutable(_ relativePath: String, executable: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    func testBundledVendorBinaryWinsOverFallback() throws {
        let vendored = try makeExecutable("Vendor/cwebp")
        try makeExecutable("brew/cwebp")
        let locator = BundledToolLocator(vendorDirectory: root.appendingPathComponent("Vendor"),
                                         fallbackDirectories: [root.appendingPathComponent("brew").path])
        XCTAssertEqual(locator.locate(.cwebp)?.standardizedFileURL, vendored.standardizedFileURL)
    }

    func testExifToolInsideItsOwnFolderIsFound() throws {
        let script = try makeExecutable("Vendor/exiftool/exiftool")
        let locator = BundledToolLocator(vendorDirectory: root.appendingPathComponent("Vendor"), fallbackDirectories: [])
        XCTAssertEqual(locator.locate(.exiftool)?.standardizedFileURL, script.standardizedFileURL)
    }

    func testFallsBackToHomebrewStyleDirectories() throws {
        let brew = try makeExecutable("brew/ffmpeg")
        let locator = BundledToolLocator(vendorDirectory: root.appendingPathComponent("Vendor"),
                                         fallbackDirectories: [root.appendingPathComponent("missing").path,
                                                               root.appendingPathComponent("brew").path])
        XCTAssertEqual(locator.locate(.ffmpeg)?.standardizedFileURL, brew.standardizedFileURL)
    }

    func testNonExecutableFilesAndDirectoriesAreIgnored() throws {
        try makeExecutable("Vendor/cwebp", executable: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Vendor/ffmpeg"), withIntermediateDirectories: true)
        let locator = BundledToolLocator(vendorDirectory: root.appendingPathComponent("Vendor"), fallbackDirectories: [])
        XCTAssertNil(locator.locate(.cwebp))
        XCTAssertNil(locator.locate(.ffmpeg))
    }

    func testRequireThrowsAUserFacingErrorWhenMissing() {
        let locator = BundledToolLocator(vendorDirectory: nil, fallbackDirectories: [])
        XCTAssertThrowsError(try locator.require(.exiftool)) {
            XCTAssertEqual($0 as? ConversionError, .toolMissing("exiftool"))
            XCTAssertTrue(($0 as? ConversionError)?.errorDescription?.contains("setup-vendor.sh") == true)
        }
    }

    // MARK: - ProcessRunner

    func testNonZeroExitSurfacesAsToolFailure() async {
        do {
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: [], tool: "false")
            XCTFail("expected failure")
        } catch {
            guard case .toolFailed(let tool, _) = error as? ConversionError else { return XCTFail("\(error)") }
            XCTAssertEqual(tool, "false")
        }
    }

    func testCancellingTheTaskKillsTheProcess() async {
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], tool: "sleep")
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
