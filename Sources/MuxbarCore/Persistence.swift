import Foundation

public enum Persistence {
    public enum LoadOutcome: Equatable {
        case loaded
        case fresh
        case recoveredFromCorrupt(movedTo: String)
    }

    /// Loads state. A corrupt file is moved aside (never deleted) and an empty state returned.
    public static func load(path: String) -> (AppState, LoadOutcome) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return (AppState(), .fresh) }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            var state = try JSONDecoder().decode(AppState.self, from: data)
            if state.schemaVersion > AppState.currentSchema {
                throw NSError(domain: "Muxbar", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "state schema \(state.schemaVersion) is newer than this app"])
            }
            state.schemaVersion = AppState.currentSchema
            if !state.hosts.contains(localHost) { state.hosts.insert(localHost, at: 0) }
            return (state, .loaded)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let bad = path + ".bad-\(stamp)"
            try? fm.moveItem(atPath: path, toPath: bad)
            Log.error("state file unreadable (\(error)); moved to \(bad)")
            return (AppState(), .recoveredFromCorrupt(movedTo: bad))
        }
    }

    /// Atomic write: temp file + rename.
    public static func save(_ state: AppState, path: String) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(state)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Minimal file logger (N4). Every caught error goes through here.
public enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) public static var path: String? = nil

    public static func info(_ msg: String) { write("INFO", msg) }
    public static func error(_ msg: String) { write("ERROR", msg) }

    private static func write(_ level: String, _ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(msg)\n"
        lock.lock(); defer { lock.unlock() }
        guard let path else { FileHandle.standardError.write(line.data(using: .utf8)!); return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }
}
