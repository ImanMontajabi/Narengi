import XCTest
@testable import Narengi

final class ZipAndArchiveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    // MARK: ZipWriter

    func testCRC32MatchesTheKnownCheckValue() {
        XCTAssertEqual(ZipWriter.crc32(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(ZipWriter.crc32(Data()), 0)
    }

    func testEntriesRoundTripThroughBsdtarAndUnzip() throws {
        var zip = ZipWriter()
        let big = Data(String(repeating: "Narengi compresses repetitive text well. ", count: 500).utf8)
        try zip.add("a.txt", text: "hello")
        try zip.add("dir/big.txt", data: big)
        try zip.add("stored.bin", data: big, compress: false)
        try zip.add("empty.txt", data: Data())
        try zip.add("ünïcode ✓.txt", text: "unicode name")
        let url = directory.appendingPathComponent("test.zip")
        try zip.write(to: url)

        try TestSupport.run("/usr/bin/unzip", ["-tq", url.path])  // integrity check (CRCs and sizes)
        let out = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try TestSupport.run("/usr/bin/tar", ["-xf", url.path, "-C", out.path])
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("a.txt")), "hello")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("dir/big.txt")), big)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("stored.bin")), big)
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("empty.txt")), Data())
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("ünïcode ✓.txt")), "unicode name")

        var onlyCompressible = ZipWriter()
        try onlyCompressible.add("big.txt", data: big)
        XCTAssertLessThan(onlyCompressible.finalized().count, big.count / 4, "the compressible entry must actually be deflated")
        var onlyStored = ZipWriter()
        try onlyStored.add("big.bin", data: big, compress: false)
        XCTAssertGreaterThan(onlyStored.finalized().count, big.count, "compress: false must store the bytes as they are")
    }

    // MARK: Archive conversion

    private func makeSourceTree() throws -> URL {
        let tree = directory.appendingPathComponent("tree")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "one".write(to: tree.appendingPathComponent("one.txt"), atomically: true, encoding: .utf8)
        try "two".write(to: tree.appendingPathComponent("sub/two.txt"), atomically: true, encoding: .utf8)
        return tree
    }

    private func convert(_ source: URL, from: String, to: String) async throws -> URL {
        let options = ConversionOptions(sourceFormat: from, targetFormat: to)
        return try await ConversionService.run(source: source, options: options)[0]
    }

    func testZipTarGzipRoundTripKeepsEveryFile() async throws {
        let tree = try makeSourceTree()
        let zip = directory.appendingPathComponent("project.zip")
        try TestSupport.run("/usr/bin/tar", ["--format", "zip", "-cf", zip.path, "-C", tree.path, "one.txt", "sub"])

        let tar = try await convert(zip, from: "ZIP", to: "TAR")
        XCTAssertEqual(tar.lastPathComponent, "project.tar")
        let gz = try await convert(tar, from: "TAR", to: "GZIP")
        XCTAssertEqual(gz.lastPathComponent, "project.tar.gz")
        let back = try await convert(gz, from: "GZIP", to: "ZIP")
        XCTAssertEqual(back.lastPathComponent, "project 2.zip", "the original project.zip is not overwritten")

        for archive in [tar, gz, back] {
            let names = try TestSupport.archiveListing(archive)
            XCTAssertTrue(names.contains("one.txt"), "\(archive.lastPathComponent): \(names)")
            XCTAssertTrue(names.contains { $0.hasSuffix("two.txt") }, "\(archive.lastPathComponent): \(names)")
            XCTAssertFalse(names.contains { $0.contains("._") }, "no AppleDouble files")
        }
    }

    func testGZIPOfASingleFileIsGunzipped() async throws {
        let file = directory.appendingPathComponent("notes.txt")
        try "plain text".write(to: file, atomically: true, encoding: .utf8)
        try TestSupport.run("/usr/bin/gzip", ["-k", file.path])
        let gz = directory.appendingPathComponent("notes.txt.gz")

        let policy = OutputPolicy()
        let outputs = try await ConversionService.stagedWork(policy: policy) { allocator, progress in
            try await ArchiveEngine.extractToFolder(source: gz, format: "GZIP", allocator: allocator, progress: progress)
        }(JobContext(reportProgress: { _ in }))
        let folder = try XCTUnwrap(outputs.first)
        XCTAssertEqual(folder.lastPathComponent, "notes.txt Extracted")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.txt")), "plain text")
    }

    func testExtractToFolderUsesTheExtractedSuffix() async throws {
        let tree = try makeSourceTree()
        let tgz = directory.appendingPathComponent("little-project.tgz")
        try TestSupport.run("/usr/bin/tar", ["-czf", tgz.path, "-C", tree.path, "."])
        let work = ConversionService.extractArchiveWork(source: tgz, format: "GZIP", policy: OutputPolicy())
        let folder = try await work(JobContext(reportProgress: { _ in }))[0]
        XCTAssertEqual(folder.lastPathComponent, "little-project Extracted")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("one.txt")), "one")
    }

    func testArchivesCannotWriteOutsideTheExtractionFolder() async throws {
        var zip = ZipWriter()
        try zip.add("../escaped.txt", text: "evil")
        try zip.add("safe.txt", text: "ok")
        let url = directory.appendingPathComponent("hostile.zip")
        try zip.write(to: url)

        let work = ConversionService.extractArchiveWork(source: url, format: "ZIP", policy: OutputPolicy())
        _ = try? await work(JobContext(reportProgress: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escaped.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escaped.txt").path))
    }

    func testDamagedArchiveFailsWithAReadableMessageAndLeavesNothing() async throws {
        let url = directory.appendingPathComponent("broken.zip")
        try Data("not really a zip".utf8).write(to: url)
        let options = ConversionOptions(sourceFormat: "ZIP", targetFormat: "TAR")
        do {
            _ = try await ConversionService.run(source: url, options: options)
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("Could not extract") == true, "\(error)")
        }
        XCTAssertEqual(TestSupport.directoryContents(directory), ["broken.zip"])
    }
}
