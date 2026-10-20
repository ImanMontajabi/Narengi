import Foundation

/// Output naming. Ported in behaviour from Satsuma's `naming.rs` (MIT, © sonatina-dream).
/// Results never overwrite: a clash takes the next free ` 2`, ` 3`, … suffix.
enum NamingRules {
    /// File name without its extension; `.tar.gz` and `.tgz` count as one extension and a
    /// leading dot alone (".bashrc") is not an extension.
    static func stem(of fileName: String) -> String {
        let lower = fileName.lowercased()
        var cut: String.Index?
        if lower.hasSuffix(".tar.gz") {
            cut = fileName.index(fileName.endIndex, offsetBy: -".tar.gz".count)
        } else if lower.hasSuffix(".tgz") {
            cut = fileName.index(fileName.endIndex, offsetBy: -".tgz".count)
        } else if let dot = fileName.lastIndex(of: ".") {
            cut = dot
        }
        guard let cut, cut != fileName.startIndex else { return fileName }
        return String(fileName[..<cut])
    }

    /// Extension written for an output format (`GZIP` writes `.tar.gz`).
    static func fileExtension(for format: String) -> String {
        switch format {
        case "GZIP": return "tar.gz"
        case "TEXTCLIPPING": return "textClipping"
        default: return format.lowercased()
        }
    }

    static func name(_ base: String, _ ext: String?) -> String {
        guard let ext, !ext.isEmpty else { return base }
        return "\(base).\(ext)"
    }

    /// `<base>.<ext>`, `<base> 2.<ext>`, `<base> 3.<ext>`, … — the first one `taken` doesn't claim.
    static func firstFree(base: String, ext: String?, taken: (String) -> Bool) -> String {
        let first = name(base, ext)
        if !taken(first) { return first }
        var n = 2
        while true {
            let candidate = name("\(base) \(n)", ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }

    /// `photo.png` → `photo.jpg` / `photo 2.jpg`.
    static func conversionOutputName(fileName: String, target: String, taken: (String) -> Bool) -> String {
        firstFree(base: stem(of: fileName), ext: fileExtension(for: target), taken: taken)
    }

    /// `photo.jpg` → `photo Compressed.jpg`; a nil `outputFormat` means a folder.
    static func toolOutputName(fileName: String, label: String, outputFormat: String?, taken: (String) -> Bool) -> String {
        firstFree(base: "\(stem(of: fileName)) \(label)", ext: outputFormat.map(fileExtension(for:)), taken: taken)
    }
}
