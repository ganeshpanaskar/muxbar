import Foundation

/// Finds the web link under a click in a terminal screen. Rows hold one Character per cell, so a
/// column is an index. A link that runs to the right edge continues on the next row (after its
/// indentation): Claude Code and other full-screen apps wrap long URLs that way.
public enum LinkFinder {
    static let url = try! NSRegularExpression(pattern: #"https?://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#)
    /// Frame characters that border text in boxes; never part of a link.
    static let frame: Set<Character> = ["│", "┃", "║", "╎", "▏", "▎"]

    public static func link(atColumn col: Int, row: Int, rows: [String]) -> String? {
        guard rows.indices.contains(row) else { return nil }
        let cells = rows.map { Array($0) }
        let width = cells.map(\.count).max() ?? 0
        func isText(_ c: Character) -> Bool { !c.isWhitespace && c != "\u{0}" && !frame.contains(c) }
        let line = cells[row]
        guard line.indices.contains(col), isText(line[col]) else { return nil }
        // The word under the click.
        var a = col, b = col
        while a > 0, isText(line[a - 1]) { a -= 1 }
        while b + 1 < line.count, isText(line[b + 1]) { b += 1 }
        var pieces = [(row: row, start: a, end: b)]
        func firstWord(_ r: Int) -> (Int, Int)? {
            let l = cells[r]
            guard let s = l.firstIndex(where: isText) else { return nil }
            var e = s
            while e + 1 < l.count, isText(l[e + 1]) { e += 1 }
            return (s, e)
        }
        func lastWord(_ r: Int) -> (Int, Int)? {
            let l = cells[r]
            guard let e = l.lastIndex(where: isText) else { return nil }
            var s = e
            while s > 0, isText(l[s - 1]) { s -= 1 }
            return (s, e)
        }
        func touchesEdge(_ r: Int, _ end: Int) -> Bool {
            // Nothing but frame characters or spaces after it, and it reaches (nearly) the edge.
            end >= width - 3 || cells[r][(end + 1)...].allSatisfy { !isText($0) } && end >= cells[r].count - 3
        }
        // Back: this word starts its row and the row above ends at the edge (a link wrapped onto
        // this row): go up until the piece with the link's start.
        func piece(_ p: (row: Int, start: Int, end: Int)) -> String { String(cells[p.row][p.start...p.end]) }
        var r = row
        while r > 0, pieces.count < 8, !piece(pieces[0]).contains("://"), pieces[0].start == firstWord(r)?.0,
              let (s, e) = lastWord(r - 1), touchesEdge(r - 1, e) {
            pieces.insert((r - 1, s, e), at: 0); r -= 1
        }
        // Forward: the last piece reaches the edge; the next row's first word continues it.
        r = pieces.last!.row
        while r + 1 < cells.count, pieces.count < 12, touchesEdge(r, pieces.last!.end), let (s, e) = firstWord(r + 1) {
            pieces.append((r + 1, s, e)); r += 1
        }
        var text = "", clicked = 0
        for p in pieces {
            if p.row == row { clicked = text.count + (col - p.start) }
            text += piece(p)
        }
        // The link that covers the clicked cell (not just any link in the joined words).
        let ns = text as NSString
        for m in url.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let range = Range(m.range, in: text) else { continue }
            let link = trimmed(String(text[range]))
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            if clicked >= start && clicked < start + link.count { return link }
        }
        return nil
    }

    /// Drops sentence punctuation after a link, and closing brackets it didn't open.
    static func trimmed(_ s: String) -> String {
        var s = s
        while let c = s.last {
            if ".,;:!?'\"".contains(c) { s.removeLast(); continue }
            let pairs: [Character: Character] = [")": "(", "]": "[", "}": "{"]
            if let open = pairs[c], s.filter({ $0 == c }).count > s.filter({ $0 == open }).count { s.removeLast(); continue }
            break
        }
        return s
    }
}
