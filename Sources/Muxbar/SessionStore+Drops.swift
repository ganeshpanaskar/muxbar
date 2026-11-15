import AppKit
import MuxbarCore

/// F5: files and screenshots dropped on a pane become paths typed into it (not submitted). Remote
/// sessions get the file copied to their host first, so the agent there can read it.
extension SessionStore {
    static let confirmAboveBytes = 100 * 1024 * 1024
    static let progressAboveBytes = 5 * 1024 * 1024

    struct DropError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Copies (remote) and pastes. Returns the pasted paths. `confirmed` must be true above 100 MB.
    @discardableResult
    func drop(_ key: String, files: [URL], confirmed: Bool = false) async throws -> [String] {
        guard let rec = state.sessions[key], !rec.ended else { throw StoreError("Session not found or ended") }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        for f in files where fm.fileExists(atPath: f.path, isDirectory: &isDir) && isDir.boolValue {
            throw DropError(message: "Drop files, not folders (\(f.lastPathComponent) is a folder)")
        }
        let sizes = files.map { ((try? fm.attributesOfItem(atPath: $0.path)[.size]) as? Int) ?? 0 }
        let total = sizes.reduce(0, +)
        if let bad = files.first(where: { DropNaming.unsafeToPaste($0.path) }) {
            throw DropError(message: "\(bad.lastPathComponent.debugDescription) has control characters in its path; rename it first")
        }
        // Only copying is slow: a local drop just pastes the path, whatever the size.
        if rec.host != localHost && total > Self.confirmAboveBytes && !confirmed {
            throw DropError(message: "That's \(formatKB(total / 1024)); confirm to copy it to \(hostLabel(rec.host))")
        }
        var paths: [String] = []
        if rec.host == localHost {
            paths = files.map(\.path)
        } else {
            if total > Self.progressAboveBytes { dropProgress = "Copying \(formatKB(total / 1024)) to \(hostLabel(rec.host))…" }
            defer { dropProgress = nil }
            let now = Date()
            for (i, f) in files.enumerated() {
                let data = try Data(contentsOf: f)
                let name = DropNaming.remoteName(original: f.lastPathComponent, date: now, unique: files.count > 1 ? "\(i + 1)" : nil)
                let r = await runner().run(host: rec.host, script: DropNaming.uploadScript(dir: DropNaming.remoteDir(date: now), name: name),
                                           timeout: max(30, Double(data.count) / 1_000_000), stdin: data)
                guard r.ok, let up = DropNaming.parseUpload(r.stdout), up.bytes == data.count else {
                    let msg = cleanSSHStderr(r.stderr)
                    throw DropError(message: "Couldn't copy \(f.lastPathComponent) to \(hostLabel(rec.host))\(msg.isEmpty ? "" : ": " + msg)")
                }
                paths.append(up.path)
            }
        }
        try await paste(key, text: DropNaming.pasteText(paths))
        Log.info("dropped \(files.count) file(s) into \(rec.name) on \(rec.host): \(paths.joined(separator: " "))")
        return paths
    }

    /// Types `text` into the session's pane as a paste: bracketed if the app asked for it, never
    /// submitted.
    func paste(_ key: String, text: String) async throws {
        guard let rec = state.sessions[key] else { throw StoreError("Session not found") }
        if rec.tmuxID != nil {
            if agentPane(rec) == nil { await refresh(host: rec.host) }
            guard let pane = agentPane(rec)?.pane else { throw StoreError("Can't find \(rec.name)'s pane") }
            let tmux = try tmuxPath(rec.host)
            _ = try await runTmux(host: rec.host, "\(tmux) set-buffer -b muxbar-drop -- \(shellQuote(text)) && "
                                    + "\(tmux) paste-buffer -p -d -b muxbar-drop -t \(shellQuote(pane))")
        } else if let pane = embedded.session(key), pane.isRunning {
            pane.view.send(txt: DropNaming.pasteBytes(text, bracketed: pane.view.getTerminal().bracketedPasteMode))
        } else {
            throw StoreError("\(rec.name) has no open pane to paste into")
        }
    }

    /// Edit → Paste Image to Session (⌘⇧V): the clipboard image, as a PNG file, dropped in.
    func pasteClipboardImage(_ key: String) async throws {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            try await drop(key, files: urls)
            return
        }
        guard let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw StoreError("The clipboard has no image")
        }
        try await drop(key, files: [try Self.writeTempPNG(png, name: "clipboard.png")])
    }

    static func writeTempPNG(_ data: Data, name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-drops", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(name)")
        try data.write(to: url)
        return url
    }
}
