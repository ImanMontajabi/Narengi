import XCTest
@testable import Narengi

final class SheetTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try TestSupport.makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private let sample = SheetEngine.Sheet(name: "Budget", rows: [
        [.text("Item"), .text("Cost"), .text("Zip")],
        [.text("Rent, monthly"), .number(1200), .text("007")],
        [.text("Coffee \"beans\""), .number(12.5), .bool(true)],
        [],
        [.text("multi\nline"), .empty, .number(-3)],
    ])

    func testCellTyping() {
        XCTAssertEqual(SheetEngine.Cell.from(text: "42"), .number(42))
        XCTAssertEqual(SheetEngine.Cell.from(text: "-3.5"), .number(-3.5))
        XCTAssertEqual(SheetEngine.Cell.from(text: "007"), .text("007"))
        XCTAssertEqual(SheetEngine.Cell.from(text: "0.5"), .number(0.5))
        XCTAssertEqual(SheetEngine.Cell.from(text: "12 apples"), .text("12 apples"))
        XCTAssertEqual(SheetEngine.Cell.from(text: " "), .empty)
        XCTAssertEqual(SheetEngine.formatNumber(3), "3")
        XCTAssertEqual(SheetEngine.formatNumber(3.25), "3.25")
    }

    func testColumnNames() {
        XCTAssertEqual(SheetEngine.columnName(0), "A")
        XCTAssertEqual(SheetEngine.columnName(25), "Z")
        XCTAssertEqual(SheetEngine.columnName(26), "AA")
        XCTAssertEqual(SheetEngine.columnIndex(of: "AB12"), 27)
        for i in [0, 1, 25, 26, 51, 701, 702] { XCTAssertEqual(SheetEngine.columnIndex(of: SheetEngine.columnName(i)), i) }
    }

    func testCSVParsingHandlesQuotesNewlinesAndLineEndings() {
        let text = "a,b,c\r\n\"x, y\",\"say \"\"hi\"\"\",\"line1\nline2\"\r\n,,\n"
        XCTAssertEqual(SheetEngine.parseDelimited(text, delimiter: ","),
                       [["a", "b", "c"], ["x, y", "say \"hi\"", "line1\nline2"], ["", "", ""]])
        XCTAssertEqual(SheetEngine.parseDelimited("a\tb\n", delimiter: "\t"), [["a", "b"]])
        XCTAssertEqual(SheetEngine.parseDelimited("", delimiter: ","), [])
        XCTAssertEqual(SheetEngine.parseDelimited("last,row", delimiter: ","), [["last", "row"]])
    }

    func testEveryFormatRoundTripsThroughTheServiceAndTheReaders() async throws {
        // CSV → XLSX → ODS → TSV → CSV, reading each result back.
        let csv = directory.appendingPathComponent("budget.csv")
        try SheetEngine.write(sample, format: "CSV", to: csv)
        XCTAssertTrue(try String(contentsOf: csv).contains("\"Rent, monthly\",1200,007"))

        var current = csv
        var currentFormat = "CSV"
        for target in ["XLSX", "ODS", "TSV", "CSV"] {
            let out = try await ConversionService.run(
                source: current, options: ConversionOptions(sourceFormat: currentFormat, targetFormat: target))[0]
            let read = try await SheetEngine.read(out, format: target)
            XCTAssertEqual(read.rows[0], [.text("Item"), .text("Cost"), .text("Zip")], target)
            XCTAssertEqual(read.rows[1], [.text("Rent, monthly"), .number(1200), .text("007")], target)
            XCTAssertEqual(read.rows[2][0], .text("Coffee \"beans\""), target)
            XCTAssertEqual(read.rows[2][1], .number(12.5), target)
            current = out
            currentFormat = target
        }
    }

    func testXLSXAndODSKeepTheSheetNameTypesAndBlankRows() async throws {
        for format in ["XLSX", "ODS"] {
            let file = directory.appendingPathComponent("typed.\(format.lowercased())")
            try SheetEngine.write(sample, format: format, to: file)
            let back = try await SheetEngine.read(file, format: format)
            XCTAssertEqual(back.name, "Budget", format)
            XCTAssertEqual(back.rows[2][2], .bool(true), format)
            XCTAssertEqual(back.rows[3], [], "\(format): blank row")
            XCTAssertEqual(back.rows[4][0], .text("multi\nline"), format)
            XCTAssertEqual(back.rows[4][2], .number(-3), format)
        }
    }

    func testXLSXReaderHandlesSharedStringsAndSparseCells() async throws {
        // A workbook the way Excel writes it: shared strings, a gap between columns, a skipped row.
        var zip = ZipWriter()
        try zip.add("[Content_Types].xml", text: "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        try zip.add("xl/workbook.xml", text: """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId7"/></sheets></workbook>
        """)
        try zip.add("xl/_rels/workbook.xml.rels", text: """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId7" Type="x" Target="worksheets/data.xml"/></Relationships>
        """)
        try zip.add("xl/sharedStrings.xml", text: """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Name</t></si><si><r><t>Rich </t></r><r><t>text</t></r></si></sst>
        """)
        try zip.add("xl/worksheets/data.xml", text: """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1"><v>2.5</v></c></row>
        <row r="3"><c r="B3" t="s"><v>1</v></c><c r="D3" t="b"><v>0</v></c></row>
        </sheetData></worksheet>
        """)
        let file = directory.appendingPathComponent("excel.xlsx")
        try zip.write(to: file)

        let sheet = try await SheetEngine.read(file, format: "XLSX")
        XCTAssertEqual(sheet.name, "Data")
        XCTAssertEqual(sheet.rows[0], [.text("Name"), .empty, .number(2.5)])
        XCTAssertEqual(sheet.rows[1], [])
        XCTAssertEqual(sheet.rows[2], [.empty, .text("Rich text"), .empty, .bool(false)])
    }

    func testPDFExportIsAnAlignedTable() throws {
        let table = SheetEngine.textTable(.init(name: "t", rows: [
            [.text("Item"), .text("Cost")],
            [.text("Rent"), .number(1200)],
            [.text("Tea"), .number(12.5)],
        ]))
        XCTAssertEqual(table, "Item  Cost\nRent  1200\nTea   12.5\n")

        let pdf = directory.appendingPathComponent("t.pdf")
        try SheetEngine.write(sample, format: "PDF", to: pdf)
        XCTAssertTrue(try Data(contentsOf: pdf).starts(with: Array("%PDF".utf8)))
    }

    func testLegacyXLSIsNotOffered() {
        XCTAssertFalse(Availability.shared.conversion(from: "XLS", to: "XLSX"))
        XCTAssertTrue(Availability.shared.conversion(from: "CSV", to: "XLSX"))
        XCTAssertTrue(Availability.shared.conversion(from: "ODS", to: "PDF"))
    }
}
