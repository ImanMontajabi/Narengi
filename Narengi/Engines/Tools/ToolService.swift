import CoreGraphics
import Foundation

/// A tool plus the choices made for it (from Settings, or from its window).
enum ToolOperation: Sendable {
    /// Runs with defaults and Settings: the quick path for batches and non-interactive tools.
    case plain(ToolID, ToolOptions = ToolOptions())
    case compress(CompressionSpec)
    case organize([PDFPageEdit], sameWidth: Bool)
    /// Metadata window "Save": per-tag edits (nil removes the tag).
    case metadata([String: String?])
    /// Editor results. Crop and Add Background apply to every selected image; the rest to one file.
    case crop(CropSpec)
    case frame(FrameSpec)
    case adjust(Adjustments)
    /// Annotate or redact (`tool` says which, for naming and output format); marks are per PDF page (images use page 0).
    case markup(ToolID, [Int: [MarkupItem]])
    /// Video and audio editors.
    case trimVideo(start: Double, end: Double)
    case cropVideo(CropSpec)
    case redactVideo([VideoRedaction], start: Double?, end: Double?)
    case bleep([BleepInterval])

    var tool: ToolID {
        switch self {
        case .crop: return .cropImage
        case .frame: return .frameImage
        case .adjust: return .editImage
        case .markup(let tool, _): return tool
        case .trimVideo: return .trimVideo
        case .cropVideo: return .cropVideo
        case .redactVideo: return .redactVideo
        case .bleep: return .redactAudio
        case .plain(let tool, _): return tool
        case .compress: return .compress
        case .organize: return .organizePDF
        case .metadata: return .removeMetadata
        }
    }
}

struct ToolOptions: Sendable, Equatable {
    var splitParts = 2
    var speed = 2.0
    var compression = CompressionSpec()
}

/// Routes tools to their engines and owns naming, staging and publishing for them.
enum ToolService {
    // MARK: - Capability

    /// Whether `tool` works on a file of `input` format on this Mac (so the wheel can hide what doesn't).
    static func supports(_ tool: ToolID, input: String, availability: Availability) -> Bool {
        let category = FormatCatalog.category(of: input)?.id
        let ffmpeg = availability.media.hasFFmpeg
        let media = MediaEngine(env: availability.media)
        let h264 = (try? media.h264Arguments(crf: 20)) != nil
        switch tool {
        case .extractArchive: return ["ZIP", "TAR", "GZIP", "RAR"].contains(input)
        case .compress:
            switch category {
            case "images": return ["JPG", "PNG", "WEBP", "HEIC", "TIFF"].contains(input) && (input != "HEIC" || ImageEngine.canEncode("HEIC"))
            case "audio": return ffmpeg
            case "video": return ffmpeg && h264
            default: return input == "PDF"
            }
        case .removeMetadata:
            switch category {
            case "images": return MetadataEngine.strippableImages.contains(input) || availability.tools.locate(.exiftool) != nil
            case "audio", "video": return ffmpeg
            default: return input == "PDF"
            }
        case .readQR: return category == "images" || input == "PDF"
        case .normalizeAudio, .trimAudio, .audioChannels: return ffmpeg && category == "audio"
        case .audioToVideo: return ffmpeg && category == "audio" && h264
        case .muteVideo, .changeVideoSpeed, .videoSnapshots: return ffmpeg && category == "video" && (tool == .muteVideo || tool == .videoSnapshots || h264)
        case .splitVideo, .joinVideos: return ffmpeg && category == "video" && h264
        case .splitPDF, .mergePDF, .organizePDF, .annotatePDF, .redactPDF: return input == "PDF"
        case .createPDF, .createCollage: return category == "images"
        case .editImage, .annotateImage, .frameImage, .cropImage, .redactImage: return category == "images" && input != "SVG"
        case .trimVideo, .cropVideo, .redactVideo: return ffmpeg && category == "video" && h264
        case .redactAudio:
            guard ffmpeg, category == "audio" || category == "video" else { return false }
            return (try? media.audioCodecArguments(for: category == "video" ? (input == "MKV" ? "MKV" : "MP4") : input, kbps: 192)) != nil
        }
    }

    // MARK: - Jobs

    static func work(
        _ operation: ToolOperation, sources: [URL], formats: [String], policy: OutputPolicy,
        availability: Availability = .shared
    ) -> Job.Work {
        ConversionService.stagedWork(policy: policy) { allocator, progress in
            try await perform(operation, sources: sources, formats: formats, allocator: allocator, availability: availability, progress: progress)
        }
    }

    /// Runs one tool and returns staging paths; the caller publishes or cleans up.
    static func perform(
        _ operation: ToolOperation, sources: [URL], formats: [String], allocator: OutputAllocator,
        availability: Availability = .shared, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        guard let first = sources.first, let format = formats.first else { return [] }
        let tool = operation.tool
        let stem = NamingRules.stem(of: first.lastPathComponent)

        func output(_ label: String? = nil, ext: String) throws -> URL {
            try allocator.allocateFile(for: first, baseName: "\(stem) \(label ?? tool.info.label)", pathExtension: ext)
        }
        func sameFormat() throws -> URL { try output(ext: NamingRules.fileExtension(for: format)) }

        switch operation {
        case .compress(let spec):
            return try await CompressEngine(availability: availability).compress(
                source: first, format: format, spec: spec, allocator: allocator, progress: progress)

        case .organize(let edits, let sameWidth):
            let url = try output(ext: "pdf")
            try PDFTools.organize(source: first, output: url, edits: edits, sameWidth: sameWidth)
            return [url]

        case .metadata(let changes):
            let url = try sameFormat()
            try await MetadataEngine(tools: availability.tools, media: availability.media)
                .save(source: first, output: url, format: format, changes: changes)
            return [url]

        case .crop(let spec):
            var outputs: [URL] = []
            for (n, (source, format)) in zip(sources, formats).enumerated() {
                try Task.checkCancellation()
                let decoded = try ImageEngine.decode(source, dpi: 150, flattenOnWhite: false)
                let size = CGSize(width: decoded.image.width, height: decoded.image.height)
                let rect = spec.pixels(in: size)
                let cropped = try ImageOps.crop(
                    decoded.image, to: rect, output: spec.output.map { (Int($0.width), Int($0.height)) })
                let url = try allocator.allocateFile(
                    for: source, baseName: "\(NamingRules.stem(of: source.lastPathComponent)) \(tool.info.label)",
                    pathExtension: NamingRules.fileExtension(for: format))
                try await ImageSaver.save(cropped, format: format, to: url, preserving: decoded.metadata, dpi: decoded.dpi, availability: availability)
                outputs.append(url)
                progress(Double(n + 1) / Double(sources.count))
            }
            return outputs

        case .frame(let spec):
            let decoded = try ImageEngine.decode(first, dpi: 150, flattenOnWhite: false)
            var background: CGImage?
            if case .image(let url) = spec.background { background = try ImageEngine.decode(url, dpi: 150, flattenOnWhite: true).image }
            let framed = try FrameRenderer.render(decoded.image, spec: spec, backgroundImage: background)
            let url = try output(ext: "png")
            try await ImageSaver.save(framed, format: "PNG", to: url, availability: availability)
            progress(1)
            return [url]

        case .adjust(let adjustments):
            let decoded = try ImageEngine.decode(first, dpi: 150, flattenOnWhite: false)
            let edited = try PhotoAdjuster.apply(adjustments, to: decoded.image)
            let url = try sameFormat()
            try await ImageSaver.save(edited, format: format, to: url, preserving: decoded.metadata, dpi: decoded.dpi, availability: availability)
            progress(1)
            return [url]

        case .markup(let markupTool, let itemsByPage):
            if format == "PDF" {
                let url = try output(ext: "pdf")
                try MarkupRenderer.renderPDF(source: first, output: url, itemsByPage: itemsByPage)
                progress(1)
                return [url]
            }
            let decoded = try ImageEngine.decode(first, dpi: 150, flattenOnWhite: false)
            let marked = try MarkupRenderer.render(decoded.image, items: itemsByPage[0] ?? [])
            // Annotated photos are saved as PNG; a redacted photo keeps its format but drops all metadata.
            let targetFormat = markupTool == .annotateImage ? "PNG" : format
            let url = try output(ext: NamingRules.fileExtension(for: targetFormat))
            try await ImageSaver.save(marked, format: targetFormat, to: url, preserving: [:], dpi: decoded.dpi, availability: availability)
            progress(1)
            return [url]

        case .trimVideo(let start, let end):
            let url = try sameFormat()
            try await MediaEngine(env: availability.media).trim(source: first, output: url, format: format, start: start, end: end, progress: progress)
            return [url]

        case .cropVideo(let spec):
            let url = try sameFormat()
            try await MediaEngine(env: availability.media).crop(source: first, output: url, format: format, spec: spec, progress: progress)
            return [url]

        case .redactVideo(let regions, let start, let end):
            let url = try sameFormat()
            try await MediaEngine(env: availability.media).redact(
                source: first, output: url, format: format, regions: regions, start: start, end: end, progress: progress)
            return [url]

        case .bleep(let intervals):
            let url = try sameFormat()
            try await MediaEngine(env: availability.media).bleep(source: first, output: url, format: format, intervals: intervals, progress: progress)
            return [url]

        case .plain(_, let options):
            return try await performPlain(
                tool, options: options, sources: sources, formats: formats, allocator: allocator,
                availability: availability, progress: progress)
        }
    }

    private static func performPlain(
        _ tool: ToolID, options: ToolOptions, sources: [URL], formats: [String], allocator: OutputAllocator,
        availability: Availability, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let first = sources[0], format = formats[0]
        let stem = NamingRules.stem(of: first.lastPathComponent)
        let media = MediaEngine(env: availability.media)
        func output(_ label: String? = nil, ext: String) throws -> URL {
            try allocator.allocateFile(for: first, baseName: "\(stem) \(label ?? tool.info.label)", pathExtension: ext)
        }
        func sameFormat(_ label: String? = nil) throws -> URL { try output(label, ext: NamingRules.fileExtension(for: format)) }
        if media.env.hasFFmpeg == false, FormatCatalog.category(of: format)?.id == "audio" || FormatCatalog.category(of: format)?.id == "video" {
            throw ConversionError.toolMissing("ffmpeg")
        }

        switch tool {
        case .compress:
            return try await CompressEngine(availability: availability).compress(
                source: first, format: format, spec: options.compression, allocator: allocator, progress: progress)

        case .removeMetadata:
            let url = try sameFormat()
            try await MetadataEngine(tools: availability.tools, media: availability.media)
                .strip(source: first, output: url, format: format, progress: progress)
            return [url]

        case .normalizeAudio:
            let url = try sameFormat()
            try await media.normalize(source: first, output: url, format: format, progress: progress)
            return [url]

        case .trimAudio:
            let url = try sameFormat()
            try await media.trimSilence(source: first, output: url, format: format, progress: progress)
            return [url]

        case .audioChannels:
            let channels = await media.targetChannels(for: first)
            let url = try sameFormat(channels == 1 ? "Mono" : "Stereo")
            try await media.changeChannels(source: first, output: url, format: format, channels: channels, progress: progress)
            return [url]

        case .audioToVideo:
            let url = try output(ext: "mp4")
            try await media.visualize(source: first, output: url, progress: progress)
            return [url]

        case .muteVideo:
            let url = try sameFormat()
            try await media.mute(source: first, output: url, format: format, progress: progress)
            return [url]

        case .changeVideoSpeed:
            let url = try sameFormat()
            try await media.changeSpeed(source: first, output: url, format: format, factor: options.speed, progress: progress)
            return [url]

        case .videoSnapshots:
            let url = try output(ext: "png")
            try await media.snapshot(source: first, output: url, progress: progress)
            return [url]

        case .splitVideo:
            let folder = try allocator.allocateFolder(for: first, name: "\(stem) Clips")
            try await media.splitEqual(
                source: first, directory: folder, stem: stem, format: format, parts: options.splitParts,
                allocator: allocator, progress: progress)
            return [folder]

        case .joinVideos:
            let url = try allocator.allocateFile(for: first, baseName: "Joined", pathExtension: "mp4")
            try await media.join(sources: sources, output: url, progress: progress)
            return [url]

        case .splitPDF:
            let folder = try allocator.allocateFolder(for: first, name: "\(stem) Pages")
            try PDFTools.split(source: first, directory: folder, stem: stem, progress: progress)
            return [folder]

        case .mergePDF:
            guard sources.count >= 2 else { throw ConversionError.custom("Select at least two PDFs to merge.") }
            let url = try allocator.allocateFile(for: first, baseName: "Merged", pathExtension: "pdf")
            try PDFTools.merge(sources: sources, output: url, progress: progress)
            return [url]

        case .createPDF:
            let url = try output("Images", ext: "pdf")
            try PDFTools.createPDF(from: sources, output: url, progress: progress)
            return [url]

        case .createCollage:
            guard sources.count >= 2 else { throw ConversionError.custom("Select at least two images.") }
            var images: [CGImage] = []
            for (n, source) in sources.enumerated() {
                try Task.checkCancellation()
                images.append(try ImageEngine.decode(source, dpi: 150, flattenOnWhite: true).image)
                progress(Double(n + 1) / Double(sources.count + 1))
            }
            let url = try allocator.allocateFile(for: first, baseName: "Collage", pathExtension: "png")
            let collage = try CollageEngine.make(images: images)
            try ImageEngine.encode(
                ImageEngine.DecodedImage(image: collage, dpi: 72, metadata: [:]), format: "PNG",
                options: ConversionOptions(sourceFormat: "PNG", targetFormat: "PNG", preserveMetadata: false), to: url)
            return [url]

        case .extractArchive:
            return try await ArchiveEngine.extractToFolder(source: first, format: format, allocator: allocator, progress: progress)

        default:
            throw ConversionError.notImplemented(tool.info.name)
        }
    }
}
