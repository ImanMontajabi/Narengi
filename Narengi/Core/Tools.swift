import Foundation

/// What a tool writes next to its source.
enum ToolOutput: Equatable {
    /// Same format as the input (WAV compresses to FLAC).
    case sameFormat
    case fixed(String)
    case folder
    /// Produces no file (Read QR shows its results in a window).
    case none
}

struct ToolInfo {
    let id: String
    /// Upper-case title on the petal.
    let title: String
    /// Human name for menus and progress.
    let name: String
    /// SF Symbol name.
    let symbol: String
    /// Word appended to output names (`photo Compressed.jpg`).
    let label: String
    let output: ToolOutput
    /// Progress title while running.
    let verb: String
}

/// The 26 file tools of the Tools wheel. Ported from Satsuma's `tools.rs` (MIT, © sonatina-dream);
/// titles, symbols and labels originate from the original app's website data.
enum ToolID: String, CaseIterable {
    case compress, removeMetadata, editImage, annotateImage, frameImage, cropImage, redactImage
    case normalizeAudio, audioToVideo, trimAudio, audioChannels, redactAudio
    case muteVideo, trimVideo, cropVideo, changeVideoSpeed, videoSnapshots, splitVideo, redactVideo, joinVideos
    case splitPDF, organizePDF, mergePDF, createPDF, createCollage, extractArchive
    /// Narengi additions to Satsuma's list: QR/barcode reading (as in the original app) and PDF markup.
    case readQR, annotatePDF, redactPDF

    var info: ToolInfo {
        func make(_ title: String, _ name: String, _ symbol: String, _ label: String, _ output: ToolOutput, _ verb: String) -> ToolInfo {
            ToolInfo(id: rawValue, title: title, name: name, symbol: symbol, label: label, output: output, verb: verb)
        }
        switch self {
        case .compress: return make("COMPRESS", "Compress", "arrow.down.right.and.arrow.up.left", "Compressed", .sameFormat, "Compressing")
        case .removeMetadata: return make("METADATA", "Remove Metadata", "tag", "No Metadata", .sameFormat, "Removing metadata")
        case .editImage: return make("EDIT", "Edit Photo", "slider.horizontal.3", "Edited", .sameFormat, "Editing photo")
        case .annotateImage: return make("ANNOTATE", "Annotate Photo", "pencil.and.outline", "Annotated", .fixed("PNG"), "Annotating photo")
        case .frameImage: return make("ADD BG", "Add Background", "photo.artframe", "With Background", .fixed("PNG"), "Adding background")
        case .cropImage: return make("CROP", "Crop Image", "crop", "Cropped", .sameFormat, "Cropping")
        case .redactImage: return make("REDACT", "Redact Photo", "eye.slash", "Redacted", .sameFormat, "Redacting")
        case .normalizeAudio: return make("NORMALIZE", "Normalize Volume", "waveform", "Normalized", .sameFormat, "Normalizing volume")
        case .audioToVideo: return make("VISUALIZE", "Audio Visualizer", "waveform", "Visualizer", .fixed("MP4"), "Creating visualization")
        case .trimAudio: return make("TRIM", "Trim Silence", "scissors", "Trimmed", .sameFormat, "Trimming")
        case .audioChannels: return make("CHANNELS", "Convert Audio Channels", "hifispeaker.2", "Mono", .sameFormat, "Converting channels")
        case .redactAudio: return make("BLEEP", "Bleep Audio", "waveform.badge.minus", "Bleeped", .sameFormat, "Bleeping")
        case .muteVideo: return make("MUTE", "Remove Audio", "speaker.slash.fill", "Muted", .sameFormat, "Removing audio")
        case .trimVideo: return make("TRIM", "Trim Video", "scissors", "Trimmed", .sameFormat, "Trimming")
        case .cropVideo: return make("CROP", "Crop Video", "crop", "Cropped", .sameFormat, "Cropping")
        case .changeVideoSpeed: return make("SPEED", "Change Video Speed", "speedometer", "Speed 2x", .sameFormat, "Changing speed")
        case .videoSnapshots: return make("SNAPSHOT", "Video Snapshot", "camera", "Snapshot", .fixed("PNG"), "Saving snapshots")
        case .splitVideo: return make("SPLIT", "Split Video", "film", "Clips", .folder, "Splitting video")
        case .redactVideo: return make("REDACT", "Redact Video", "eye.slash", "Redacted", .sameFormat, "Redacting")
        case .joinVideos: return make("JOIN", "Join Videos", "film.stack", "Joined", .fixed("MP4"), "Joining videos")
        case .splitPDF: return make("SPLIT", "Split PDF", "rectangle.split.2x1", "Pages", .folder, "Splitting PDF")
        case .organizePDF: return make("ORGANIZE", "Organize PDF", "square.grid.2x2", "Organized", .fixed("PDF"), "Organizing PDF")
        case .mergePDF: return make("MERGE PDF", "Merge PDFs", "doc.on.doc", "Merged", .fixed("PDF"), "Merging PDFs")
        case .createPDF: return make("CREATE PDF", "Create PDF", "doc.badge.plus", "Images", .fixed("PDF"), "Creating PDF")
        case .createCollage: return make("COLLAGE", "Create Collage", "rectangle.3.group", "Collage", .fixed("PNG"), "Creating collage")
        case .extractArchive: return make("EXTRACT", "Extract Archive", "archivebox", "Extracted", .folder, "Extracting archive")
        case .readQR: return make("READ QR", "Read QR Code", "qrcode.viewfinder", "QR", .none, "Reading QR codes")
        case .annotatePDF: return make("ANNOTATE", "Annotate PDF", "pencil.and.outline", "Annotated", .fixed("PDF"), "Annotating PDF")
        case .redactPDF: return make("REDACT", "Redact PDF", "eye.slash", "Redacted", .fixed("PDF"), "Redacting PDF")
        }
    }

    var title: String { info.title }
    var symbol: String { info.symbol }

    /// Tools that work on a multi-file selection.
    var isBatchCapable: Bool {
        switch self {
        case .compress, .removeMetadata, .cropImage, .normalizeAudio, .muteVideo, .splitPDF,
             .extractArchive, .createPDF, .mergePDF, .joinVideos, .createCollage:
            return true
        default:
            return false
        }
    }

    /// Tools that fold several inputs into one output.
    var combinesInputs: Bool {
        switch self {
        case .createPDF, .mergePDF, .joinVideos, .createCollage: return true
        default: return false
        }
    }

    /// Tools whose original opens an editor window before saving.
    var isInteractive: Bool {
        switch self {
        case .editImage, .annotateImage, .frameImage, .cropImage, .redactImage, .redactAudio,
             .trimVideo, .cropVideo, .redactVideo, .organizePDF, .annotatePDF, .redactPDF:
            return true
        default:
            return false
        }
    }

    /// Whether choosing this tool opens a window (an editor, or an options panel) instead of running at once.
    /// Compress and Metadata open one for a single file; batches use the Settings presets / strip everything.
    func opensPanel(forCount count: Int) -> Bool {
        if isInteractive || self == .readQR { return true }
        switch self {
        case .compress, .removeMetadata: return count == 1
        default: return false
        }
    }

    /// Output format for an input format, or nil when the tool writes a folder.
    func outputFormat(for input: String) -> String? {
        switch info.output {
        case .sameFormat: return self == .compress && input == "WAV" ? "FLAC" : input
        case .fixed(let f): return f
        case .folder, .none: return nil
        }
    }

    // MARK: - Per-format lists

    private static func tools(forFormat f: String, count: Int) -> [ToolID] {
        let many = count > 1
        switch f {
        case "JPG", "PNG", "WEBP", "HEIC", "TIFF":
            return many
                ? [.compress, .removeMetadata, .cropImage, .createPDF, .createCollage]
                : [.compress, .removeMetadata, .readQR, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage]
        case "SVG":
            return many ? [.createPDF, .createCollage] : []
        case "MP3", "M4A", "WAV", "FLAC":
            return [.compress, .removeMetadata, .normalizeAudio, .audioToVideo, .trimAudio, .audioChannels, .redactAudio]
        case "MP4", "MOV", "MKV":
            return many
                ? [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed, .joinVideos]
                : [.compress, .removeMetadata, .muteVideo, .trimVideo, .cropVideo, .changeVideoSpeed,
                   .videoSnapshots, .splitVideo, .redactVideo, .redactAudio]
        case "GIF":
            return [.removeMetadata]
        case "PDF":
            return many
                ? [.compress, .removeMetadata, .splitPDF, .mergePDF]
                : [.compress, .removeMetadata, .readQR, .organizePDF, .splitPDF, .annotatePDF, .redactPDF]
        case "ZIP", "TAR", "GZIP", "RAR":
            return [.extractArchive]
        default:
            return []
        }
    }

    /// Tools for `count` files of one format, in wheel order.
    static func tools(for format: String, count: Int) -> [ToolID] {
        guard count > 0 else { return [] }
        return tools(forFormat: format, count: count).filter { count == 1 || $0.isBatchCapable }
    }

    /// Tools for a (possibly mixed) selection: the intersection of each format's list,
    /// in the order of the first file's list.
    static func tools(forSelection formats: [String]) -> [ToolID] {
        guard let first = formats.first else { return [] }
        let count = formats.count
        var result = tools(for: first, count: count)
        for f in formats.dropFirst() {
            let other = tools(for: f, count: count)
            result.removeAll { !other.contains($0) }
        }
        return result
    }
}

enum ActionID: String, CaseIterable {
    case airDrop, float, copy, move, copyPath, terminal

    var title: String {
        switch self {
        case .airDrop: return "AIRDROP"
        case .float: return "FLOAT"
        case .copy: return "COPY"
        case .move: return "MOVE"
        case .copyPath: return "COPY PATH"
        case .terminal: return "TERMINAL"
        }
    }

    var name: String {
        switch self {
        case .airDrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .airDrop: return "airplayaudio"
        case .float: return "pin.fill"
        case .copy: return "doc.on.doc"
        case .move: return "folder"
        case .copyPath: return "doc.text"
        case .terminal: return "terminal"
        }
    }

    /// Text for Copy Path: one POSIX path per line.
    static func pathsAsText(_ paths: [URL]) -> String {
        paths.map(\.path).joined(separator: "\n")
    }

    /// Folder a terminal should open for an item: the folder itself, else its parent.
    static func terminalDirectory(for url: URL, isDirectory: Bool) -> URL {
        isDirectory ? url : url.deletingLastPathComponent()
    }
}
