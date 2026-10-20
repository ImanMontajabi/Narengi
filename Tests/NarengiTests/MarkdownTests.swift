import XCTest
@testable import Narengi

final class MarkdownTests: XCTestCase {
    private func html(_ md: String) -> String { MarkdownRenderer.htmlBody(md) }

    func testHeadingsParagraphsAndHardBreaks() {
        let out = html("# Title\n\nFirst line  \nsecond line\n\nSetext\n======\n")
        XCTAssertTrue(out.contains("<h1>Title</h1>"), out)
        XCTAssertTrue(out.contains("<p>First line<br />\nsecond line</p>"), out)
        XCTAssertTrue(out.contains("<h1>Setext</h1>"), out)
    }

    func testInlineStyles() {
        let out = html("**bold** and *italic* and ~~gone~~ and `a < b` and [link](https://example.com) and \\*literal\\*")
        XCTAssertTrue(out.contains("<strong>bold</strong>"), out)
        XCTAssertTrue(out.contains("<em>italic</em>"), out)
        XCTAssertTrue(out.contains("<del>gone</del>"), out)
        XCTAssertTrue(out.contains("<code>a &lt; b</code>"), out)
        XCTAssertTrue(out.contains("<a href=\"https://example.com\">link</a>"), out)
        XCTAssertTrue(out.contains("*literal*"), out)
        XCTAssertFalse(out.contains("<em>literal"), out)
    }

    func testSnakeCaseIsNotItalic() {
        XCTAssertTrue(html("use my_snake_case_name here").contains("my_snake_case_name"))
        XCTAssertFalse(html("use my_snake_case_name here").contains("<em>"))
    }

    func testRawHTMLIsEscaped() {
        let out = html("<script>alert(1)</script> & more")
        XCTAssertFalse(out.contains("<script>"), out)
        XCTAssertTrue(out.contains("&lt;script&gt;"), out)
        XCTAssertTrue(out.contains("&amp; more"), out)
    }

    func testListsNestedAndOrdered() {
        let out = html("- one\n- two\n  - nested\n- three\n\n1. a\n2. b\n")
        XCTAssertTrue(out.contains("<ul>\n<li>one</li>"), out)
        XCTAssertTrue(out.contains("<li>two\n<ul>"), out)
        XCTAssertTrue(out.contains("<li>nested</li>"), out)
        XCTAssertTrue(out.contains("<ol>\n<li>a</li>\n<li>b</li>"), out)
    }

    func testFencedCodeQuotesRulesAndTables() {
        let out = html("```\nlet x = a < b\n```\n\n> quoted\n\n---\n\n| a | b |\n|---|---|\n| 1 | 2 |\n")
        XCTAssertTrue(out.contains("<pre><code>let x = a &lt; b"), out)
        XCTAssertTrue(out.contains("<blockquote>"), out)
        XCTAssertTrue(out.contains("<hr />"), out)
        XCTAssertTrue(out.contains("<th>a</th>"), out)
        XCTAssertTrue(out.contains("<td>2</td>"), out)
    }

    func testOutputIsWellFormedXMLSoEPUBReadersAcceptIt() {
        let md = "# T\n\ntext with <b> & \"quotes\"\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n![alt](pic.png)\n\nline  \nbreak\n"
        let xml = "<body>\(html(md))</body>"
        let parser = XMLParser(data: Data(xml.utf8))
        XCTAssertTrue(parser.parse(), "\(parser.parserError?.localizedDescription ?? "")\n\(xml)")
    }

    // MARK: HTML → Markdown

    func testHTMLToMarkdownBasics() {
        let md = HTMLToMarkdown.convert("""
        <html><head><title>x</title><style>p {color: red}</style></head><body>
        <h2>Sub</h2><p>Hello <b>bold</b> and <i>it</i> <a href="https://a.b/c">link</a>.</p>
        <ul><li>one</li><li>two</li></ul><ol><li>a</li><li>b</li></ol>
        <blockquote><p>quote</p></blockquote><hr><pre>code &lt;x&gt;</pre>
        <table><tr><th>H1</th><th>H2</th></tr><tr><td>1</td><td>2</td></tr></table>
        </body></html>
        """)
        XCTAssertTrue(md.contains("## Sub"), md)
        XCTAssertTrue(md.contains("Hello **bold** and *it* [link](https://a.b/c)."), md)
        XCTAssertTrue(md.contains("- one\n- two"), md)
        XCTAssertTrue(md.contains("1. a\n2. b"), md)
        XCTAssertTrue(md.contains("> quote"), md)
        XCTAssertTrue(md.contains("---"), md)
        XCTAssertTrue(md.contains("```\ncode <x>\n```"), md)
        XCTAssertTrue(md.contains("| H1 | H2 |\n| --- | --- |\n| 1 | 2 |"), md)
        XCTAssertFalse(md.contains("color: red"), md)
        XCTAssertFalse(md.contains("<p>") || md.contains("<b>") || md.contains("<li>"), md)
    }

    func testTextutilStyleHeadingsAreDetectedByFontSize() {
        let md = HTMLToMarkdown.convert("""
        <html><head><style>
        p.p1 {margin: 0.0px; font: 28.0px Helvetica}
        p.p2 {margin: 0.0px; font: 12.0px Helvetica}
        p.p3 {margin: 0.0px; font: 18.0px Helvetica}
        </style></head><body>
        <p class="p1"><b>Big Title</b></p>
        <p class="p2">Body text goes here and is long enough to be the common size in this document.</p>
        <p class="p3">Smaller heading</p>
        <p class="p2">More body text that keeps twelve pixels the dominant size by character count.</p>
        </body></html>
        """)
        XCTAssertTrue(md.hasPrefix("# **Big Title**") || md.hasPrefix("# Big Title"), md)
        XCTAssertTrue(md.contains("## Smaller heading"), md)
        XCTAssertTrue(md.contains("Body text goes here"), md)
    }

    func testEmphasisMarkersNeverSwallowSpacesOrEmptyPairs() {
        XCTAssertEqual(HTMLToMarkdown.convert("<p>a <b>bold </b>b</p>"), "a **bold** b\n")
        XCTAssertEqual(HTMLToMarkdown.convert("<p>x<b></b>y</p>"), "xy\n")
        XCTAssertEqual(HTMLToMarkdown.convert("<p>2 * 3 = 6 and snake_case</p>"), "2 \\* 3 = 6 and snake\\_case\n")
    }

    func testEntitiesAndTokenizer() {
        XCTAssertEqual(HTML.decodeEntities("Tom &amp; Jerry &lt;3 &#8212; &#x2014; &copy; &unknown; &"), "Tom & Jerry <3 — — © &unknown; &")
        XCTAssertEqual(HTML.attribute("href", in: " class=\"x\" HREF='a&amp;b' "), "a&b")
        let tokens = HTML.tokenize("<p class=a>Hi<br>there</p><!-- c --><img src=x />")
        XCTAssertEqual(tokens.count, 6)
        XCTAssertEqual(tokens[0], .open(name: "p", attrs: " class=a", selfClosing: false))
        XCTAssertEqual(tokens[1], .text("Hi"))
    }

    func testTextReflowDehyphenatesLineBreaks() {
        XCTAssertEqual(HTML.textToMarkdown("Hello wor-\nld and\nmore\n\nNext"), "Hello world and more\n\nNext\n")
        XCTAssertEqual(HTML.textToBody("a & b\nc\n\n\nd"), "<p>a &amp; b<br />\nc</p>\n<p>d</p>\n")
    }
}
