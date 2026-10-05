import Foundation

/// Per-host workspace folders: `<root>/<group>/<session>` (or `<root>/<session>` ungrouped).
/// Muxbar only ever creates or moves folders it created itself, never deletes contents, and
/// refuses to overwrite an existing folder.
public enum Workspace {
    public static let defaultLocalRoot = "~/muxbar-sessions"
    public static let defaultRemoteRoot = "~/muxbar-sessions"

    /// A group/session name as a single safe path component.
    public static func folderName(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for bad in ["/", ":", "\0", "\n", "\r", "\t"] { s = s.replacingOccurrences(of: bad, with: "-") }
        while s.hasPrefix(".") { s.removeFirst() }
        return s.isEmpty ? "untitled" : String(s.prefix(80))
    }

    public static func path(root: String, group: String?, session: String) -> String {
        var r = root.trimmingCharacters(in: .whitespacesAndNewlines)
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        if let g = group, !g.isEmpty { return "\(r)/\(folderName(g))/\(folderName(session))" }
        return "\(r)/\(folderName(session))"
    }

    public static func groupPath(root: String, group: String) -> String {
        var r = root.trimmingCharacters(in: .whitespacesAndNewlines)
        while r.count > 1 && r.hasSuffix("/") { r.removeLast() }
        return "\(r)/\(folderName(group))"
    }

    public static func mkdirScript(_ path: String) -> String {
        "mkdir -p -- \(shellQuotePath(path))"
    }

    /// Moves a folder. Missing source → just creates the target. Existing target → exit 5, nothing moved.
    public static func moveScript(from: String, to: String) -> String {
        """
        F=\(shellQuotePath(from)); T=\(shellQuotePath(to))
        [ "$F" = "$T" ] && exit 0
        if [ -e "$T" ]; then echo "folder already exists: $T" >&2; exit 5; fi
        mkdir -p -- "$(dirname -- "$T")" || exit 4
        if [ -e "$F" ]; then mv -- "$F" "$T"; else mkdir -p -- "$T"; fi
        """
    }

    /// Removes a folder only if it's empty (never deletes contents).
    public static func rmdirIfEmptyScript(_ path: String) -> String {
        "rmdir -- \(shellQuotePath(path)) 2>/dev/null; true"
    }

    /// Re-roots a path that lived under `oldPrefix` (used when a group folder is renamed).
    public static func rebase(_ path: String, from oldPrefix: String, to newPrefix: String) -> String? {
        guard path == oldPrefix || path.hasPrefix(oldPrefix + "/") else { return nil }
        return newPrefix + path.dropFirst(oldPrefix.count)
    }

    /// `root=…` from `~/.muxbar/install.conf` (written by install.sh).
    public static func installRoot(conf text: String) -> String? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("root=") {
                let v = String(t.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }
}
