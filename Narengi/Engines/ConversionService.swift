import Foundation

/// What this Mac can actually do, so the wheels only show petals that work (SPEC §"capability").
struct Availability: Sendable {
    var media: MediaEnvironment
    var tools: BundledToolLocator

    static let shared = Availability(media: .shared, tools: .shared)

    /// Pure-system backends only (no ffmpeg), for tests and diagnostics.
    static func withoutFFmpeg(tools: BundledToolLocator = .shared) -> Availability {
        Availability(media: .none, tools: tools)
    }

    private static let sheetFormats: Set<String> = ["XLSX", "ODS", "CSV", "TSV"]

    /// Whether `source → target` is both in the matrix and implemented here.
    func conversion(from source: String, to target: String) -> Bool {
        FormatCatalog.canConvert(source, to: target) && engineSupports(source: source, target: target)
    }

    func engineSupports(source: String, target: String) -> Bool {
        switch FormatCatalog.category(of: source)?.id {
        case "images":
            switch target {
            case "PDF", "DOCX", "TXT", "MD": return true
            case "WEBP": return ImageEngine.canEncode("WEBP") || tools.locate(.cwebp) != nil
            default: return ImageEngine.canEncode(target)
            }
        case "audio", "video":
            return MediaEngine(env: media).supports(source: source, target: target)
        case "documents":
            if source == "PDF" { return PDFEngine.outputFormats.contains(target) || DocumentEngine.supports(source: source, target: target) }
            return DocumentEngine.supports(source: source, target: target)
        case "spreadsheets":
            return Self.sheetFormats.contains(source) && (Self.sheetFormats.contains(target) || target == "PDF")
        case "subtitles", "archives":
            return true
        default:
            return false
        }
    }

    /// Whether a tool works on a file of this format.
    func tool(_ tool: ToolID, input: String) -> Bool {
        ToolService.supports(tool, input: input, availability: self)
    }

    /// Whether a petal works for every file in the selection (`nil` = folder or unknown file).
    func item(_ item: WheelItem, formats: [String?]) -> Bool {
        switch item.action {
        case .action:
            return true
        case .convert(let target):
            return formats.allSatisfy { format in format.map { $0 == target || conversion(from: $0, to: target) } ?? false }
        case .tool(let tool):
            return formats.allSatisfy { format in format.map { self.tool(tool, input: $0) } ?? false }
        }
    }
}

/// Routes a request to the right engine and owns staging, publishing and cleanup.
enum ConversionService {
    /// A job body that runs a conversion, then publishes the staged result atomically.
    static func work(
        source: URL,
        options: ConversionOptions,
        policy: OutputPolicy,
        availability: Availability = .shared
    ) -> Job.Work {
        stagedWork(policy: policy) { allocator, progress in
            try await perform(source: source, options: options, allocator: allocator, availability: availability, progress: progress)
        }
    }

    /// A job body for any staged operation: `body` writes to staging paths, then everything is published.
    static func stagedWork(
        policy: OutputPolicy,
        _ body: @escaping @Sendable (OutputAllocator, @escaping @Sendable (Double) -> Void) async throws -> [URL]
    ) -> Job.Work {
        { context in
            let allocator = OutputAllocator(policy: policy)
            do {
                let staged = try await body(allocator, context.reportProgress)
                try Task.checkCancellation()
                let published = try allocator.publish()
                return staged.map { published[$0] ?? $0 }
            } catch {
                allocator.cleanup()
                throw error
            }
        }
    }

    /// Runs one conversion and returns the published outputs (used by tests and the CLI-style callers).
    static func run(
        source: URL,
        options: ConversionOptions,
        policy: OutputPolicy = OutputPolicy(),
        availability: Availability = .shared,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [URL] {
        try await work(source: source, options: options, policy: policy, availability: availability)(JobContext(reportProgress: progress))
    }

    /// Dispatches to an engine. Returns staging paths; the caller publishes or cleans up.
    static func perform(
        source: URL,
        options: ConversionOptions,
        allocator: OutputAllocator,
        availability: Availability = .shared,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let from = options.sourceFormat, to = options.targetFormat
        switch FormatCatalog.category(of: from)?.id {
        case "images":
            return try await ImageEngine(tools: availability.tools).convert(source: source, options: options, allocator: allocator, progress: progress)
        case "audio", "video":
            return try await MediaEngine(env: availability.media).convert(source: source, options: options, allocator: allocator, progress: progress)
        case "documents":
            if from == "PDF", PDFEngine.outputFormats.contains(to) {
                return try await PDFEngine().convert(source: source, options: options, allocator: allocator, progress: progress)
            }
            return try await DocumentEngine().convert(source: source, options: options, allocator: allocator, progress: progress)
        case "spreadsheets":
            guard availability.engineSupports(source: from, target: to) else { throw ConversionError.unsupported(from: from, to: to) }
            return try await SheetEngine.convert(source: source, options: options, allocator: allocator, progress: progress)
        case "subtitles":
            return try SubtitleEngine.convert(source: source, options: options, allocator: allocator)
        case "archives":
            return try await ArchiveEngine.convert(source: source, options: options, allocator: allocator, progress: progress)
        default:
            throw ConversionError.unsupported(from: from, to: to)
        }
    }

    // MARK: - Tools

    static func extractArchiveWork(source: URL, format: String, policy: OutputPolicy) -> Job.Work {
        stagedWork(policy: policy) { allocator, progress in
            try await ArchiveEngine.extractToFolder(source: source, format: format, allocator: allocator, progress: progress)
        }
    }

    /// A job body for wheel choices that exist in the UI but have no engine yet.
    static func notImplemented(_ name: String) -> Job.Work {
        { _ in throw ConversionError.notImplemented(name) }
    }

    // MARK: - Wheel helpers

    static func supports(source: String, target: String, availability: Availability = .shared) -> Bool {
        availability.conversion(from: source, to: target)
    }

    /// Outputs the wheel can offer for a selection: the matrix targets that have a working engine.
    static func supportedOutputs(for urls: [URL], availability: Availability = .shared) -> [String] {
        let formats = urls.map(FormatCatalog.detect)
        let known = formats.compactMap { $0 }
        guard known.count == formats.count else { return [] }
        return FormatCatalog.targets(forSelection: known).filter { target in
            known.allSatisfy { $0 == target || availability.conversion(from: $0, to: target) }
        }
    }
}
