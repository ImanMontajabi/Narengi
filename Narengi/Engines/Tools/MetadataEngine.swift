import Foundation
import ImageIO
import PDFKit

/// One row of the Metadata window.
struct MetadataEntry: Identifiable, Equatable {
    /// Unique, and what ExifTool is told to edit (`IFD0:Artist`, `PDF:Title`).
    let id: String
    let group: String
    let label: String
    var value: String
    var isEditable: Bool
}

struct MetadataGroup: Identifiable, Equatable {
    var id: String { name }
    let name: String
    var entries: [MetadataEntry]
}

/// Reading, editing and removing metadata. ExifTool is used when present (read, edit, strip); without it
/// JPEG/PNG/WebP/GIF are stripped losslessly in Swift, PDFs through PDFKit and audio/video through ffmpeg,
/// so Remove Metadata always works.
struct MetadataEngine {
    var tools: BundledToolLocator = .shared
    var media: MediaEnvironment = .shared

    static let strippableImages: Set<String> = ["JPG", "PNG", "WEBP", "GIF"]

    // MARK: - Reading

    func read(_ url: URL, format: String) async throws -> [MetadataGroup] {
        if let exiftool = tools.locate(.exiftool) {
            let output = try await ProcessRunner.capture(exiftool, arguments: ["-json", "-G1", "-a", "-s", "-struct", "-q", url.path])
            if let groups = Self.parseExifTool(output.standardOutput), !groups.isEmpty { return groups }
        }
        return try await fallbackRead(url, format: format)
    }

    /// Groups ExifTool's flat `Group:Tag` JSON; file-system and tool bookkeeping groups are hidden.
    static func parseExifTool(_ json: String) -> [MetadataGroup]? {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else { return nil }
        let hidden: Set<String> = ["System", "ExifTool", "File", "SourceFile"]
        var grouped: [String: [MetadataEntry]] = [:]
        var order: [String] = []
        for key in first.keys.sorted() where key != "SourceFile" {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !hidden.contains(parts[0]) else { continue }
            let value = flatten(first[key] as Any)
            guard !value.isEmpty, !value.hasPrefix("(Binary data") else { continue }
            let group = displayGroup(parts[0])
            if grouped[group] == nil { order.append(group) }
            grouped[group, default: []].append(
                MetadataEntry(id: key, group: group, label: prettyLabel(parts[1]), value: value, isEditable: !parts[0].hasPrefix("Composite")))
        }
        // Derived values (Composite) read best at the end.
        let sorted = order.filter { $0 != "Composite" } + order.filter { $0 == "Composite" }
        return sorted.map { MetadataGroup(name: $0, entries: grouped[$0] ?? []) }
    }

    private static func flatten(_ value: Any) -> String {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        case let array as [Any]: return array.map(flatten).joined(separator: ", ")
        default: return String(describing: value)
        }
    }

    static func displayGroup(_ raw: String) -> String {
        switch raw {
        case "IFD0", "IFD1", "ExifIFD", "Exif": return "Camera & Exif"
        case "GPS": return "Location"
        case "XMP-dc", "XMP-xmp", "XMP", "PDF", "PDF-update", "Keys", "QuickTime", "ID3v2_3", "ID3v2_4", "ID3v1", "Vorbis", "FLAC": return "Document"
        case "ICC_Profile", "ICC-header": return "Color profile"
        case "IPTC", "Photoshop": return "IPTC"
        default: return raw.hasPrefix("XMP") ? "Document" : raw
        }
    }

    /// `CreateDate` → `Create Date`, `ISO` stays.
    static func prettyLabel(_ tag: String) -> String {
        var result = ""
        var previous: Character?
        for character in tag {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber { result.append(" ") }
            result.append(character)
            previous = character
        }
        return result
    }

    private func fallbackRead(_ url: URL, format: String) async throws -> [MetadataGroup] {
        var groups: [MetadataGroup] = []
        func add(_ name: String, _ pairs: [(String, String)], editable: Bool = false) {
            let entries = pairs.filter { !$0.1.isEmpty }.map {
                MetadataEntry(id: "\(name):\($0.0)", group: name, label: Self.prettyLabel($0.0), value: $0.1, isEditable: editable)
            }
            if !entries.isEmpty { groups.append(MetadataGroup(name: name, entries: entries)) }
        }
        if format == "PDF" {
            if let document = PDFDocument(url: url), let attributes = document.documentAttributes {
                let pairs = attributes.compactMap { key, value -> (String, String)? in
                    guard let key = key as? String else { return nil }
                    return (key.replacingOccurrences(of: "Document", with: ""), "\(value)")
                }.sorted { $0.0 < $1.0 }
                add("Document", pairs, editable: true)
            }
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
                if let dictionary = value as? [String: Any] {
                    add(key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")), dictionary.sorted { $0.key < $1.key }.map { ($0.key, "\($0.value)") })
                }
            }
        } else if let ffmpeg = media.ffmpeg {
            let output = try await ProcessRunner.capture(ffmpeg, arguments: ["-hide_banner", "-nostdin", "-i", url.path])
            add("Document", Self.ffmpegTags(output.standardError))
        }
        return groups
    }

    /// Key/value rows from the `Metadata:` blocks of `ffmpeg -i` output.
    static func ffmpegTags(_ text: String) -> [(String, String)] {
        var tags: [(String, String)] = []
        var inMetadata = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "Metadata:" { inMetadata = true; continue }
            if trimmed.hasPrefix("Stream #") || trimmed.hasPrefix("Duration:") || trimmed.hasPrefix("Input #") { inMetadata = false }
            guard inMetadata, let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty, !tags.contains(where: { $0.0 == key }) { tags.append((key, value)) }
        }
        return tags
    }

    // MARK: - Editing (ExifTool)

    var canEdit: Bool { tools.locate(.exiftool) != nil }

    /// Writes `changes` (tag → new value; nil deletes) to a copy of `source` at `output`.
    func save(source: URL, output: URL, format: String, changes: [String: String?]) async throws {
        if format == "PDF" {
            try savePDF(source: source, output: output, changes: changes)
            return
        }
        let exiftool = try tools.require(.exiftool)
        try FileManager.default.copyItem(at: source, to: output)
        var arguments = ["-overwrite_original", "-q"]
        for (tag, value) in changes.sorted(by: { $0.key < $1.key }) {
            arguments.append(value.map { "-\(tag)=\($0)" } ?? "-\(tag)=")
        }
        arguments.append(output.path)
        try await ProcessRunner.run(exiftool, arguments: arguments, tool: "exiftool")
    }

    private func savePDF(source: URL, output: URL, changes: [String: String?]) throws {
        let document = try PDFEngine.open(source)
        var attributes = document.documentAttributes ?? [:]
        for (tag, value) in changes {
            let name = tag.split(separator: ":").last.map(String.init) ?? tag
            let key = Self.pdfAttributeKeys[name] ?? name + "Document"
            attributes[key] = value
            if value == nil { attributes.removeValue(forKey: key) }
        }
        document.documentAttributes = attributes
        guard document.write(to: output) else { throw ConversionError.encodeFailed("PDF") }
    }

    private static let pdfAttributeKeys: [String: String] = [
        "Title": PDFDocumentAttribute.titleAttribute.rawValue, "Author": PDFDocumentAttribute.authorAttribute.rawValue,
        "Subject": PDFDocumentAttribute.subjectAttribute.rawValue, "Keywords": PDFDocumentAttribute.keywordsAttribute.rawValue,
        "Creator": PDFDocumentAttribute.creatorAttribute.rawValue, "Producer": PDFDocumentAttribute.producerAttribute.rawValue,
        "CreationDate": PDFDocumentAttribute.creationDateAttribute.rawValue, "ModDate": PDFDocumentAttribute.modificationDateAttribute.rawValue,
    ]

    // MARK: - Removing

    /// Writes a metadata-free copy of `source` to `output`.
    func strip(source: URL, output: URL, format: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        switch format {
        case "PDF":
            try stripPDF(source: source, output: output)
        case "JPG", "PNG", "WEBP", "GIF":
            // The native stripper keeps ICC profiles and orientation and never re-encodes.
            let stripped = try MetadataStripper.strip(try Data(contentsOf: source), format: format)
            try stripped.write(to: output)
            if let exiftool = tools.locate(.exiftool) {
                // Belt and braces: whatever the byte pass kept (vendor tags) goes too, orientation and colour stay.
                _ = try? await ProcessRunner.run(
                    exiftool, arguments: ["-overwrite_original", "-q", "-all=", "-tagsFromFile", "@", "-Orientation", "-ICC_Profile", output.path],
                    tool: "exiftool")
            }
        case "HEIC", "TIFF", "AVIF", "BMP":
            let exiftool = try tools.require(.exiftool)
            try FileManager.default.copyItem(at: source, to: output)
            try await ProcessRunner.run(
                exiftool, arguments: ["-overwrite_original", "-q", "-all=", "-tagsFromFile", "@", "-Orientation", "-ICC_Profile", output.path],
                tool: "exiftool")
        default:
            // Audio and video: ffmpeg copies the streams without their tags.
            try await MediaEngine(env: media).removeMetadata(source: source, output: output, format: format, progress: progress)
        }
        progress(1)
    }

    /// Drops the document info dictionary (author, title, creator, keywords, dates).
    func stripPDF(source: URL, output: URL) throws {
        let document = try PDFEngine.open(source)
        document.documentAttributes = [:]
        guard document.write(to: output) else { throw ConversionError.encodeFailed("PDF") }
    }
}
