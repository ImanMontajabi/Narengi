import Foundation

/// Markdown → XHTML-safe HTML. Headings, paragraphs (hard breaks), emphasis, code, links, images, quotes,
/// nested lists, rules, tables and strikethrough: the subset documents actually use.
enum MarkdownRenderer {
    static func htmlBody(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var parser = Parser(lines: normalized.components(separatedBy: "\n"))
        return parser.parseBlocks()
    }

    // MARK: - Blocks

    private struct Parser {
        var lines: [String]
        var index = 0

        init(lines: [String]) { self.lines = lines }

        mutating func parseBlocks() -> String {
            var out = ""
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }

                if let fence = fenceStart(line) {
                    out += codeBlock(fence)
                } else if let (level, text) = atxHeading(line) {
                    out += "<h\(level)>\(inline(text))</h\(level)>\n"
                    index += 1
                } else if isRule(line) {
                    out += "<hr />\n"
                    index += 1
                } else if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    out += quote()
                } else if listMarker(line) != nil {
                    out += list()
                } else if isTableStart() {
                    out += table()
                } else if let (level, text) = setextHeading() {
                    out += "<h\(level)>\(inline(text))</h\(level)>\n"
                } else {
                    out += paragraph()
                }
            }
            return out
        }

        // Fenced code

        private func fenceStart(_ line: String) -> String? {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") { return "```" }
            if t.hasPrefix("~~~") { return "~~~" }
            return nil
        }

        private mutating func codeBlock(_ fence: String) -> String {
            index += 1
            var code: [String] = []
            while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                code.append(lines[index])
                index += 1
            }
            index += 1
            return "<pre><code>\(HTML.escape(code.joined(separator: "\n")))\n</code></pre>\n"
        }

        // Headings and rules

        private func atxHeading(_ line: String) -> (Int, String)? {
            let t = line.trimmingCharacters(in: .whitespaces)
            let hashes = t.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(hashes), t.count > hashes, t[t.index(t.startIndex, offsetBy: hashes)] == " " else { return nil }
            var text = String(t.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
            while text.hasSuffix("#") { text.removeLast() }
            return (hashes, text.trimmingCharacters(in: .whitespaces))
        }

        private func isRule(_ line: String) -> Bool {
            let t = line.filter { !$0.isWhitespace }
            guard t.count >= 3, let first = t.first, "-*_".contains(first) else { return false }
            return t.allSatisfy { $0 == first }
        }

        private mutating func setextHeading() -> (Int, String)? {
            guard index + 1 < lines.count else { return nil }
            let underline = lines[index + 1].trimmingCharacters(in: .whitespaces)
            guard !underline.isEmpty, underline.allSatisfy({ $0 == "=" }) || underline.allSatisfy({ $0 == "-" }) else { return nil }
            let level = underline.first == "=" ? 1 : 2
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            index += 2
            return (level, text)
        }

        // Quotes

        private mutating func quote() -> String {
            var inner: [String] = []
            while index < lines.count {
                let t = lines[index].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(">") {
                    var content = String(t.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    inner.append(content)
                } else if t.isEmpty {
                    break
                } else {
                    inner.append(t)  // lazy continuation
                }
                index += 1
            }
            var parser = Parser(lines: inner)
            return "<blockquote>\n\(parser.parseBlocks())</blockquote>\n"
        }

        // Lists

        private struct Marker {
            let indent: Int
            let ordered: Bool
            let contentOffset: Int
            let text: String
        }

        private func listMarker(_ line: String) -> Marker? {
            let indent = line.prefix(while: { $0 == " " }).count
            let rest = line.dropFirst(indent)
            if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " ", !isRule(line) {
                return Marker(indent: indent, ordered: false, contentOffset: indent + 2, text: String(rest.dropFirst(2)))
            }
            let digits = rest.prefix(while: \.isNumber)
            if !digits.isEmpty, digits.count <= 9 {
                let after = rest.dropFirst(digits.count)
                if after.first == "." || after.first == ")", after.dropFirst().first == " " {
                    return Marker(indent: indent, ordered: true, contentOffset: indent + digits.count + 2, text: String(after.dropFirst(2)))
                }
            }
            return nil
        }

        private mutating func list() -> String {
            guard let first = listMarker(lines[index]) else { return paragraph() }
            let baseIndent = first.indent
            var items: [[String]] = []
            var task: [String?] = []

            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // A blank line continues the list only when more of it follows.
                    if index + 1 < lines.count, let next = listMarker(lines[index + 1]), next.indent >= baseIndent { index += 1; continue }
                    if index + 1 < lines.count, lines[index + 1].hasPrefix("  "), !items.isEmpty { items[items.count - 1].append(""); index += 1; continue }
                    break
                }
                if let marker = listMarker(line), marker.indent == baseIndent, marker.ordered == first.ordered {
                    var text = marker.text
                    var state: String?
                    if text.hasPrefix("[ ] ") { state = "☐"; text = String(text.dropFirst(4)) }
                    else if text.lowercased().hasPrefix("[x] ") { state = "☑"; text = String(text.dropFirst(4)) }
                    items.append([text])
                    task.append(state)
                } else if marker(line)?.indent ?? 0 > baseIndent || line.hasPrefix(" ") {
                    let strip = min(line.prefix(while: { $0 == " " }).count, first.contentOffset)
                    items[items.count - 1].append(String(line.dropFirst(strip)))
                } else {
                    break
                }
                index += 1
            }

            let tag = first.ordered ? "ol" : "ul"
            var out = "<\(tag)>\n"
            for (n, item) in items.enumerated() {
                var parser = Parser(lines: item)
                var body = parser.parseBlocks()
                // Tight lists show the first paragraph without <p>.
                if body.hasPrefix("<p>"), let end = body.range(of: "</p>\n") {
                    let inner = body[body.index(body.startIndex, offsetBy: 3)..<end.lowerBound]
                    body = String(inner) + "\n" + body[end.upperBound...]
                }
                let prefix = task[n].map { "\($0) " } ?? ""
                out += "<li>\(prefix)\(body.trimmingCharacters(in: .newlines))</li>\n"
            }
            return out + "</\(tag)>\n"
        }

        private func marker(_ line: String) -> Marker? { listMarker(line) }

        // Tables

        private func isTableStart() -> Bool {
            guard index + 1 < lines.count, lines[index].contains("|") else { return false }
            let separator = lines[index + 1].trimmingCharacters(in: .whitespaces)
            return separator.contains("-") && separator.allSatisfy { "|-: ".contains($0) } && separator.contains("|")
        }

        private func cells(_ line: String) -> [String] {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        private mutating func table() -> String {
            let header = cells(lines[index])
            index += 2
            var out = "<table>\n<thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
            while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                out += "<tr>" + cells(lines[index]).map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                index += 1
            }
            return out + "</tbody>\n</table>\n"
        }

        // Paragraphs

        private func startsBlock(_ line: String) -> Bool {
            fenceStart(line) != nil || atxHeading(line) != nil || isRule(line)
                || line.trimmingCharacters(in: .whitespaces).hasPrefix(">") || listMarker(line) != nil
        }

        private mutating func paragraph() -> String {
            var collected: [String] = [lines[index]]
            index += 1
            while index < lines.count {
                let line = lines[index]
                if line.trimmingCharacters(in: .whitespaces).isEmpty || startsBlock(line) { break }
                collected.append(line)
                index += 1
            }
            var html = ""
            for (i, line) in collected.enumerated() {
                let hardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
                var text = line.trimmingCharacters(in: .whitespaces)
                if text.hasSuffix("\\") { text.removeLast() }
                html += inline(text)
                if i < collected.count - 1 { html += hardBreak ? "<br />\n" : "\n" }
            }
            return "<p>\(html)</p>\n"
        }
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        var holders: [String] = []
        func hold(_ html: String) -> String {
            holders.append(html)
            return "\u{E000}\(holders.count - 1)\u{E001}"
        }

        var s = text
        // Backslash escapes and code spans are shielded from further processing.
        s = replace(s, #"\\([\\`*_{}\[\]()#+\-.!|~<>])"#) { hold(HTML.escape($0[1])) }
        s = replace(s, #"(`+)(.+?)\1"#) { hold("<code>\(HTML.escape($0[2].trimmingCharacters(in: .whitespaces)))</code>") }
        s = replace(s, #"<(https?://[^\s>]+)>"#) { hold("<a href=\"\(HTML.escape($0[1]))\">\(HTML.escape($0[1]))</a>") }
        s = HTML.escape(s)
        s = replace(s, #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#) {
            hold("<img src=\"\($0[2])\" alt=\"\($0[1])\" />")
        }
        s = replace(s, #"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)"#) {
            hold("<a href=\"\($0[2])\">\($0[1])</a>")
        }
        s = replace(s, #"\*\*(.+?)\*\*"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"(?<![A-Za-z0-9_])__(.+?)__(?![A-Za-z0-9_])"#) { "<strong>\($0[1])</strong>" }
        s = replace(s, #"~~(.+?)~~"#) { "<del>\($0[1])</del>" }
        s = replace(s, #"\*(?!\s)(.+?)(?<!\s)\*"#) { "<em>\($0[1])</em>" }
        s = replace(s, #"(?<![A-Za-z0-9_])_(?!\s)(.+?)(?<!\s)_(?![A-Za-z0-9_])"#) { "<em>\($0[1])</em>" }

        // Restore shielded pieces (they may nest inside emphasis, so loop until stable).
        for _ in 0..<3 {
            s = replace(s, "\u{E000}(\\d+)\u{E001}") { holders[Int($0[1]) ?? 0] }
        }
        return s
    }

    /// Regex replacement where the closure receives [whole match, group1, group2, …].
    private static func replace(_ input: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return input }
        let ns = input as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: input, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            var groups: [String] = []
            for g in 0..<match.numberOfRanges {
                let r = match.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }
}

// MARK: - HTML → Markdown

/// HTML (as `textutil` and EPUB chapters write it) → Markdown. `textutil` marks headings only with a
/// larger CSS font size, so paragraph classes are mapped to heading levels by size.
enum HTMLToMarkdown {
    static func convert(_ html: String) -> String {
        var converter = Converter(tokens: HTML.tokenize(html))
        return converter.run()
    }

    static func markdownTable(_ rows: [[String]]) -> String {
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return "" }
        func line(_ r: [String]) -> String {
            "| " + (0..<cols).map { $0 < r.count ? r[$0] : "" }.joined(separator: " | ") + " |"
        }
        var s = line(rows[0]) + "\n|" + String(repeating: " --- |", count: cols) + "\n"
        for r in rows.dropFirst() { s += line(r) + "\n" }
        return s
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\*`_".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    private struct Converter {
        let tokens: [HTMLToken]
        var out = ""
        var lists: [Int?] = []          // nil = bullet, n = ordered counter
        var skip = 0
        var pre = false
        var links: [(start: Int, href: String?)] = []
        var table: [[String]]?
        var row: [String]?
        var cell: String?
        var quote = 0
        var classSizes: [String: Double] = [:]
        var bodySize: Double = 0
        var paragraphHeading: [Int] = []   // stack: heading level for open <p>, 0 = none
        var headingTags = 0
        /// Inside a heading, bold and italic markers are noise (`# **Title**`).
        var inHeading: Bool { headingTags > 0 || (paragraphHeading.last ?? 0) > 0 }

        init(tokens: [HTMLToken]) {
            self.tokens = tokens
            analyzeStyles()
        }

        /// Reads `p.p1 { font: 24.0px … }` rules and picks the most common size (by text length) as body.
        mutating func analyzeStyles() {
            var inStyle = false
            var css = ""
            for token in tokens {
                switch token {
                case .open(let name, _, _) where name == "style": inStyle = true
                case .close(let name) where name == "style": inStyle = false
                case .text(let t) where inStyle: css += t
                default: break
                }
            }
            guard !css.isEmpty, let rule = try? NSRegularExpression(pattern: #"p\.(\w+)\s*\{[^}]*?font:\s*(?:\w+\s+)*?([\d.]+)px"#) else { return }
            let ns = css as NSString
            for m in rule.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
                if let size = Double(ns.substring(with: m.range(at: 2))) { classSizes[ns.substring(with: m.range(at: 1))] = size }
            }
            // Weight each size by the text it covers.
            var weights: [Double: Int] = [:]
            var current: Double?
            for token in tokens {
                switch token {
                case .open(let name, let attrs, _) where name == "p":
                    current = HTML.attribute("class", in: attrs).flatMap { classSizes[$0] }
                case .close(let name) where name == "p": current = nil
                case .text(let t): if let current { weights[current, default: 0] += t.count }
                default: break
                }
            }
            bodySize = weights.max(by: { $0.value < $1.value })?.key ?? 0
        }

        func headingLevel(forClass cls: String?) -> Int {
            guard bodySize > 0, let cls, let size = classSizes[cls] else { return 0 }
            let ratio = size / bodySize
            return ratio >= 1.8 ? 1 : ratio >= 1.45 ? 2 : ratio >= 1.25 ? 3 : 0
        }

        mutating func run() -> String {
            for token in tokens {
                switch token {
                case .open(let name, let attrs, let selfClosing): open(name, attrs, selfClosing)
                case .close(let name): close(name)
                case .text(let t): text(t)
                }
            }
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "" : trimmed + "\n"
        }

        private var cellOrOut: String {
            get { cell ?? out }
            set { if cell != nil { cell = newValue } else { out = newValue } }
        }

        mutating func blankLine() {
            if cell != nil { cell! += " "; return }
            while out.hasSuffix(" ") || out.hasSuffix("\t") { out.removeLast() }
            if out.isEmpty { return }
            while !out.hasSuffix("\n\n") { out += "\n" }
            quotePrefix()
        }

        mutating func newline() {
            if cell != nil { cell! += " "; return }
            if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
            quotePrefix()
        }

        mutating func quotePrefix() {
            for _ in 0..<quote { out += "> " }
        }

        mutating func text(_ raw: String) {
            if skip > 0 { return }
            let decoded = HTML.decodeEntities(raw)
            if pre { cellOrOut += decoded; return }
            let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if collapsed.isEmpty {
                let buffer = cellOrOut
                if decoded.contains(where: \.isWhitespace), !buffer.isEmpty, !buffer.hasSuffix(" "), !buffer.hasSuffix("\n") { cellOrOut += " " }
                return
            }
            let lead = decoded.first?.isWhitespace == true
            let trail = decoded.last?.isWhitespace == true
            let buffer = cellOrOut
            if lead, !buffer.isEmpty, !buffer.hasSuffix(" "), !buffer.hasSuffix("\n") { cellOrOut += " " }
            cellOrOut += HTMLToMarkdown.escapeMarkdown(collapsed)
            if trail { cellOrOut += " " }
        }

        mutating func open(_ name: String, _ attrs: String, _ selfClosing: Bool) {
            if ["head", "style", "script", "title"].contains(name) {
                if !selfClosing { skip += 1 }
                return
            }
            if skip > 0 { return }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                blankLine()
                headingTags += 1
                cellOrOut += String(repeating: "#", count: Int(name.dropFirst()) ?? 1) + " "
            case "p":
                blankLine()
                let level = headingLevel(forClass: HTML.attribute("class", in: attrs))
                paragraphHeading.append(level)
                if level > 0 { cellOrOut += String(repeating: "#", count: level) + " " }
            case "div", "section", "article", "header", "footer":
                blankLine()
            case "blockquote":
                blankLine(); quote += 1; out += "> "
            case "br":
                if cell != nil { cell! += " " } else { out += "  \n"; quotePrefix() }
            case "hr":
                blankLine(); out += "---"; blankLine()
            case "ul", "ol":
                if lists.isEmpty { blankLine() }
                lists.append(name == "ol" ? 0 : nil)
            case "li":
                newline()
                let depth = max(lists.count, 1)
                var marker = "- "
                if let last = lists.indices.last, let n = lists[last] {
                    lists[last] = n + 1
                    marker = "\(n + 1). "
                }
                out += String(repeating: "  ", count: depth - 1) + marker
            case "b", "strong": if !inHeading { cellOrOut += "**" }
            case "i", "em": if !inHeading { cellOrOut += "*" }
            case "code" where !pre: cellOrOut += "`"
            case "pre":
                blankLine(); out += "```\n"; pre = true
            case "a":
                links.append((cellOrOut.count, HTML.attribute("href", in: attrs)))
            case "img":
                let a = HTML.attributes(attrs)
                if let src = a["src"] { cellOrOut += "![\(a["alt"] ?? "")](\(src))" }
            case "table":
                blankLine(); table = []
            case "tr": row = []
            case "td", "th": cell = ""
            default: break
            }
        }

        mutating func close(_ name: String) {
            if ["head", "style", "script", "title"].contains(name) { skip = max(0, skip - 1); return }
            if skip > 0 { return }
            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                headingTags = max(0, headingTags - 1)
                blankLine()
            case "div", "section", "article", "header", "footer":
                blankLine()
            case "p":
                _ = paragraphHeading.popLast()
                blankLine()
            case "blockquote":
                quote = max(0, quote - 1); blankLine()
            case "ul", "ol":
                _ = lists.popLast()
                if lists.isEmpty { blankLine() } else { newline() }
            case "b", "strong": if !inHeading { closeMarker("**") }
            case "i", "em": if !inHeading { closeMarker("*") }
            case "code" where !pre: closeMarker("`")
            case "pre":
                pre = false; newline(); out += "```"; blankLine()
            case "a":
                if let link = links.popLast() {
                    var buffer = cellOrOut
                    let start = min(link.start, buffer.count)
                    if let href = link.href, !href.isEmpty, !href.hasPrefix("#") {
                        let startIndex = buffer.index(buffer.startIndex, offsetBy: start)
                        let label = buffer[startIndex...].trimmingCharacters(in: .whitespaces)
                        buffer.removeSubrange(startIndex...)
                        buffer += "[\(label.isEmpty ? href : label)](\(href))"
                        cellOrOut = buffer
                    }
                }
            case "td", "th":
                if let c = cell {
                    cell = nil
                    row?.append(c.split(whereSeparator: \.isWhitespace).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|"))
                }
            case "tr":
                if let r = row, !r.isEmpty { table?.append(r) }
                row = nil
            case "table":
                if let rows = table {
                    out += HTMLToMarkdown.markdownTable(rows)
                    table = nil
                    blankLine()
                }
            default: break
            }
        }

        /// Closes an emphasis marker, moving trailing spaces outside it and dropping empty pairs.
        mutating func closeMarker(_ marker: String) {
            var buffer = cellOrOut
            var trailing = 0
            while buffer.hasSuffix(" ") { buffer.removeLast(); trailing += 1 }
            if buffer.hasSuffix(marker) { buffer.removeLast(marker.count) } else { buffer += marker }
            buffer += String(repeating: " ", count: trailing)
            cellOrOut = buffer
        }
    }
}

// MARK: - Printable HTML

enum PrintableHTML {
    /// Rewrites HTML so a plain text engine (CoreText) can print it: list items become indented paragraphs
    /// with explicit markers, tables become aligned monospace blocks, quotes become indented blocks.
    static func rewrite(_ html: String) -> String {
        var out = ""
        var lists: [Int?] = []
        var inItem = 0
        var table: [[String]]?
        var cell: String?

        for token in HTML.tokenize(html) {
            if table != nil {
                switch token {
                case .open(let name, _, _) where name == "tr": table!.append([])
                case .open(let name, _, _) where name == "td" || name == "th": cell = ""
                case .open(let name, _, _) where name == "br": cell? += " "
                case .close(let name) where name == "td" || name == "th":
                    if let c = cell, !table!.isEmpty {
                        table![table!.count - 1].append(c.split(whereSeparator: \.isWhitespace).joined(separator: " "))
                    }
                    cell = nil
                case .close(let name) where name == "table":
                    out += "<pre style=\"font-family: Menlo; font-size: 10px\">\(HTML.escape(alignedRows(table!)))</pre>\n"
                    table = nil
                case .text(let t): cell? += HTML.decodeEntities(t)
                default: break
                }
                continue
            }
            switch token {
            case .open(let name, _, _) where name == "table": table = []
            case .open(let name, _, _) where name == "ul" || name == "ol": lists.append(name == "ol" ? 0 : nil)
            case .close(let name) where name == "ul" || name == "ol": _ = lists.popLast()
            case .open(let name, _, _) where name == "li":
                let depth = max(lists.count, 1)
                var marker = "•"
                if let last = lists.indices.last, let n = lists[last] { lists[last] = n + 1; marker = "\(n + 1)." }
                if inItem > 0 { out += "</p>\n" }
                inItem += 1
                out += "<p style=\"margin-left: \(18 * depth)px; text-indent: -14px\">\(marker)&nbsp;&nbsp;"
            case .close(let name) where name == "li":
                if inItem > 0 { inItem -= 1; out += "</p>\n" }
            case .open(let name, _, _) where name == "p" && inItem > 0, .close(let name) where name == "p" && inItem > 0:
                break  // a paragraph inside a list item would split the marker from its text
            case .open(let name, _, _) where name == "blockquote": out += "<div style=\"margin-left: 24px; color: #555555\">"
            case .close(let name) where name == "blockquote": out += "</div>"
            case .open(let name, let attrs, let selfClosing):
                out += "<\(name)" + attrs.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/")).trimmingCharacters(in: .whitespaces).prependingSpace + (selfClosing ? " />" : ">")
            case .close(let name): out += "</\(name)>"
            case .text(let t): out += t
            }
        }
        return out
    }

    /// Rows as space-aligned columns.
    static func alignedRows(_ rows: [[String]]) -> String {
        let cols = rows.map(\.count).max() ?? 0
        let widths = (0..<cols).map { c in rows.compactMap { $0.count > c ? $0[c].count : nil }.max() ?? 0 }
        return rows.map { row in
            (0..<cols).map { c -> String in
                let s = c < row.count ? row[c] : ""
                return s + String(repeating: " ", count: widths[c] - s.count)
            }.joined(separator: "   ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n") + "\n"
    }
}

private extension String {
    var prependingSpace: String { isEmpty ? "" : " " + self }
}
