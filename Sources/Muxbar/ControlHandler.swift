import AppKit
import MuxbarCore

/// Maps control-socket requests onto SessionStore. Kept thin: no logic the UI doesn't also use.
@MainActor
enum ControlHandler {
    static func handle(_ store: SessionStore, _ req: [String: Any]) async -> [String: Any] {
        let cmd = req["cmd"] as? String ?? ""
        let a = req["args"] as? [String: Any] ?? [:]
        func str(_ k: String) -> String? { a[k] as? String }
        func need(_ k: String) throws -> String {
            guard let v = str(k), !v.isEmpty else { throw StoreError("missing --\(k)") }
            return v
        }
        do {
            switch cmd {
            case "hosts":
                return ok(store.state.hosts.map(hostJSON(store)))
            case "available-hosts":
                return ok(store.availableSSHHosts())
            case "hosts-add":
                store.addHost(try need("host"))
                return ok("added")
            case "hosts-remove":
                store.removeHost(try need("host"))
                return ok("removed")
            case "refresh":
                if let h = str("host") { await store.refresh(host: h) } else {
                    for h in store.state.hosts { await store.refresh(host: h) }
                }
                return ok(store.state.hosts.map(hostJSON(store)))
            case "probe":
                let h = try need("host")
                guard store.state.hosts.contains(h) else { throw StoreError("Unknown host \(h); add it with hosts-add") }
                await store.refresh(host: h)
                return ok(hostJSON(store)(h))
            case "list":
                let hosts = str("host").map { [$0] } ?? store.state.hosts
                return ok(hosts.flatMap { store.sessions(for: $0) }.map(sessionJSON(store)))
            case "new":
                let g = str("group").flatMap { $0.isEmpty ? nil : $0 }
                let rec = try await store.newSession(host: try need("host"), dir: str("dir") ?? "",
                                                     name: try need("name"), command: str("cmd"), group: g,
                                                     attach: a["no-attach"] as? Bool != true)
                return ok(sessionJSON(store)(store.state.sessions[rec.key] ?? rec))
            case "type":
                // Test hook: types into a session's built-in pane exactly as a user would at the
                // keyboard (Muxbar itself never types into panes).
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                guard let pane = store.embedded.session(rec.key), pane.isRunning else { throw StoreError("No running pane for \(rec.name)") }
                pane.view.send(txt: try need("text") + (a["no-enter"] as? Bool == true ? "" : "\r"))
                return ok("typed")
            case "rename":
                let h = try need("host")
                let rec = try store.resolve(host: h, ref: try need("id"))
                return ok(sessionJSON(store)(try await store.rename(key: rec.key, to: try need("name"))))
            case "focus":
                let h = try need("host")
                let rec = try store.resolve(host: h, ref: try need("id"))
                return ok(try await store.focus(key: rec.key).rawValue)
            case "kill":
                let h = try need("host")
                let rec = try store.resolve(host: h, ref: try need("id"))
                guard a["yes"] as? Bool == true else {
                    throw StoreError("Refusing to kill \(rec.name) on \(h) without --yes")
                }
                try await store.kill(key: rec.key)
                return ok("killed \(rec.name) on \(h)")
            case "status":
                let h = try need("host")
                let rec = try store.resolve(host: h, ref: try need("id"))
                return ok(sessionJSON(store)(rec))
            case "dismiss-ended":
                store.dismissEnded(host: str("host"))
                return ok("dismissed")
            case "settings":
                return ok(settingsJSON(store.settings))
            case "workspace-root":
                let h = try need("host")
                return ok(store.workspaceRoot(h))
            case "settings-set":
                var err: String?
                store.updateSettings { s in
                    if let t = a["terminal"] as? String {
                        if let k = TerminalKind(rawValue: t) { s.terminal = k } else { err = "terminal must be embedded|terminal|iterm" }
                    }
                    if let f = a["ssh-config"] as? String { s.sshConfigFile = f.isEmpty ? nil : f }
                if let h = a["root-host"] as? String, let r = a["root"] as? String { s.workspaceRoots[h] = r.isEmpty ? nil : r }
                    if let c = a["default-command"] as? String { s.defaultCommand = c.trimmingCharacters(in: .whitespaces) }   // empty = plain shell
                    if let d = a["disable-local-tmux"] as? String { s.disableLocalTmux = (d == "true" || d == "1") }
                }
                if let err { throw StoreError(err) }
                return ok(settingsJSON(store.settings))
            case "tabs":
                return ok(try store.terminalTabs().map { t -> [String: Any] in
                    ["kind": t.kind.rawValue, "windowID": t.windowID ?? -1, "tty": t.tty ?? "",
                     "itermSessionID": t.itermSessionID ?? "", "title": t.title]
                })
            case "simulate-sleep":
                store.handleSleep()
                return ok(pollingJSON(store))
            case "simulate-wake":
                store.handleWake()
                return ok(pollingJSON(store))
            case "polling":
                return ok(pollingJSON(store))
            case "info":
                return ok(["banner": store.banner ?? "", "stateFile": store.stateFile,
                           "automationDenied": store.automationDenied,
                           "bundle": Bundle.main.bundlePath, "pid": ProcessInfo.processInfo.processIdentifier])
            case "resume-ended":
                let h = try need("host"), ref = try need("id")
                guard let rec = store.state.sessions.values.first(where: { $0.host == h && $0.ended && ($0.name == ref || $0.tmuxID == ref || $0.key == ref) })
                else { throw StoreError("No ended session '\(ref)' on \(h)") }
                return ok(sessionJSON(store)(try await store.resumeEnded(key: rec.key)))
            case "restore-state":
                return ok(["openPanes": store.state.openPanes.compactMap { store.state.sessions[$0]?.name },
                           "lastSelected": store.state.lastSelected.flatMap { store.state.sessions[$0]?.name } ?? ""])
            case "scroll":
                // Test hook: --lines N (positive = back), or --to POSITION (0 = live); reports info.
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                if let l = str("lines").flatMap(Int.init) { store.scrollPane(rec.key, lines: l) }
                if let t = str("to").flatMap(Int.init) { store.scrollPane(rec.key, toPosition: t) }
                try? await Task.sleep(nanoseconds: 900_000_000)
                await store.refreshScrollInfo(rec.key)
                let i = store.scrollInfo[rec.key]
                return ok(["history": i?.history ?? -1, "position": i?.position ?? -1, "inMode": i?.inMode ?? false,
                           "atLive": i?.atLive ?? true])
            case "waiting":
                return ok(store.waitingSessions.map { r -> [String: Any] in
                    ["name": r.name, "host": r.host, "location": store.location(of: r),
                     "since": store.waitingSince[r.key].map { Int($0.timeIntervalSince1970) } ?? 0]
                })
            case "next-waiting":
                guard let r = try await store.focusNextWaiting() else { return ok("") }
                return ok(r.name)
            case "groups":
                let hosts = str("host").map { [$0] } ?? store.state.hosts
                return ok(hosts.flatMap { h in store.state.groups(for: h).map { g -> [String: Any] in
                    ["host": h, "group": g, "sessions": store.sessions(inGroup: g, host: h).map(\.name),
                     "waiting": store.waitingCount(group: g, host: h)]
                } })
            case "group-create":
                return ok(try store.createGroup(host: try need("host"), try need("name")))
            case "group-rename":
                try await store.renameGroup(host: try need("host"), try need("name"), to: try need("to"))
                return ok("renamed")
            case "group-delete":
                try await store.deleteGroup(host: try need("host"), try need("name"))
                return ok("deleted")
            case "group-set":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                let g = str("group") ?? ""
                try await store.setGroup(key: rec.key, group: g.isEmpty ? nil : g)
                return ok(sessionJSON(store)(store.state.sessions[rec.key] ?? rec))
            case "conversations":
                let list = try await store.conversations(host: try need("host"), limit: Int(str("limit") ?? "") ?? 40)
                return ok(list.map { c -> [String: Any] in
                    ["agent": c.agent, "id": c.id, "cwd": c.cwd ?? "", "prompt": c.firstPrompt ?? "", "modified": c.modified]
                })
            case "resume":
                // --dir given: start directly from folder + session id (like the dialog's fields).
                // Otherwise look the id up among the host's conversations to find its folder.
                let h = try need("host"), cid = try need("id")
                guard Conversations.isValidSessionID(cid) else { throw StoreError("'\(cid)' isn't a valid session id") }
                let c: Conversation
                if let dir = str("dir"), !dir.isEmpty {
                    let agent = str("agent") ?? store.settings.defaultAgent?.id ?? AgentProfile.claude.id
                    guard store.settings.agent(id: agent) != nil else { throw StoreError("Unknown agent '\(agent)'") }
                    c = Conversation(agent: agent, id: cid, cwd: dir, firstPrompt: nil, modified: 0)
                } else {
                    let list = try await store.conversations(host: h, limit: 200)
                    guard let found = list.first(where: { $0.id == cid }) else { throw StoreError("No conversation \(cid) on \(h); pass --dir (and --agent) to start it anyway") }
                    c = found
                }
                return ok(sessionJSON(store)(try await store.resume(host: h, conversation: c, name: str("name"), group: str("group"))))
            case "embedded":
                // Built-in panes: which sessions have one, and whether its process is running.
                return ok(store.embedded.sessions.values.map { e -> [String: Any] in
                    ["key": e.key, "name": store.state.sessions[e.key]?.name ?? "",
                     "state": e.isRunning ? "running" : "exited", "pid": Int(e.pid), "starts": e.starts]
                }.sorted { ($0["name"] as! String) < ($1["name"] as! String) })
            case "open-window":
                // Test hook: open the New Session or Continue window.
                guard let id = str("id"), ["new", "continue", "settings"].contains(id) else { throw StoreError("--id new|continue|settings") }
                if id == "settings" { activateApp(); WindowOpener.openSettings?() } else { WindowOpener.open?(id) }
                return ok("opened \(id)")
            case "window":
                // Test hook: report or close the main window (exercises the reopen path).
                let w = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
                if str("action") == "close" { w?.close(); return ok("closed") }
                return ok(w?.isVisible == true ? "open" : "closed")
            case "glyph":
                // Test hook: export the menu-bar glyph at an animation phase (0…1) as a 4x PNG.
                let img = str("phase").flatMap(Double.init).map { MenuGlyph.image(phase: $0) } ?? MenuGlyph.waitingStatic()
                let out = try need("out")
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8,
                                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 72, height: 72).fill()
                img.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
                return ok(out)
            case "check-updates":
                // Test hook: --latest TAG simulates the newest release; --apply acts on it
                // (auto-update / popup) — without it, only the decision is reported.
                let sim = str("latest").flatMap { t in SemVer(t).map { ReleaseInfo(tag: t, version: $0, notes: "Simulated release", url: "https://github.com/\(Updates.repo)/releases") } }
                let apply = a["apply"] as? Bool == true
                let d = await Updater.shared.check(manual: sim == nil && apply, simulated: sim, apply: apply)
                let decision: String
                switch d {
                case .upToDate: decision = "up-to-date"
                case .automatic(let r): decision = "automatic \(r.tag)"
                case .askFirst(let r): decision = "ask-first \(r.tag)"
                }
                return ok(["current": Updater.currentVersion.description, "decision": decision, "status": Updater.shared.lastResult])
            case "branding":
                // Test hook: which Dock icon is active and whether the menu-bar glyph animates.
                let dark = AppIconController.shared.isDark
                return ok(["dark": dark, "dockIcon": dark ? "AppIcon-dark (C8)" : "AppIcon-light (C2)",
                           "menuGlyphAnimating": MenuGlyphState.shared.animator?.animating ?? false,
                           "waitingSessions": store.state.sessions.values.filter { store.status(of: $0) == .waiting }.map(\.name),
                           "dockBadge": NSApp.dockTile.badgeLabel ?? "",
                           "notified": Attention.shared.notified])
            case "selected":
                return ok(store.selectedKey.flatMap { store.state.sessions[$0]?.name } ?? "")
            case "snapshot":
                // Renders the menu-bar session list to PNG (no Screen Recording permission needed).
                let out = try need("out")
                switch str("what") {
                case "window": try Snapshot.renderMainWindow(to: out)
                case "new", "continue": try Snapshot.renderMainWindow(to: out, id: str("what")!)
                case "settings": try Snapshot.renderMainWindow(to: out, id: "com_apple_SwiftUI_Settings")
                case "popover": try Snapshot.renderPopover(to: out)
                default: try Snapshot.render(store: store, to: out)
                }
                return ok(out)
            case "quit":
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
                return ok("quitting")
            default:
                throw StoreError("unknown command '\(cmd)'")
            }
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    static func ok(_ v: Any) -> [String: Any] { ["ok": true, "result": v] }

    static func hostJSON(_ store: SessionStore) -> (String) -> [String: Any] {
        { h in
            let hh = store.health[h] ?? .unknown
            return ["host": h, "health": hh.label, "hint": hh.hint ?? "", "tmux": store.tmuxVersions[h] ?? "",
                    "sessions": store.sessions(for: h).filter { !$0.ended }.count,
                    "lastRefresh": store.lastRefresh[h].map { Int($0.timeIntervalSince1970) } ?? 0]
        }
    }

    static func sessionJSON(_ store: SessionStore) -> (SessionRecord) -> [String: Any] {
        { r in
            var d: [String: Any] = ["key": r.key, "host": r.host, "id": r.tmuxID ?? "", "name": r.name,
                                    "path": r.path ?? "", "status": store.status(of: r).rawValue,
                                    "ended": r.ended, "created": r.created, "lastActivity": r.lastActivity ?? 0,
                                    "attached": store.live[r.key]?.attached ?? 0,
                                    "group": r.group ?? "", "claudeSessionID": r.conversationID ?? "",
                                    "conversationID": r.conversationID ?? "", "agent": r.agent ?? "",
                                    "origin": r.isOutside ? "outside" : "muxbar"]
            if let t = r.tab {
                d["tab"] = ["kind": t.kind.rawValue, "windowID": t.windowID ?? -1, "tty": t.tty ?? "",
                            "itermSessionID": t.itermSessionID ?? ""]
            }
            return d
        }
    }

    static func settingsJSON(_ s: AppSettings) -> [String: Any] {
        ["terminal": s.terminal.rawValue, "defaultCommand": s.defaultCommand, "checkForUpdates": s.checkForUpdates,
         "agents": s.agents.map { ["id": $0.id, "name": $0.name, "command": $0.command, "resume": $0.resumeTemplate ?? ""] },
         "sshConfigFile": s.sshConfigFile ?? "", "disableLocalTmux": s.disableLocalTmux]
    }

    static func pollingJSON(_ store: SessionStore) -> [String: Any] {
        ["active": store.pollingActive, "interval": store.interval]
    }
}

/// `Muxbar --cli <command> [--key value ...] [--yes] [--no-attach] [--json]`
enum CLI {
    static let flags: Set<String> = ["yes", "no-attach", "json", "no-enter", "dry-run", "apply"]

    static func run(_ argv: [String]) -> Int32 {
        guard let cmd = argv.first else {
            FileHandle.standardError.write(Data(usage.utf8))
            return 2
        }
        var args: [String: Any] = [:]
        var json = false
        var i = 1
        while i < argv.count {
            let k = argv[i]
            guard k.hasPrefix("--") else {
                FileHandle.standardError.write(Data("unexpected argument \(k)\n".utf8)); return 2
            }
            let key = String(k.dropFirst(2))
            if flags.contains(key) {
                if key == "json" { json = true } else { args[key] = true }
                i += 1
            } else {
                guard i + 1 < argv.count else {
                    FileHandle.standardError.write(Data("missing value for \(k)\n".utf8)); return 2
                }
                args[key] = argv[i + 1]
                i += 2
            }
        }
        do {
            let resp = try ControlClient.send(["cmd": cmd, "args": args])
            if json {
                let d = try JSONSerialization.data(withJSONObject: resp, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: d, as: UTF8.self))
            } else {
                printHuman(cmd, resp)
            }
            if resp["ok"] as? Bool == true { return 0 }
            FileHandle.standardError.write(Data("error: \(resp["error"] as? String ?? "unknown")\n".utf8))
            return 1
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            return 3
        }
    }

    static func printHuman(_ cmd: String, _ resp: [String: Any]) {
        guard resp["ok"] as? Bool == true else { return }
        let r = resp["result"]
        if cmd == "list", let rows = r as? [[String: Any]] {
            for s in rows {
                print([s["host"], s["id"], s["status"], s["name"], s["path"]]
                    .map { "\($0 ?? "")" }.joined(separator: "\t"))
            }
        } else if let rows = r as? [[String: Any]] {
            for row in rows { print(row.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
        } else if let d = r as? [String: Any] {
            print(d.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        } else if let s = r {
            print("\(s)")
        }
    }

    static let usage = """
    usage: Muxbar --cli <command> [--key value ...] [--json]
      hosts | available-hosts | hosts-add --host H | hosts-remove --host H
      list [--host H] | probe --host H | refresh [--host H]
      new --host H --name N [--dir D] [--cmd C] [--group G] [--no-attach]   (no --cmd = plain shell)
      type --host H --id ID --text T [--no-enter]   (test hook: keystrokes into the built-in pane)
      groups [--host H] | group-create --host H --name G | group-rename --host H --name G --to G2
      group-delete --host H --name G | group-set --host H --id ID --group G  (empty --group = ungroup)
      Groups belong to one host; a session can only join a group on its own host.
      conversations --host H [--limit N] | resume --host H --id SESSION_ID [--dir D [--agent claude|codex|gemini|…]] [--name N] [--group G]
      rename --host H --id ID --name N | focus --host H --id ID
      kill --host H --id ID --yes | status --host H --id ID | dismiss-ended [--host H]
      workspace-root --host H | settings-set --root-host H --root PATH (empty = default)
      settings | settings-set [--terminal embedded|terminal|iterm] [--ssh-config PATH] [--default-command C]  (empty = plain shell)
      scroll --host H --id ID [--lines N | --to POS] | type … then check atLive
      waiting | next-waiting   (⌘J) | resume-ended --host H --id NAME | restore-state
      check-updates [--latest TAG] [--apply]   (no --apply = only report the decision)
      embedded | selected | window [--action close] | tabs | polling | simulate-sleep | simulate-wake | info | snapshot --out PNG [--what window] | quit
    ID may be a tmux id ($3), an exact session name, or a record key.

    """
}
