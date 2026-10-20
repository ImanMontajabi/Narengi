import Foundation

enum HTMLToken: Equatable {
    case open(name: String, attrs: String, selfClosing: Bool)
    case close(name: String)
    case text(String)
}

/// A small, tolerant HTML tokenizer and helpers. It handles what `textutil` and EPUB chapters produce
/// (unclosed `<br>`, `<meta>`, entities). Design ported from Satsuma's `html.rs` (MIT, © sonatina-dream).
enum HTML {
    /// Splits HTML into tags and text. Comments, doctypes and processing instructions are dropped.
    static func tokenize(_ html: String) -> [HTMLToken] {
        let bytes = Array(html.utf8)
        var tokens: [HTMLToken] = []
        var pos = 0
        func string(_ a: Int, _ b: Int) -> String { String(decoding: bytes[a..<b], as: UTF8.self) }

        while pos < bytes.count {
            if bytes[pos] == UInt8(ascii: "<") {
                if bytes[pos...].starts(with: Array("<!--".utf8)) {
                    if let end = find(Array("-->".utf8), in: bytes, from: pos) { pos = end + 3 } else { pos = bytes.count }
                    continue
                }
                guard let close = bytes[pos...].firstIndex(of: UInt8(ascii: ">")) else {
                    tokens.append(.text(string(pos, bytes.count)))
                    break
                }
                let inner = string(pos + 1, close)
                pos = close + 1
                if inner.hasPrefix("!") || inner.hasPrefix("?") { continue }
                if inner.hasPrefix("/") {
                    tokens.append(.close(name: tagName(String(inner.dropFirst()))))
                } else {
                    let name = tagName(inner)
                    if name.isEmpty { continue }
                    let attrStart = inner.firstIndex(where: \.isWhitespace) ?? inner.endIndex
                    let attrs = String(inner[attrStart...])
                    tokens.append(.open(name: name, attrs: attrs, selfClosing: inner.trimmingCharacters(in: .whitespaces).hasSuffix("/")))
                }
            } else {
                let end = bytes[pos...].firstIndex(of: UInt8(ascii: "<")) ?? bytes.count
                tokens.append(.text(string(pos, end)))
                pos = end
            }
        }
        return tokens
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        var i = from
        while i <= bytes.count - needle.count {
            if bytes[i] == needle[0], bytes[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    private static func tagName(_ s: String) -> String {
        String(s.drop(while: \.isWhitespace).prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ":" || $0 == "-") })).lowercased()
    }

    /// Attribute values of a tag, keyed by lower-cased name.
    static func attributes(_ attrs: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(attrs)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 }
            var name = ""
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" { name.append(chars[i]); i += 1 }
            guard !name.isEmpty else { break }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]; i += 1
                    while i < chars.count, chars[i] != quote { value.append(chars[i]); i += 1 }
                    i += 1
                } else {
                    while i < chars.count, !chars[i].isWhitespace, chars[i] != ">" { value.append(chars[i]); i += 1 }
                }
            }
            result[name.lowercased()] = decodeEntities(value)
        }
        return result
    }

    static func attribute(_ name: String, in attrs: String) -> String? {
        attributes(attrs)[name.lowercased()]
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "mdash": "—", "ndash": "–",
        "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®",
        "trade": "™", "bull": "•",
    ]

    /// Decodes the common named entities and numeric character references.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            rest = rest[amp...]
            let window = rest.prefix(12)
            if let semi = window.firstIndex(of: ";") {
                let name = String(rest[rest.index(after: rest.startIndex)..<semi])
                var decoded: String?
                if let named = namedEntities[name] {
                    decoded = named
                } else if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                }
                if let decoded {
                    out += decoded
                    rest = rest[rest.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = rest.dropFirst()
        }
        return out + rest
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Wraps a body in a minimal UTF-8 HTML document.
    static func document(title: String, body: String) -> String {
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>\(escape(title))</title>\n</head>\n<body>\n\(body)\n</body>\n</html>\n"
    }

    /// Inner HTML of `<body>`, or the whole input when there is no body tag.
    static func bodyOf(_ html: String) -> String {
        let lower = html.lowercased()
        var start = html.startIndex
        if let open = lower.range(of: "<body"), let close = lower[open.lowerBound...].firstIndex(of: ">") {
            start = lower.index(after: close)
        }
        var end = html.endIndex
        if let closing = lower.range(of: "</body>", options: .backwards), closing.lowerBound >= start {
            end = closing.lowerBound
        }
        // `lower` and `html` share indices only when lowercasing didn't change the byte layout.
        if lower.utf8.count == html.utf8.count { return String(html[start..<end]) }
        return String(html)
    }

    // MARK: - Plain text helpers

    static func splitParagraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\n")) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Paragraphs of plain text as HTML.
    static func textToBody(_ text: String) -> String {
        splitParagraphs(text).map { "<p>" + escape($0).replacingOccurrences(of: "\n", with: "<br />\n") + "</p>\n" }.joined()
    }

    /// Reflows extracted PDF text into Markdown paragraphs (de-hyphenating line breaks).
    static func textToMarkdown(_ text: String) -> String {
        var out = ""
        for paragraph in splitParagraphs(text) {
            var joined = ""
            for line in paragraph.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                if joined.hasSuffix("-"), !joined.hasSuffix(" -") {
                    joined.removeLast()
                    joined += line
                } else {
                    if !joined.isEmpty { joined += " " }
                    joined += line
                }
            }
            out += joined + "\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}
