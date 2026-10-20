import XCTest
@testable import Narengi

final class OutputAllocatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestSupport.makeTempDirectory()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func source(_ name: String = "photo.heic") -> URL { directory.appendingPathComponent(name) }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func testEnginesWriteToAHiddenStagingPathWithTheRightExtension() throws {
        let allocator = OutputAllocator(policy: OutputPolicy())
        let staging = try allocator.allocateFile(for: source(), pathExtension: "png")
        XCTAssertEqual(staging.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
        XCTAssertTrue(staging.lastPathComponent.hasPrefix(".narengi-tmp-"), staging.lastPathComponent)
        XCTAssertEqual(staging.pathExtension, "png", "tools like ffmpeg pick the container from the extension")
        XCTAssertFalse(exists(directory.appendingPathComponent("photo.png")), "nothing is visible until publish")
        allocator.cleanup()
    }

    func testPublishRenamesToThePlainNameAndRemovesStaging() throws {
        let allocator = OutputAllocator(policy: OutputPolicy())
        let staging = try allocator.allocateFile(for: source(), pathExtension: "png")
        try Data("pixels".utf8).write(to: staging)
        let map = try allocator.publish()

        let final = try XCTUnwrap(map[staging])
        XCTAssertEqual(final.lastPathComponent, "photo.png")
        XCTAssertEqual(try String(contentsOf: final), "pixels")
        XCTAssertFalse(exists(staging))
        XCTAssertEqual(TestSupport.directoryContents(directory), ["photo.png"])
    }

    func testCollisionsGetNumberedNamesWithoutOverwriting() throws {
        let existing = directory.appendingPathComponent("photo.png")
        try Data("original".utf8).write(to: existing)

        let allocator = OutputAllocator(policy: OutputPolicy())
        let staging = try allocator.allocateFile(for: source(), pathExtension: "png")
        try Data("new".utf8).write(to: staging)
        let final = try XCTUnwrap(allocator.publish()[staging])

        XCTAssertEqual(final.lastPathComponent, "photo 2.png")
        XCTAssertEqual(try String(contentsOf: existing), "original")
    }

    func testNamesReservedByRunningJobsAreNotHandedOutTwice() throws {
        let a = OutputAllocator(policy: OutputPolicy()), b = OutputAllocator(policy: OutputPolicy())
        let stagedA = try a.allocateFile(for: source(), pathExtension: "jpg")
        let stagedB = try b.allocateFile(for: source(), pathExtension: "jpg")
        try Data("a".utf8).write(to: stagedA)
        try Data("b".utf8).write(to: stagedB)
        let finalA = try XCTUnwrap(a.publish()[stagedA])
        let finalB = try XCTUnwrap(b.publish()[stagedB])
        XCTAssertEqual(finalA.lastPathComponent, "photo.jpg")
        XCTAssertEqual(finalB.lastPathComponent, "photo 2.jpg")
    }

    func testAFileThatAppearsBeforePublishIsNeverOverwritten() throws {
        let allocator = OutputAllocator(policy: OutputPolicy())
        let staging = try allocator.allocateFile(for: source(), pathExtension: "png")
        try Data("mine".utf8).write(to: staging)
        // Someone else creates the reserved name while the job is running.
        let intruder = directory.appendingPathComponent("photo.png")
        try Data("theirs".utf8).write(to: intruder)

        let final = try XCTUnwrap(allocator.publish()[staging])
        XCTAssertEqual(final.lastPathComponent, "photo 2.png")
        XCTAssertEqual(try String(contentsOf: intruder), "theirs")
        XCTAssertEqual(try String(contentsOf: final), "mine")
    }

    func testConcurrentJobsAlwaysEndUpWithDistinctFiles() throws {
        let policy = OutputPolicy()
        let src = source()
        let lock = NSLock()
        var finals = Set<String>()
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            let allocator = OutputAllocator(policy: policy)
            guard let staging = try? allocator.allocateFile(for: src, pathExtension: "png") else { return }
            try? Data("x".utf8).write(to: staging)
            if let final = try? allocator.publish()[staging] {
                lock.lock(); finals.insert(final.lastPathComponent); lock.unlock()
            }
        }
        XCTAssertEqual(finals.count, 40)
        XCTAssertEqual(TestSupport.directoryContents(directory).count, 40, "no staging files left behind")
    }

    func testCleanupRemovesStagingAndReleasesTheName() throws {
        let allocator = OutputAllocator(policy: OutputPolicy())
        let staging = try allocator.allocateFile(for: source(), pathExtension: "png")
        try Data("partial".utf8).write(to: staging)
        allocator.cleanup()
        XCTAssertTrue(TestSupport.directoryContents(directory).isEmpty)

        // The name is free again for the next job.
        let next = OutputAllocator(policy: OutputPolicy())
        let staged = try next.allocateFile(for: source(), pathExtension: "png")
        try Data("x".utf8).write(to: staged)
        XCTAssertEqual(try next.publish()[staged]?.lastPathComponent, "photo.png")
    }

    func testCustomFolderIsUsedAndCreated() throws {
        let custom = directory.appendingPathComponent("Converted/Nested")
        let policy = OutputPolicy(location: .customFolder, customFolder: custom)
        let allocator = OutputAllocator(policy: policy)
        let staging = try allocator.allocateFile(for: source(), pathExtension: "webp")
        try Data("x".utf8).write(to: staging)
        let final = try XCTUnwrap(allocator.publish()[staging])
        XCTAssertEqual(final.deletingLastPathComponent().standardizedFileURL.path, custom.standardizedFileURL.path)
        XCTAssertTrue(exists(final))
    }

    func testCustomLocationWithoutAFolderFallsBackBesideTheOriginal() throws {
        let policy = OutputPolicy(location: .customFolder, customFolder: nil)
        let staging = try OutputAllocator(policy: policy).allocateFile(for: source(), pathExtension: "png")
        XCTAssertEqual(staging.deletingLastPathComponent().standardizedFileURL.path, directory.standardizedFileURL.path)
    }

    func testFoldersStageThenGetTheFinalName() throws {
        let allocator = OutputAllocator(policy: OutputPolicy())
        let folder = try allocator.allocateFolder(for: source("report.pdf"))
        XCTAssertTrue(folder.lastPathComponent.hasPrefix(".narengi-tmp-"))
        let inside = try allocator.allocateFile(in: folder, baseName: "Page 1", pathExtension: "png")
        XCTAssertEqual(inside.lastPathComponent, "Page 1.png")
        try Data("x".utf8).write(to: inside)
        let second = try allocator.allocateFile(in: folder, baseName: "Page 1", pathExtension: "png")
        XCTAssertEqual(second.lastPathComponent, "Page 1 2.png", "names inside a folder never collide")

        let final = try XCTUnwrap(allocator.publish()[folder])
        XCTAssertEqual(final.lastPathComponent, "report")
        XCTAssertEqual(TestSupport.directoryContents(final), ["Page 1.png"])

        let again = OutputAllocator(policy: OutputPolicy())
        let folder2 = try again.allocateFolder(for: source("report.pdf"))
        XCTAssertEqual(try XCTUnwrap(again.publish()[folder2]).lastPathComponent, "report 2")
    }

    func testUnwritableDestinationThrows() {
        let policy = OutputPolicy(location: .customFolder, customFolder: URL(fileURLWithPath: "/System/narengi-nope"))
        XCTAssertThrowsError(try OutputAllocator(policy: policy).allocateFile(for: source(), pathExtension: "png")) {
            XCTAssertTrue($0 is ConversionError)
        }
    }
}
