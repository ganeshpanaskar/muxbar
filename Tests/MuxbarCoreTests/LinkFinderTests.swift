import Testing
@testable import MuxbarCore

private func pad(_ rows: [String], _ w: Int = 40) -> [String] { rows.map { $0 + String(repeating: " ", count: max(0, w - $0.count)) } }

@Test func linkUnderTheClick() {
    let rows = pad(["see https://example.com/a?b=1. done", "no link here"])
    #expect(LinkFinder.link(atColumn: 10, row: 0, rows: rows) == "https://example.com/a?b=1")   // sentence dot dropped
    #expect(LinkFinder.link(atColumn: 1, row: 0, rows: rows) == nil)    // "see"
    #expect(LinkFinder.link(atColumn: 3, row: 0, rows: rows) == nil)    // the space
    #expect(LinkFinder.link(atColumn: 2, row: 1, rows: rows) == nil)
    #expect(LinkFinder.link(atColumn: 99, row: 0, rows: rows) == nil)
}

@Test func wrappedLinkIsJoinedFromEitherRow() {
    // 30 columns; the URL runs to the edge and continues, indented, on the next two rows.
    let rows = pad(["⏺ Doc: https://wiki.example/bi", "  n/view/Team/Some/Very/Long/P", "  age/ (open it)", "next"], 30)
    let want = "https://wiki.example/bin/view/Team/Some/Very/Long/Page/"
    #expect(LinkFinder.link(atColumn: 12, row: 0, rows: rows) == want)
    #expect(LinkFinder.link(atColumn: 5, row: 1, rows: rows) == want)
    #expect(LinkFinder.link(atColumn: 3, row: 2, rows: rows) == want)
    #expect(LinkFinder.link(atColumn: 9, row: 2, rows: rows) == nil)    // "(open"
}

@Test func linkBracketsAndFrames() {
    let rows = pad(["│ (https://x.dev/a_(b)) │", "[link](https://y.dev/p)", "ftp://nope.dev x"], 40)
    #expect(LinkFinder.link(atColumn: 8, row: 0, rows: rows) == "https://x.dev/a_(b)")
    #expect(LinkFinder.link(atColumn: 12, row: 1, rows: rows) == "https://y.dev/p")
    #expect(LinkFinder.link(atColumn: 2, row: 2, rows: rows) == nil)    // web links only
}
