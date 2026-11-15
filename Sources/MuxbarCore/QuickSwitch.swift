import Foundation

/// ⌘K quick switcher (F7): fuzzy matching and ranking of sessions and a few commands.
public enum QuickSwitch {
    public struct Item: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case session, command }
        public var id: String            // session key, or a command id
        public var kind: Kind
        public var title: String         // session name or command title
        public var group: String?
        public var host: String          // host label ("This Mac", "devbox")
        public var folder: String?
        public var prompt: String?       // the conversation's first prompt, when known
        public var needsYou: Bool
        public var waitingSince: Int?
        public var unread: Bool
        public var finishedAt: Int?
        public var lastViewed: Int?

        public init(id: String, kind: Kind = .session, title: String, group: String? = nil, host: String = "",
                    folder: String? = nil, prompt: String? = nil, needsYou: Bool = false, waitingSince: Int? = nil,
                    unread: Bool = false, finishedAt: Int? = nil, lastViewed: Int? = nil) {
            self.id = id; self.kind = kind; self.title = title; self.group = group; self.host = host
            self.folder = folder; self.prompt = prompt; self.needsYou = needsYou; self.waitingSince = waitingSince
            self.unread = unread; self.finishedAt = finishedAt; self.lastViewed = lastViewed
        }
    }

    public struct Row: Equatable, Sendable {
        public var item: Item
        public var score: Int
        /// "Needs you", "Finished", "Recent" (empty query), "Sessions" or "Commands".
        public var section: String
    }

    public static let emptyLimit = 9

    static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased())
    }

    static func isWordStart(_ t: [Character], _ i: Int) -> Bool {
        i == 0 || !(t[i - 1].isLetter || t[i - 1].isNumber)
    }

    /// How well one query word matches `text` (nil = not at all). Exact 1000 > prefix 800 >
    /// substring at a word start 600 > substring 400 > subsequence (up to 300, more for word
    /// starts and consecutive characters). Case- and diacritic-insensitive.
    public static func score(query: String, text: String) -> Int? {
        let q = fold(query.trimmingCharacters(in: .whitespaces)), t = fold(text)
        guard !q.isEmpty else { return 0 }
        guard q.count <= t.count else { return nil }
        if q == t { return 1000 }
        if t.starts(with: q) { return 800 + max(0, 40 - (t.count - q.count)) }
        var best: Int?
        if q.count <= t.count {
            for i in 0...(t.count - q.count) where t[i] == q[0] && Array(t[i..<(i + q.count)]) == q {
                let s = (isWordStart(t, i) ? 600 : 400) - min(i, 30)
                best = max(best ?? 0, s)
                if isWordStart(t, i) { break }
            }
        }
        if let best { return best }
        // Subsequence: every query character in order.
        var ti = 0, s = 0, prev = -2
        for qc in q {
            while ti < t.count && t[ti] != qc { ti += 1 }
            guard ti < t.count else { return nil }
            var c = 10
            if ti == prev + 1 { c += 15 }
            if isWordStart(t, ti) { c += 20 }
            s += c
            prev = ti
            ti += 1
        }
        return min(300, s)
    }

    /// The item's match for a whole query: every word must match some field (weighted by field).
    public static func match(_ item: Item, query: String) -> Int? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return 0 }
        let fields: [(String?, Double)] = [(item.title, 1.0), (item.group, 0.9), (item.host, 0.7),
                                           (item.folder.map { ($0 as NSString).lastPathComponent }, 0.6),
                                           (item.folder, 0.4), (item.prompt, 0.5)]
        var total = 0
        for w in words {
            var best: Int?
            for (text, weight) in fields {
                guard let text, !text.isEmpty, let s = score(query: w, text: text) else { continue }
                best = max(best ?? 0, Int(Double(s) * weight))
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    /// Ranked rows. Empty query: Needs you (longest waiting first), Finished (newest first), then
    /// Recent (last viewed), sessions only, at most `emptyLimit`. Otherwise matches plus boosts
    /// (needs you > unread > recently viewed), ties by recency then name.
    public static func rank(_ items: [Item], query: String, now: Int) -> [Row] {
        let sessions = items.filter { $0.kind == .session }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let waiting = sessions.filter(\.needsYou).sorted { ($0.waitingSince ?? now, $0.title) < ($1.waitingSince ?? now, $1.title) }
            let finished = sessions.filter { !$0.needsYou && $0.unread }
                .sorted { ($0.finishedAt ?? 0, $1.title) > ($1.finishedAt ?? 0, $0.title) }
            let rest = sessions.filter { !$0.needsYou && !$0.unread }
                .sorted { ($0.lastViewed ?? 0, $1.title) > ($1.lastViewed ?? 0, $0.title) }
            let rows = waiting.map { Row(item: $0, score: 0, section: "Needs you") }
                + finished.map { Row(item: $0, score: 0, section: "Finished") }
                + rest.map { Row(item: $0, score: 0, section: "Recent") }
            return Array(rows.prefix(emptyLimit))
        }
        var rows: [Row] = []
        for it in items {
            guard let m = match(it, query: query) else { continue }
            var s = m
            if it.kind == .session {
                if it.needsYou { s += 250 } else if it.unread { s += 150 }
                if let v = it.lastViewed { s += now - v < 3600 ? 100 : (now - v < 86400 ? 50 : 0) }
            }
            rows.append(Row(item: it, score: s, section: it.kind == .session ? "Sessions" : "Commands"))
        }
        return rows.sorted {
            ($0.score, $0.item.lastViewed ?? 0, $1.item.title) > ($1.score, $1.item.lastViewed ?? 0, $0.item.title)
        }
    }
}

/// Grid view (F10): 2 side by side, 3–4 as 2×2, 5–6 as 3×2.
public enum GridLayout {
    public static let maxTiles = 6

    public static func columns(_ n: Int) -> Int { n <= 2 ? max(1, n) : (n <= 4 ? 2 : 3) }

    public enum Direction: String, Sendable { case left, right, up, down }

    /// The tile next to `i` in direction `d` (itself at an edge).
    public static func neighbor(of i: Int, count n: Int, _ d: Direction) -> Int {
        guard n > 0, i >= 0, i < n else { return 0 }
        let c = columns(n), col = i % c
        switch d {
        case .left: return col > 0 ? i - 1 : i
        case .right: return col < c - 1 && i + 1 < n ? i + 1 : i
        case .up: return i - c >= 0 ? i - c : i
        case .down: return i + c < n ? i + c : i
        }
    }
}
