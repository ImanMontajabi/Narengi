import Foundation

/// Spreadsheet conversions (first sheet only): CSV/TSV, XLSX and ODS read and write, PDF as an aligned
/// table. Cell typing and the ODS/PDF layouts follow Satsuma's `sheet.rs` (MIT, © sonatina-dream).
/// Legacy binary `.xls` input is not supported, so XLS is never offered.
enum SheetEngine {
    enum Cell: Equatable {
        case empty
        case number(Double)
        case text(String)
        case bool(Bool)

        /// Interprets CSV text: plain numbers become numbers (but "007" stays text).
        static func from(text raw: String) -> Cell {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .empty }
            let digits = t.drop(while: { $0 == "-" })
            let leadingZero = digits.count > 1 && digits.hasPrefix("0") && !digits.hasPrefix("0.")
            if !leadingZero, t.allSatisfy({ $0.isNumber || "-.eE+".contains($0) }), let n = Double(t), n.isFinite {
                return .number(n)
            }
            return .text(raw)
        }

        var display: String {
            switch self {
            case .empty: return ""
            case .number(let n): return SheetEngine.formatNumber(n)
            case .text(let s): return s
            case .bool(let b): return b ? "TRUE" : "FALSE"
            }
        }
    }

    struct Sheet: Equatable {
        var name: String
        var rows: [[Cell]]
    }

    static func formatNumber(_ n: Double) -> String {
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return "\(n)"
    }

    // MARK: - Reading

    static func read(_ url: URL, format: String) async throws -> Sheet {
        switch format {
        case "CSV": return try readDelimited(url, delimiter: ",")
        case "TSV": return try readDelimited(url, delimiter: "\t")
        case "XLSX": return try await readXLSX(url)
        case "ODS": return try await readODS(url)
        default: throw ConversionError.unsupported(from: format, to: "table")
        }
    }

    // CSV (RFC 4180: quoted fields, doubled quotes, embedded newlines)

    static func parseDelimited(_ text: String, delimiter: Character) -> [[String]] {
        // Scalars, not Characters: Swift fuses "\r\n" into a single Character.
        let scalars = Array(text.unicodeScalars)
        guard let separator = delimiter.unicodeScalars.first else { return [] }
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var i = 0

        func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
        func endRow() { endField(); rows.append(row); row = [] }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"", field.isEmpty {
                inQuotes = true
            } else if c == separator {
                endField()
            } else if c == "\n" {
                endRow()
            } else if c == "\r" {
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static func readDelimited(_ url: URL, delimiter: Character) throws -> Sheet {
        let data = try Data(contentsOf: url)
        let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        let text = String(decoding: bytes, as: UTF8.self)
        let rows = parseDelimited(text, delimiter: delimiter).map { $0.map(Cell.from(text:)) }
        return Sheet(name: "Sheet1", rows: rows)
    }

    // XLSX

    private static func scratchDirectory(_ prefix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("narengi-\(prefix)-\(UUID().uuidString)")
    }

    /// Column index from a cell reference like "AB12" (A = 0).
    static func columnIndex(of reference: String) -> Int {
        var n = 0
        for c in reference.uppercased() {
            guard let v = c.asciiValue, v >= 65, v <= 90 else { break }
            n = n * 26 + Int(v - 64)
        }
        return max(0, n - 1)
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    private static func readXLSX(_ url: URL) async throws -> Sheet {
        let scratch = scratchDirectory("xlsx")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do { try await ArchiveEngine.extract(url, format: "ZIP", into: scratch) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ConversionError.decodeFailed(url.lastPathComponent) }

        func file(_ path: String) -> Data? { try? Data(contentsOf: scratch.appendingPathComponent(path)) }

        // Which part is the first sheet, and what is it called?
        var sheetName = "Sheet1"
        var sheetPath = "xl/worksheets/sheet1.xml"
        if let workbook = file("xl/workbook.xml") {
            let parser = TagCollector(workbook) { name, attrs in
                name == "sheet" ? attrs : nil
            }
            if let first = parser.matches.first {
                sheetName = first["name"] ?? sheetName
                if let rid = first["r:id"], let rels = file("xl/_rels/workbook.xml.rels") {
                    let relationships = TagCollector(rels) { name, attrs in name == "Relationship" ? attrs : nil }
                    if let target = relationships.matches.first(where: { $0["Id"] == rid })?["Target"] {
                        sheetPath = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                    }
                }
            }
        }

        var shared: [String] = []
        if let data = file("xl/sharedStrings.xml") { shared = SharedStringsParser.parse(data) }
        guard let sheetData = file(sheetPath) else { throw ConversionError.decodeFailed(url.lastPathComponent) }
        return Sheet(name: sheetName, rows: XLSXSheetParser.parse(sheetData, shared: shared))
    }

    // ODS

    private static func readODS(_ url: URL) async throws -> Sheet {
        let scratch = scratchDirectory("ods")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do { try await ArchiveEngine.extract(url, format: "ZIP", into: scratch) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ConversionError.decodeFailed(url.lastPathComponent) }
        guard let data = try? Data(contentsOf: scratch.appendingPathComponent("content.xml")) else {
            throw ConversionError.decodeFailed(url.lastPathComponent)
        }
        return ODSParser.parse(data)
    }

    // MARK: - Writing

    static func write(_ sheet: Sheet, format: String, to url: URL) throws {
        switch format {
        case "CSV": try writeDelimited(sheet, delimiter: ",", to: url)
        case "TSV": try writeDelimited(sheet, delimiter: "\t", to: url)
        case "XLSX": try writeXLSX(sheet, to: url)
        case "ODS": try writeODS(sheet, to: url)
        case "PDF": try PDFPaginator.writeMonospaced(textTable(sheet), to: url)
        default: throw ConversionError.unsupported(from: "table", to: format)
        }
    }

    private static func quoteField(_ s: String, delimiter: Character) -> String {
        if s.contains(delimiter) || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    private static func writeDelimited(_ sheet: Sheet, delimiter: Character, to url: URL) throws {
        let text = sheet.rows.map { row in
            row.isEmpty ? "" : row.map { quoteField($0.display, delimiter: delimiter) }.joined(separator: String(delimiter))
        }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    private static func xml(_ s: String) -> String {
        HTML.escape(s).replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func writeXLSX(_ sheet: Sheet, to url: URL) throws {
        let name = String(sheet.name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
        var rowsXML = ""
        for (r, row) in sheet.rows.enumerated() {
            var cells = ""
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(r + 1)"
                switch cell {
                case .empty: break
                case .number(let n): cells += "<c r=\"\(ref)\"><v>\(formatNumber(n))</v></c>"
                case .bool(let b): cells += "<c r=\"\(ref)\" t=\"b\"><v>\(b ? 1 : 0)</v></c>"
                case .text(let s): cells += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xml(s))</t></is></c>"
                }
            }
            rowsXML += "<row r=\"\(r + 1)\">\(cells)</row>"
        }

        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """)
        try zip.add("_rels/.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        try zip.add("xl/workbook.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(xml(name.isEmpty ? "Sheet1" : name))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        try zip.add("xl/_rels/workbook.xml.rels", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """)
        try zip.add("xl/worksheets/sheet1.xml", text: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rowsXML)</sheetData></worksheet>
        """)
        try zip.write(to: url)
    }

    private static func writeODS(_ sheet: Sheet, to url: URL) throws {
        var content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2"><office:body><office:spreadsheet>
        """
        content += "<table:table table:name=\"\(xml(sheet.name))\">"
        for row in sheet.rows {
            content += "<table:table-row>"
            if row.isEmpty { content += "<table:table-cell/>" }
            for cell in row {
                switch cell {
                case .empty: content += "<table:table-cell/>"
                case .number(let n):
                    content += "<table:table-cell office:value-type=\"float\" office:value=\"\(n)\"><text:p>\(formatNumber(n))</text:p></table:table-cell>"
                case .bool(let b):
                    content += "<table:table-cell office:value-type=\"boolean\" office:boolean-value=\"\(b)\"><text:p>\(b ? "TRUE" : "FALSE")</text:p></table:table-cell>"
                case .text(let s):
                    content += "<table:table-cell office:value-type=\"string\"><text:p>\(xml(s))</text:p></table:table-cell>"
                }
            }
            content += "</table:table-row>"
        }
        content += "</table:table></office:spreadsheet></office:body></office:document-content>\n"

        var zip = ZipWriter()
        try zip.add("mimetype", text: "application/vnd.oasis.opendocument.spreadsheet", compress: false)
        try zip.add("META-INF/manifest.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
         <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="application/vnd.oasis.opendocument.spreadsheet"/>
         <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        """)
        try zip.add("content.xml", text: content)
        try zip.write(to: url)
    }

    /// Aligned plain-text rendering used for PDF export (numbers right-aligned).
    static func textTable(_ sheet: Sheet) -> String {
        let maxWidth = 40
        let cols = sheet.rows.map(\.count).max() ?? 0
        func cell(_ row: [Cell], _ c: Int) -> String {
            let s = (c < row.count ? row[c].display : "").replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
            return s.count > maxWidth ? String(s.prefix(maxWidth - 1)) + "…" : s
        }
        let widths = (0..<cols).map { c in sheet.rows.map { cell($0, c).count }.max() ?? 0 }
        return sheet.rows.map { row in
            let line = (0..<cols).map { c -> String in
                let s = cell(row, c)
                let pad = String(repeating: " ", count: widths[c] - s.count)
                if case .number = (c < row.count ? row[c] : .empty) { return pad + s }
                return s + pad
            }.joined(separator: "  ")
            return line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n") + "\n"
    }

    // MARK: - Conversion

    static func convert(
        source: URL, options: ConversionOptions, allocator: OutputAllocator, progress: @Sendable (Double) -> Void
    ) async throws -> [URL] {
        let sheet = try await read(source, format: options.sourceFormat)
        progress(0.5)
        try Task.checkCancellation()
        let output = try allocator.allocateFile(for: source, pathExtension: NamingRules.fileExtension(for: options.targetFormat))
        try write(sheet, format: options.targetFormat, to: output)
        progress(1)
        return [output]
    }
}

// MARK: - XML parsers

/// Collects (name, attributes) of start tags that `select` accepts.
private final class TagCollector: NSObject, XMLParserDelegate {
    private let select: (String, [String: String]) -> [String: String]?
    private(set) var matches: [[String: String]] = []

    init(_ data: Data, select: @escaping (String, [String: String]) -> [String: String]?) {
        self.select = select
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        if let hit = select(local, attributeDict) { matches.append(hit) }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current) }
    }
}

private final class XLSXSheetParser: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [[SheetEngine.Cell]] = []
    private var rowIndex = 0
    private var row: [SheetEngine.Cell] = []
    private var cellType = ""
    private var cellColumn = 0
    private var text = ""
    private var inValue = false
    private var inInlineText = false
    private var inCell = false

    init(shared: [String]) { self.shared = shared }

    static func parse(_ data: Data, shared: [String]) -> [[SheetEngine.Cell]] {
        let delegate = XLSXSheetParser(shared: shared)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        switch name {
        case "row":
            let target = (a["r"].flatMap(Int.init) ?? rows.count + 1) - 1
            while rows.count < target { rows.append([]) }
            rowIndex = target
            row = []
        case "c":
            inCell = true
            cellType = a["t"] ?? "n"
            cellColumn = a["r"].map(SheetEngine.columnIndex(of:)) ?? row.count
            text = ""
        case "v": inValue = true
        case "t": if inCell { inInlineText = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineText { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "v": inValue = false
        case "t": inInlineText = false
        case "c":
            while row.count < cellColumn { row.append(.empty) }
            let cell: SheetEngine.Cell
            switch cellType {
            case "s": cell = Int(text.trimmingCharacters(in: .whitespaces)).flatMap { shared.indices.contains($0) ? shared[$0] : nil }.map(SheetEngine.Cell.text) ?? .empty
            case "str", "inlineStr", "e", "d": cell = text.isEmpty ? .empty : .text(text)
            case "b": cell = .bool(text.trimmingCharacters(in: .whitespaces) == "1")
            default: cell = Double(text.trimmingCharacters(in: .whitespaces)).map(SheetEngine.Cell.number) ?? (text.isEmpty ? .empty : .text(text))
            }
            row.append(cell)
            inCell = false
        case "row":
            while case .empty? = row.last { row.removeLast() }
            if rows.count > rowIndex { rows[rowIndex] = row } else { rows.append(row) }
        default: break
        }
    }
}

private final class ODSParser: NSObject, XMLParserDelegate {
    private var sheetName = "Sheet1"
    private var rows: [[SheetEngine.Cell]] = []
    private var row: [SheetEngine.Cell] = []
    private var rowRepeat = 1
    private var tableDepth = 0
    private var finished = false
    private var cellType = ""
    private var cellValue = ""
    private var cellRepeat = 1
    private var paragraphs: [String] = []
    private var inParagraph = false
    private var inCell = false

    static func parse(_ data: Data) -> SheetEngine.Sheet {
        let delegate = ODSParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        while let last = delegate.rows.last, last.isEmpty { delegate.rows.removeLast() }
        return SheetEngine.Sheet(name: delegate.sheetName, rows: delegate.rows)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
        guard !finished else { return }
        switch name {
        case "table:table":
            tableDepth += 1
            if tableDepth == 1 { sheetName = a["table:name"] ?? sheetName }
        case "table:table-row":
            row = []
            rowRepeat = Int(a["table:number-rows-repeated"] ?? "") ?? 1
        case "table:table-cell", "table:covered-table-cell":
            inCell = true
            cellType = a["office:value-type"] ?? ""
            cellValue = a["office:value"] ?? a["office:boolean-value"] ?? ""
            cellRepeat = Int(a["table:number-columns-repeated"] ?? "") ?? 1
            paragraphs = []
        case "text:p":
            if inCell { inParagraph = true; paragraphs.append("") }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inParagraph, !paragraphs.isEmpty { paragraphs[paragraphs.count - 1] += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard !finished else { return }
        switch name {
        case "text:p": inParagraph = false
        case "table:table-cell", "table:covered-table-cell":
            let cell: SheetEngine.Cell
            switch cellType {
            case "float", "percentage", "currency": cell = Double(cellValue).map(SheetEngine.Cell.number) ?? .empty
            case "boolean": cell = .bool(cellValue == "true")
            case "string", "": let t = paragraphs.joined(separator: "\n"); cell = t.isEmpty ? .empty : .text(t)
            default: let t = paragraphs.joined(separator: "\n"); cell = t.isEmpty ? .empty : .text(t)
            }
            // Large repeat counts are padding to the sheet's edge; only keep what's meaningful.
            let count = cell == .empty ? min(cellRepeat, 1) : min(cellRepeat, 256)
            for _ in 0..<count { row.append(cell) }
            inCell = false
        case "table:table-row":
            while case .empty? = row.last { row.removeLast() }
            let repeats = row.isEmpty ? min(rowRepeat, 1) : min(rowRepeat, 1000)
            for _ in 0..<repeats { rows.append(row) }
        case "table:table":
            tableDepth -= 1
            if tableDepth == 0 { finished = true }
        default: break
        }
    }
}
