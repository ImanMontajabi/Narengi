import Foundation

/// Where results go, snapshotted from Settings → Folders so it can cross threads.
struct OutputPolicy: Sendable, Equatable {
    var location: OutputLocation = .besideOriginal
    var customFolder: URL?

    /// Folder a result for `source` should be written to.
    func directory(for source: URL) -> URL {
        if location == .customFolder, let customFolder { return customFolder }
        return source.deletingLastPathComponent()
    }
}

/// Result of `publish()`: staging path → final path. Keyed by normalised path text, because a URL for a
/// folder compares differently before and after it is renamed (trailing slash).
struct PublishedOutputs {
    fileprivate var byPath: [String: URL] = [:]

    subscript(_ staged: URL) -> URL? { byPath[staged.standardizedFileURL.path] }
    var count: Int { byPath.count }
}

/// Hands out output paths in two steps so a failed or cancelled job leaves nothing behind and
/// nothing is ever overwritten:
///
/// 1. `allocate…` returns a hidden **staging** path (`<dir>/.narengi-tmp-<uuid>.<ext>`) for the engine
///    to write to, and reserves the final name (`photo.jpg`, then `photo 2.jpg`, …).
/// 2. `publish()` renames each staged item to its final name with an atomic, non-overwriting rename.
///    `cleanup()` deletes the staged items instead.
final class OutputAllocator: @unchecked Sendable {
    private struct Pending {
        let staging: URL
        let finalURL: URL
        let base: String
        let ext: String?
    }

    /// Final names reserved by jobs that are still running, so concurrent jobs never pick the same one.
    private static let registryLock = NSLock()
    private static var registry = Set<String>()

    private let policy: OutputPolicy
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var pending: [Pending] = []

    init(policy: OutputPolicy) {
        self.policy = policy
    }

    // MARK: - Allocation

    /// Staging path for `<base>.<ext>` next to (or in the chosen folder for) `source`.
    func allocateFile(for source: URL, baseName: String? = nil, pathExtension ext: String) throws -> URL {
        let directory = policy.directory(for: source)
        try ensureDirectory(directory)
        let base = baseName ?? NamingRules.stem(of: source.lastPathComponent)
        return track(in: directory, base: base, ext: ext)
    }

    /// Staging folder for outputs that produce many files; files go inside it with `allocateFile(in:…)`.
    func allocateFolder(for source: URL, name: String? = nil) throws -> URL {
        let directory = policy.directory(for: source)
        try ensureDirectory(directory)
        let base = name ?? NamingRules.stem(of: source.lastPathComponent)
        let staging = track(in: directory, base: base, ext: nil)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw ConversionError.outputUnwritable(directory.path)
        }
        return staging
    }

    /// A plain, unique file path inside a staging folder (the folder itself is the staging area).
    func allocateFile(in directory: URL, baseName: String, pathExtension ext: String) throws -> URL {
        let name = NamingRules.firstFree(base: baseName, ext: ext) {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return directory.appendingPathComponent(name)
    }

    /// Staging paths handed out so far.
    var stagedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return pending.map(\.staging)
    }

    // MARK: - Finishing

    /// Renames every staged item to its final name and returns `staged → final`.
    /// A name that appeared in the meantime moves on to the next free number; nothing is overwritten.
    @discardableResult
    func publish() throws -> PublishedOutputs {
        lock.lock()
        let items = pending
        pending = []
        lock.unlock()

        var map = PublishedOutputs()
        var failure: Error?
        for item in items {
            guard failure == nil else { remove(item.staging); continue }
            do {
                map.byPath[item.staging.standardizedFileURL.path] = try rename(item)
            } catch {
                failure = error
                remove(item.staging)
            }
            release(item.finalURL)
        }
        if let failure { throw failure }
        return map
    }

    /// Deletes staged files and releases the reserved names.
    func cleanup() {
        lock.lock()
        let items = pending
        pending = []
        lock.unlock()
        for item in items.reversed() {
            remove(item.staging)
            release(item.finalURL)
        }
    }

    // MARK: - Internals

    private func track(in directory: URL, base: String, ext: String?) -> URL {
        let name = NamingRules.firstFree(base: base, ext: ext) { candidate in
            let path = directory.appendingPathComponent(candidate)
            return fileManager.fileExists(atPath: path.path) || Self.isReserved(path)
        }
        let finalURL = directory.appendingPathComponent(name)
        Self.reserve(finalURL)

        let stagingName = ".narengi-tmp-\(UUID().uuidString)" + (ext.map { ".\($0)" } ?? "")
        let staging = directory.appendingPathComponent(stagingName)

        lock.lock()
        pending.append(Pending(staging: staging, finalURL: finalURL, base: base, ext: ext))
        lock.unlock()
        return staging
    }

    /// `renamex_np(…, RENAME_EXCL)` fails instead of replacing, which makes the claim atomic.
    private func rename(_ item: Pending) throws -> URL {
        let directory = item.finalURL.deletingLastPathComponent()
        var target = item.finalURL
        for attempt in 0..<10_000 {
            if attempt > 0 {
                let name = NamingRules.firstFree(base: item.base, ext: item.ext) { candidate in
                    fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
                }
                target = directory.appendingPathComponent(name)
            }
            if renamex_np(item.staging.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST { throw ConversionError.outputUnwritable(directory.path) }
        }
        throw ConversionError.outputUnwritable(directory.path)
    }

    private func remove(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private func ensureDirectory(_ directory: URL) throws {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ConversionError.outputUnwritable(directory.path)
        }
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    private static func reserve(_ url: URL) {
        registryLock.lock(); registry.insert(key(url)); registryLock.unlock()
    }

    private func release(_ url: URL) {
        Self.registryLock.lock(); Self.registry.remove(Self.key(url)); Self.registryLock.unlock()
    }

    private static func isReserved(_ url: URL) -> Bool {
        registryLock.lock(); defer { registryLock.unlock() }
        return registry.contains(key(url))
    }
}
