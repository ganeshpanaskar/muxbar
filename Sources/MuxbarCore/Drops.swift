import Foundation

/// Dropping files and screenshots into sessions (F5). Remote sessions get the file copied to
/// `~/.muxbar/drops/YYYY-MM-DD/HHMMSS-<name>` on their host; the pane gets the path as pasted text.
public enum DropNaming {
    public static let root = "~/.muxbar/drops"
    /// Drops older than this are deleted from the host (only inside `root`).
    public static let keepDays = 7

    /// Safe file name: `HHMMSS-<name>` with only [A-Za-z0-9._-], at most 80 characters (the
    /// extension is kept), plus `-<unique>` when given.
    public static func remoteName(original: String, date: Date, unique: String? = nil) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        let base = (original as NSString).lastPathComponent
        var ext = (base as NSString).pathExtension
        var stem = (base as NSString).deletingPathExtension
        func clean(_ s: String) -> String {
            var out = String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "-" })
            while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
            return out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        ext = String(clean(ext).prefix(10))
        stem = clean(stem)
        if stem.isEmpty { stem = "drop" }
        let suffix = unique.map { "-" + clean($0) } ?? ""
        let room = 80 - 7 - suffix.count - (ext.isEmpty ? 0 : ext.count + 1)
        return f.string(from: date) + "-" + String(stem.prefix(max(8, room))) + suffix + (ext.isEmpty ? "" : "." + ext)
    }

    public static func remoteDir(date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return root + "/" + f.string(from: date)
    }

    /// The text pasted into the pane: paths separated by spaces, each quoted only when it needs it.
    /// No trailing newline: nothing is submitted.
    public static func pasteText(_ paths: [String]) -> String {
        paths.map { p in
            p.range(of: #"^[A-Za-z0-9._/~@+:%=,-]+$"#, options: .regularExpression) != nil ? p : shellQuote(p)
        }.joined(separator: " ") + " "
    }

    /// What a plain (non-tmux) pane receives: wrapped in bracketed-paste markers when the program
    /// asked for them, so it arrives as one paste rather than as typing.
    public static func pasteBytes(_ text: String, bracketed: Bool) -> String {
        bracketed ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
    }

    /// A path with control characters (newline, ESC, …) can't be pasted safely: ESC[201~ in a
    /// file name would end the paste early and the rest would arrive as keystrokes.
    public static func unsafeToPaste(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// Writes stdin to `<dir>/<name>` (private, atomic), then prints `MBX_DROP <absolute path> <bytes>`.
    public static func uploadScript(dir: String, name: String) -> String {
        let d = shellQuotePath(dir)
        let n = shellQuote(name)
        return """
        umask 077
        D=\(d); mkdir -p "$D" || exit 3
        cat > "$D"/\(n).part || exit 4
        mv -f "$D"/\(n).part "$D"/\(n) || exit 5
        echo "MBX_DROP $(cd "$D" && pwd -P)/\(name) $(wc -c < "$D"/\(n) | tr -d ' ')"
        """
    }

    /// Part of every status probe: drops older than `keepDays` days go, then empty day folders.
    public static let cleanupScript = """
        DR="$HOME/.muxbar/drops"
        if [ -d "$DR" ]; then find "$DR" -type f -mtime +\(keepDays) -exec rm -f {} + 2>/dev/null; find "$DR" -mindepth 1 -type d -empty -exec rmdir {} + 2>/dev/null; fi
        """

    public static func parseUpload(_ out: String) -> (path: String, bytes: Int)? {
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("MBX_DROP ") }) else { return nil }
        let rest = line.dropFirst("MBX_DROP ".count)
        guard let sp = rest.lastIndex(of: " "), let bytes = Int(rest[rest.index(after: sp)...]) else { return nil }
        return (String(rest[..<sp]), bytes)
    }
}
