import Foundation

/// A group of related formats (Images, Documents, …) as shown in Settings → Formats / Compatibility.
struct FormatCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    /// Sidebar order in Settings → Formats.
    let formats: [String]
    /// Rows of the compatibility matrix.
    let inputs: [String]
    /// Columns of the compatibility matrix.
    let outputs: [String]
}

/// The conversion matrix: which output formats are offered for an input, in wheel order.
///
/// The reference routes follow the original app's 283-path matrix (275 on its website plus
/// image → DOCX), as documented in Satsuma's SPEC §4 (MIT, © sonatina-dream). Petal order is
/// part of the data: the PDF and JPG orders were confirmed against screenshots and a recording.
/// Narengi adds a few routes of its own, listed under `extraTargets`.
enum FormatCatalog {
    // MARK: - Route groups

    private static let imageIn = ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "SVG", "AVIF", "BMP"]
    private static let imageOut = ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF"]
    private static let audio = ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF", "WMA"]
    private static let video = ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV"]
    private static let subtitle = ["SRT", "VTT"]
    private static let documentIn = ["DOCX", "PAGES", "MD", "RTF", "RTFD", "TEXTCLIPPING"]
    private static let sheet = ["XLSX", "XLS", "ODS", "CSV", "TSV"]
    private static let documentOut = ["DOCX", "PAGES", "PDF", "TXT", "MD", "HTML", "EPUB", "PNG", "JPG"]
    private static let archiveIn = ["ZIP", "TAR", "GZIP", "RAR"]
    private static let archiveOut = ["ZIP", "TAR", "GZIP"]

    /// Formats that can be read but are never offered as an output.
    static let inputOnly: Set<String> = ["RAR", "PPT", "XLS", "RTF", "RTFD", "TEXTCLIPPING"]

    /// Document packages: folders on disk that still count as one file.
    static let packageFormats: Set<String> = ["RTFD", "PAGES"]

    private static func rawTargets(_ f: String) -> [String] {
        if imageIn.contains(f) { return imageOut + ["DOCX"] }
        if audio.contains(f) { return audio }
        if video.contains(f) { return video + ["GIF", "MP3"] }
        if f == "GIF" { return video }
        if f == "PDF" { return ["DOCX", "PAGES", "PPTX", "XLSX", "JPG", "PNG", "EPUB", "TXT", "MD"] }
        if f == "PPT" || f == "PPTX" { return ["PDF", "JPG", "PNG"] }
        if sheet.contains(f) { return sheet + ["PDF"] }
        if documentIn.contains(f) { return documentOut }
        if f == "EPUB" { return ["PDF", "DOCX", "PAGES", "TXT", "MD", "HTML"] }
        if f == "TXT" { return ["DOCX", "PAGES", "PDF", "MD", "HTML", "EPUB", "JPG", "PNG"] }
        if subtitle.contains(f) { return ["SRT", "VTT", "TXT"] }
        if archiveIn.contains(f) { return archiveOut }
        return []
    }

    /// Routes Narengi offers beyond the reference matrix (appended after the reference petals).
    private static func extraTargets(_ f: String) -> [String] {
        if imageIn.contains(f) { return ["TXT", "MD"] }  // recognised text, like image → DOCX
        if f == "PDF" { return ["HTML", "TIFF"] }
        return []
    }

    // MARK: - Public matrix

    /// The reference matrix only (283 paths in total), in wheel order.
    static func referenceTargets(from f: String) -> [String] {
        rawTargets(f).filter { $0 != f && !inputOnly.contains($0) }
    }

    /// Output formats offered for one input, in wheel order.
    static func conversionTargets(from f: String) -> [String] {
        let all = referenceTargets(from: f) + extraTargets(f)
        return all.filter { $0 != f && !inputOnly.contains($0) }
    }

    static func referencePathCount() -> Int {
        allFormats.reduce(0) { $0 + referenceTargets(from: $1).count }
    }

    /// Output formats offered for a selection: a target is offered when every file either converts to it or
    /// already has that format, and at least one file actually needs converting. Petal order follows
    /// the first file that contributes it.
    static func targets(forSelection formats: [String]) -> [String] {
        var candidates: [String] = []
        for f in formats {
            for t in conversionTargets(from: f) where !candidates.contains(t) { candidates.append(t) }
        }
        return candidates.filter { t in
            formats.allSatisfy { $0 == t || conversionTargets(from: $0).contains(t) } && formats.contains { $0 != t }
        }
    }

    /// Output formats for the dragged files (nil format = folder or unknown file → nothing).
    static func outputs(for urls: [URL]) -> [String] {
        let formats = urls.compactMap(detect)
        guard formats.count == urls.count else { return [] }
        return targets(forSelection: formats)
    }

    static func outputs(from f: String) -> [String] { conversionTargets(from: f) }

    static func canConvert(_ input: String, to output: String) -> Bool {
        conversionTargets(from: input).contains(output)
    }

    /// Input → outputs for every format, for the Compatibility tab.
    static var routes: [String: [String]] {
        Dictionary(uniqueKeysWithValues: allFormats.map { ($0, conversionTargets(from: $0)) })
    }

    // MARK: - Format detection

    private static let extensionAliases: [String: String] = [
        "jpg": "JPG", "jpeg": "JPG", "png": "PNG", "webp": "WEBP", "heic": "HEIC", "heif": "HEIC",
        "tif": "TIFF", "tiff": "TIFF", "svg": "SVG", "avif": "AVIF", "bmp": "BMP",
        "pdf": "PDF", "docx": "DOCX", "pages": "PAGES", "ppt": "PPT", "pptx": "PPTX",
        "txt": "TXT", "text": "TXT", "md": "MD", "markdown": "MD", "rtf": "RTF", "rtfd": "RTFD",
        "textclipping": "TEXTCLIPPING", "html": "HTML", "htm": "HTML", "epub": "EPUB",
        "xlsx": "XLSX", "xls": "XLS", "ods": "ODS", "csv": "CSV", "tsv": "TSV",
        "mp3": "MP3", "m4a": "M4A", "wav": "WAV", "flac": "FLAC", "ogg": "OGG", "opus": "OPUS",
        "aiff": "AIFF", "aif": "AIFF", "wma": "WMA",
        "mp4": "MP4", "m4v": "MP4", "mov": "MOV", "mkv": "MKV", "webm": "WEBM", "avi": "AVI",
        "wmv": "WMV", "gif": "GIF",
        "zip": "ZIP", "tar": "TAR", "gz": "GZIP", "gzip": "GZIP", "tgz": "GZIP", "rar": "RAR",
        "srt": "SRT", "vtt": "VTT",
    ]

    /// Format from the file extension alone.
    static func format(for url: URL) -> String? {
        extensionAliases[url.pathExtension.lowercased()]
    }

    /// Format of an item on disk: plain folders have none, document packages count as files.
    static func detect(_ url: URL) -> String? {
        guard let format = format(for: url) else { return nil }
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return isDirectory && !packageFormats.contains(format) ? nil : format
    }

    // MARK: - Categories (Settings UI)

    static let categories: [FormatCategory] = [
        FormatCategory(
            id: "images", name: "Images", symbol: "photo.on.rectangle",
            formats: ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "SVG", "AVIF", "BMP"],
            inputs: ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "SVG", "AVIF", "BMP"],
            outputs: ["JPG", "PNG", "WEBP", "HEIC", "TIFF", "AVIF", "BMP", "PDF", "DOCX", "TXT", "MD"]),
        FormatCategory(
            id: "documents", name: "Documents", symbol: "doc.text",
            formats: ["PDF", "DOCX", "PAGES", "PPT", "PPTX", "TXT", "MD", "RTF", "RTFD", "TEXTCLIPPING", "HTML", "EPUB"],
            inputs: ["PDF", "DOCX", "PAGES", "PPT", "PPTX", "TXT", "MD", "RTF", "RTFD", "TEXTCLIPPING", "EPUB"],
            outputs: ["PDF", "DOCX", "PAGES", "PPTX", "TXT", "MD", "HTML", "EPUB", "JPG", "PNG", "TIFF", "XLSX"]),
        FormatCategory(
            id: "spreadsheets", name: "Spreadsheets", symbol: "tablecells",
            formats: ["XLSX", "XLS", "ODS", "CSV", "TSV"],
            inputs: ["XLSX", "XLS", "ODS", "CSV", "TSV"],
            outputs: ["XLSX", "ODS", "CSV", "TSV", "PDF"]),
        FormatCategory(
            id: "audio", name: "Audio", symbol: "waveform",
            formats: ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF", "WMA"],
            inputs: ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF", "WMA"],
            outputs: ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF", "WMA"]),
        FormatCategory(
            id: "video", name: "Video", symbol: "film",
            formats: ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV", "GIF"],
            inputs: ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV", "GIF"],
            outputs: ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV", "GIF", "MP3"]),
        FormatCategory(
            id: "archives", name: "Archives", symbol: "archivebox",
            formats: ["ZIP", "TAR", "GZIP", "RAR"],
            inputs: ["ZIP", "TAR", "GZIP", "RAR"],
            outputs: ["ZIP", "TAR", "GZIP"]),
        FormatCategory(
            id: "subtitles", name: "Subtitles", symbol: "captions.bubble",
            formats: ["SRT", "VTT"],
            inputs: ["SRT", "VTT"],
            outputs: ["SRT", "VTT", "TXT"]),
    ]

    static var allFormats: [String] { categories.flatMap(\.formats) }

    static func category(of format: String) -> FormatCategory? {
        categories.first { $0.formats.contains(format) }
    }
}
