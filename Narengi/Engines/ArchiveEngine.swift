import Foundation

/// Archives through macOS `bsdtar`, which reads ZIP, TAR, GZIP and RAR and writes ZIP, TAR and tar.gz.
/// Approach ported from Satsuma's `archive.rs` (MIT, © sonatina-dream).
struct ArchiveEngine {
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    /// Keeps AppleDouble `._` files and extended attributes out of archives we write.
    private static let environment = ["COPYFILE_DISABLE": "1"]

    static func isTarballName(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz")
    }

    // MARK: - Extract

    /// Extracts `source` into `directory` (created if needed). bsdtar refuses `..` and absolute paths
    /// unless told otherwise, so a hostile archive can't write outside `directory`.
    static func extract(_ source: URL, format: String, into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try await ProcessRunner.run(
                tar, arguments: ["-xf", source.path, "-C", directory.path], tool: "tar", environment: environment)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A plain .gz of one file is not a tarball: gunzip it.
            if format == "GZIP", !isTarballName(source) {
                try await gunzip(source, into: directory)
            } else {
                throw ConversionError.toolFailed(
                    tool: "tar", message: "Could not extract \(source.lastPathComponent). It may be damaged or encrypted.")
            }
        }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        if contents.isEmpty { throw ConversionError.toolFailed(tool: "tar", message: "The archive is empty.") }
    }

    private static func gunzip(_ source: URL, into directory: URL) async throws {
        let inner = NamingRules.stem(of: source.lastPathComponent)
        let target = directory.appendingPathComponent(inner.isEmpty ? "file" : inner)
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { finished in
                    if finished.terminationStatus == 0 {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: ConversionError.toolFailed(tool: "gunzip", message: "This GZIP file looks damaged."))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Pack

    /// Packs the contents of `directory` into `output`; the format decides ZIP, TAR or tar.gz.
    static func pack(_ directory: URL, to output: URL, format: String) async throws {
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
        guard !entries.isEmpty else { throw ConversionError.toolFailed(tool: "tar", message: "The archive is empty.") }

        let mode: [String]
        switch format {
        case "ZIP": mode = ["--format", "zip", "-cf"]
        case "TAR": mode = ["--format", "pax", "-cf"]
        case "GZIP": mode = ["--format", "pax", "-czf"]
        default: throw ConversionError.unsupported(from: "archive", to: format)
        }
        try await ProcessRunner.run(
            tar, arguments: mode + [output.path, "-C", directory.path, "--"] + entries,
            tool: "tar", environment: environment)
    }

    // MARK: - Conversion

    /// Re-packs an archive in another format by extracting it to a scratch folder first.
    static func convert(
        source: URL, options: ConversionOptions, allocator: OutputAllocator,
        progress: @Sendable (Double) -> Void
    ) async throws -> [URL] {
        guard ["ZIP", "TAR", "GZIP"].contains(options.targetFormat) else {
            throw ConversionError.unsupported(from: options.sourceFormat, to: options.targetFormat)
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("narengi-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }

        try await extract(source, format: options.sourceFormat, into: scratch)
        progress(0.5)
        try Task.checkCancellation()
        let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: options.targetFormat))
        try await pack(scratch, to: output, format: options.targetFormat)
        progress(1)
        return [output]
    }

    /// Extract Archive tool: a new folder beside the archive.
    static func extractToFolder(
        source: URL, format: String, allocator: OutputAllocator, progress: @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let folder = try allocator.allocateFolder(for: source, name: NamingRules.stem(of: source.lastPathComponent) + " Extracted")
        try await extract(source, format: format, into: folder)
        progress(1)
        return [folder]
    }
}
