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
                // Same path as Settings → Add remote host (validated; optional root).
                return ok(try store.addRemoteHost(try need("host"), root: str("root")))
            case "hosts-remove":
                let h = try need("host")
                let n = store.sessions(for: h).filter { !$0.ended }.count
                if n > 0 && a["yes"] as? Bool != true {
                    throw StoreError("\(h) has \(n) session(s); Muxbar would forget them (they keep running there). Pass --yes")
                }
                store.removeHost(h)
                return ok("removed")
            case "host-check":
                let c = try await store.checkHost(try need("host"))
                return ok(["host": c.host, "kind": c.result.kind, "ok": c.result.ok, "message": c.result.message(host: c.host)])
            case "setup-status":
                return ok(["needsSetup": store.needsSetup, "setupDone": store.settings.setupDone.map { $0 as Any } ?? NSNull(),
                           "windowOpen": store.setupWindowOpen, "hosts": store.state.hosts, "roots": store.settings.workspaceRoots])
            case "setup-apply":
                // Same as the setup window's Done (or Skip): --root, then --host/--host-root pairs in order.
                if a["skip"] as? Bool == true { store.finishSetup(); return ok("skipped") }
                let hosts = (a["host"] as? [String]) ?? str("host").map { [$0] } ?? []
                let roots = (a["host-root"] as? [String]) ?? str("host-root").map { [$0] } ?? []
                try store.applySetup(localRoot: str("root"),
                                     hosts: hosts.enumerated().map { ($0.element, $0.offset < roots.count ? roots[$0.offset] : nil) })
                return ok(["hosts": store.state.hosts, "roots": store.settings.workspaceRoots])
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
                                                     attach: a["no-attach"] as? Bool != true,
                                                     createFolder: a["create-folder"] as? Bool == true)
                return ok(sessionJSON(store)(store.state.sessions[rec.key] ?? rec))
            case "test-wheel":
                // Test hook: a trackpad-like gesture, --count wheel steps of --lines every --ms
                // milliseconds, through the same path as the wheel over the pane.
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                let lines = Int(str("lines") ?? "1") ?? 1, count = min(Int(str("count") ?? "60") ?? 60, 2000)
                let ms = UInt64(Int(str("ms") ?? "16") ?? 16)
                let t0 = Date()
                let dy = str("dy").flatMap(Double.init)   // a trackpad event's delta in points (else --lines)
                for _ in 0..<count {
                    if let dy { store.scrollWheel(rec.key, deltaY: CGFloat(dy), precise: true) } else { store.scrollPane(rec.key, lines: lines) }
                    try? await Task.sleep(nanoseconds: ms * 1_000_000)
                }
                return ok(["steps": count, "seconds": String(format: "%.2f", Date().timeIntervalSince(t0))])
            case "test-mouse":
                // Test hook (test instance only): a left click at --x/--y in the main window (points from
                // its top-left), as mouse events through the app.
                guard TestEnv.isTest else { throw StoreError("test-mouse only runs in a test instance") }
                guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
                      let x = str("x").flatMap(Double.init), let y = str("y").flatMap(Double.init) else { throw StoreError("--x --y") }
                let p = NSPoint(x: x, y: w.contentLayoutRect.maxY - y + (w.frame.height - w.contentLayoutRect.maxY))
                for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
                return ok(["selected": store.selectedKey.flatMap { store.state.sessions[$0]?.name } ?? ""])
            case "test-click":
                // Test hook (test instance only): a click — or a drag to --to-col, or a double-click
                // (--count 2) — at --row/--col of a session's pane, as mouse events through the app,
                // then what it did (links opened, text copied). Never moves the user's pointer.
                guard TestEnv.isTest else { throw StoreError("test-click only runs in a test instance") }
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                guard let v = store.embedded.session(rec.key)?.view as? MuxTerminalView, let win = v.window else { throw StoreError("No pane for \(rec.name)") }
                let row = Int(try need("row")) ?? 0, col = Int(try need("col")) ?? 0
                let toCol = str("to-col").flatMap(Int.init), count = Int(str("count") ?? "1") ?? 1
                let command = a["command"] as? Bool == true
                ClickTestLog.opened = []; ClickTestLog.copied = []
                func event(_ type: NSEvent.EventType, _ c: Int, clicks: Int) -> NSEvent? {
                    guard let p = v.windowPoint(col: c, row: row) else { return nil }
                    return NSEvent.mouseEvent(with: type, location: p, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)
                }
                if let toCol {
                    // A drag: AppKit doesn't route posted drag events without a real button held, so
                    // the pane gets them directly, then the same after-click step as the monitor.
                    guard let down = event(.leftMouseDown, col, clicks: 1), let up = event(.leftMouseUp, toCol, clicks: 1) else { throw StoreError("bad cell") }
                    v.mouseDown(with: down)
                    for c in stride(from: col, through: toCol, by: toCol >= col ? 1 : -1) { if let e = event(.leftMouseDragged, c, clicks: 1) { v.mouseDragged(with: e) } }
                    v.mouseUp(with: up)
                    v.clickFinished(clickCount: 1, dragged: true, at: up.locationInWindow)
                } else {
                    for n in 1...max(1, count) {   // clicks go through the app's event queue and monitor
                        for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] { if let e = event(t, col, clicks: n) { NSApp.postEvent(e, atStart: false) } }
                    }
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                return ok(["opened": ClickTestLog.opened.joined(separator: " "), "copied": ClickTestLog.copied.last ?? ""])
            case "folder-exists":
                let e = await store.folderExists(host: try need("host"), path: try need("path"))
                return ok(["exists": e.map { $0 ? "yes" : "no" } ?? "unknown"])
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
                    if let c = a["default-command"] as? String, !c.isEmpty { s.defaultCommand = c }
                    if let c = a["other-command"] as? String { s.otherCommand = c.trimmingCharacters(in: .whitespaces) }
                    if let v = a["start"] as? String {
                        if ["shell", "claude", "codex", "other"].contains(v) { s.newSessionStart = v } else { err = "start must be shell|claude|codex|other" }
                    }
                    if let d = a["disable-local-tmux"] as? String { s.disableLocalTmux = (d == "true" || d == "1") }
                if let m = a["pass-mouse"] as? String { s.passMouseToApps = (m == "true" || m == "1") }
                if let v = a["auto-forward"] as? String { s.autoForward = (v == "true" || v == "1") }
                    if let n = a["auto-sleep-min"] as? String, let v = Int(n) { s.autoSleepMinutes = v > 0 ? v : nil }
                    if let w = a["wake-on-open"] as? String { s.wakeOnOpen = (w == "true" || w == "1") }
                    if let f = a["notify-finish"] as? String { s.notifyOnFinish = (f == "true" || f == "1") }
                    if let u = a["check-updates"] as? String { s.checkForUpdates = (u == "true" || u == "1") }
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
                           "bundle": Bundle.main.bundlePath, "bundleID": Bundle.main.bundleIdentifier ?? "",
                           "pid": ProcessInfo.processInfo.processIdentifier, "test": TestEnv.isTest,
                           "tmuxSocket": store.tmuxSocket ?? "", "home": MuxbarPaths.testHome ?? "",
                           "socket": MuxbarPaths.ipcSocket])
            case "inbox":
                // Needs input (longest waiting first), then finished and unread (newest first).
                return ok(store.inbox.map { r -> [String: Any] in
                    ["name": r.name, "host": r.host, "location": store.location(of: r),
                     "kind": store.status(of: r) == .waiting ? "waiting" : "finished",
                     "unread": r.unread, "finishedAt": r.finishedAt ?? 0, "reply": r.lastReply ?? "",
                     "agent": r.agent?.rawValue ?? ""]
                } as [[String: Any]])
            case "mark-read", "mark-unread":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                store.setUnread(rec.key, cmd == "mark-unread")
                return ok(sessionJSON(store)(store.state.sessions[rec.key] ?? rec))
            case "mark-all-read":
                store.markAllRead(host: str("host"))
                return ok("marked read")
            case "preview":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                await store.fetchPreview(rec.key, info: store.live[rec.key] ?? LiveInfo(status: .unknown, attached: 0, command: nil))
                return ok(store.state.sessions[rec.key]?.lastReply ?? "")
            case "notified":
                return ok(Attention.shared.sent.map { ["title": $0.title, "body": $0.body,
                                                       "name": store.state.sessions[$0.key]?.name ?? ""] })
            case "deselect":
                store.select(nil)
                return ok("nothing selected")
            case "test-viewing":
                // Test hook: --mode active|inactive|real (whether Muxbar counts as frontmost).
                switch str("mode") {
                case "active": store.viewingOverride = true
                case "inactive": store.viewingOverride = false
                case "real": store.viewingOverride = nil
                default: throw StoreError("--mode active|inactive|real")
                }
                return ok(["viewing": store.viewedKey.flatMap { store.state.sessions[$0]?.name } ?? ""])
            case "memory":
                let h = try need("host")
                guard store.state.hosts.contains(h) else { throw StoreError("Unknown host \(h)") }
                await store.refresh(host: h)
                let top = await store.fetchTopProcesses(h, limit: Int(str("limit") ?? "") ?? 12)
                let m = store.hostMemory[h]
                let sessions = store.sessions(for: h).filter { !$0.ended }
                    .map { r -> [String: Any] in ["name": r.name, "memoryKB": store.live[r.key]?.memoryKB ?? 0] }
                    .sorted { ($0["memoryKB"] as! Int) > ($1["memoryKB"] as! Int) }
                let topList: [[String: Any]] = top.map { p -> [String: Any] in
                    let session: String = p.pane.flatMap { store.session(host: h, pane: $0)?.name } ?? ""
                    return ["pid": p.pid, "rssKB": p.rssKB, "pane": p.pane ?? "", "name": p.shortName, "args": p.args,
                            "session": session]
                }
                var out: [String: Any] = ["host": h, "level": store.memoryLevel(h).rawValue,
                                          "warn": store.memWarn, "crit": store.memCrit]
                out["os"] = m?.os ?? ""
                out["totalKB"] = m?.totalKB ?? 0
                out["availableKB"] = m?.availableKB ?? 0
                out["usedPercent"] = m?.usedPercent ?? 0
                out["swapTotalKB"] = m?.swapTotalKB ?? 0
                out["swapFreeKB"] = m?.swapFreeKB ?? 0
                out["load"] = m?.load ?? []
                out["cpus"] = m?.cpus ?? 0
                out["fastPolling"] = store.memPollers[h] != nil
                out["biggest"] = store.biggestSessionSummary(h) ?? ""
                out["sessions"] = sessions
                out["top"] = topList
                return ok(out)
            case "test-memory-thresholds":
                // Test hook: lower thresholds in memory only (never saved), so alerts can be tested
                // without filling a host's memory. --clear restores the settings.
                if a["clear"] as? Bool == true {
                    store.memThresholdOverride = nil
                } else {
                    guard let w = str("warn").flatMap(Int.init), let c = str("crit").flatMap(Int.init) else { throw StoreError("--warn P --crit P | --clear") }
                    store.memThresholdOverride = (w, c)
                }
                let now = Date().timeIntervalSince1970
                for h in store.state.hosts { store.evaluateMemoryAlerts(host: h, now: now) }
                return ok(["warn": store.memWarn, "crit": store.memCrit,
                           "levels": Dictionary(uniqueKeysWithValues: store.state.hosts.map { ($0, store.memoryLevel($0).rawValue) })])
            case "test-memory-samples":
                // Test hook: replace a host's recent samples with synthetic ones (JSON file:
                // {"totalKB": N, "samples": [{"ago": seconds, "availableKB": n}, …]}) and evaluate alerts.
                let h = try need("host")
                let data = try Data(contentsOf: URL(fileURLWithPath: try need("file")))
                guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let total = o["totalKB"] as? Int,
                      let raw = o["samples"] as? [[String: Any]] else { throw StoreError("bad samples file") }
                let now = Date().timeIntervalSince1970
                let samples = raw.compactMap { s -> MemorySample? in
                    guard let ago = s["ago"] as? Double ?? (s["ago"] as? Int).map(Double.init), let av = s["availableKB"] as? Int else { return nil }
                    return MemorySample(t: now - ago, availableKB: av)
                }.sorted { $0.t < $1.t }
                let before = Attention.shared.sent.count
                store.memSamples[h] = samples
                store.memAlerts[h] = MemoryAlerts()
                if let last = samples.last { store.hostMemory[h] = HostMemory(os: "test", totalKB: total, availableKB: last.availableKB) }
                store.evaluateMemoryAlerts(host: h, now: now)
                return ok(["alerts": Attention.shared.sent.dropFirst(before).map { $0.title + " | " + $0.body },
                           "secondsToExhaustion": MemoryTrend.secondsToExhaustion(samples, now: now) ?? -1])
            case "stop-process":
                let h = try need("host")
                guard let pid = str("pid").flatMap(Int.init) else { throw StoreError("--pid P") }
                guard a["yes"] as? Bool == true else { throw StoreError("Refusing to stop pid \(pid) on \(h) without --yes") }
                try await store.stopProcess(host: h, pid: pid)
                return ok("sent SIGTERM to \(pid) on \(h)")
            case "drop", "paste-image":
                // Same path as dropping files on the pane (paste-image: as if the image were on the clipboard).
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                let files = (a["file"] as? [String]) ?? str("file").map { [$0] } ?? []
                guard !files.isEmpty else { throw StoreError("--file PATH (repeatable)") }
                let paths = try await store.drop(rec.key, files: files.map { URL(fileURLWithPath: $0) }, confirmed: a["yes"] as? Bool == true)
                return ok(paths)
            case "history-search":
                // Same search as the History window; --claude-root/--codex-root are test hooks.
                let h = try need("host")
                let agent = str("agent").flatMap { $0 == "both" ? nil : AgentKind(rawValue: $0) }
                let res = try await store.historySearchDetailed(host: h, query: try need("query"), agent: agent, days: Int(str("days") ?? "0") ?? 0,
                                                                claudeRoot: str("claude-root"), codexRoot: str("codex-root"))
                if let p = res.partial { Log.info("history-search \(h): partial \(p.scanned)/\(p.total)") }
                return ok(res.hits.map { x -> [String: Any] in
                    ["agent": x.agent.rawValue, "path": x.path, "id": x.id, "cwd": x.cwd ?? "", "modified": x.modified, "messages": x.messages,
                     "firstPrompt": x.firstPrompt ?? "", "before": x.before, "match": x.match, "after": x.after, "role": x.role]
                })
            case "history-preview":
                guard let agent = AgentKind(rawValue: try need("agent")) else { throw StoreError("--agent claude|codex") }
                let hit = AgentHistory.Hit(agent: agent, path: try need("path"), id: "", host: try need("host"))
                guard let p = await store.historyPreview(hit) else { throw StoreError("No transcript at \(hit.path)") }
                let turns: [[String: String]] = p.turns.map { ["role": $0.role, "text": $0.text] }
                var out: [String: Any] = ["id": p.id ?? "", "firstPrompt": p.firstPrompt ?? "", "cwd": p.cwd ?? ""]
                out["gitBranch"] = p.gitBranch ?? ""
                out["model"] = p.model ?? ""
                out["turns"] = turns
                return ok(out)
            case "history-show":
                // Test hook: the History window running a search (for snapshots).
                WindowOpener.open?("history")
                try await Task.sleep(nanoseconds: 600_000_000)
                store.historyRequest = (try need("query"), str("host") ?? "*", str("claude-root"), str("codex-root"))
                return ok("searching")
            case "history-resume":
                guard let agent = AgentKind(rawValue: try need("agent")) else { throw StoreError("--agent claude|codex") }
                let hit = AgentHistory.Hit(agent: agent, path: str("path") ?? "", id: try need("id"), cwd: str("cwd"),
                                           firstPrompt: str("prompt"), host: try need("host"))
                let rec = try await store.resumeFromHistory(hit)
                return ok(sessionJSON(store)(rec))
            case "ports":
                let h = try need("host")
                return ok(store.portRows(h).map { r -> [String: Any] in
                    ["port": r.remote, "address": r.port?.address ?? "", "process": r.port?.process ?? "", "pid": r.port?.pid ?? 0,
                     "owner": r.owner?.name ?? "", "listening": r.listening, "local": r.forward?.local ?? 0]
                })
            case "forward":
                let f = try await store.forward(host: try need("host"), port: Int(try need("port")) ?? -1, local: str("local").flatMap(Int.init))
                return ok(["remote": f.remote, "local": f.local, "url": "http://localhost:\(f.local)/"])
            case "unforward":
                try await store.unforward(host: try need("host"), port: Int(try need("port")) ?? -1)
                return ok("stopped")
            case "switcher":
                // The ⌘K palette's rows for a query (same ranking as the UI).
                let rows = store.switcherRows(query: str("query") ?? "")
                return ok(rows.enumerated().map { i, r -> [String: Any] in
                    ["index": i, "id": r.item.id, "kind": r.item.kind == .session ? "session" : "command", "name": r.item.title,
                     "host": r.item.host, "group": r.item.group ?? "", "section": r.section, "score": r.score]
                })
            case "switcher-open":
                let rows = store.switcherRows(query: str("query") ?? "")
                let i = Int(str("index") ?? "0") ?? 0
                guard rows.indices.contains(i) else { throw StoreError("No row \(i) (\(rows.count) rows)") }
                store.openSwitcherRow(rows[i], toGrid: a["grid"] as? Bool == true)
                return ok(["opened": rows[i].item.title, "selected": store.selectedKey.flatMap { store.state.sessions[$0]?.name } ?? ""])
            case "switcher-show":
                // Test hook: show the palette with a query (for snapshots).
                store.switcherQuery = str("query") ?? ""
                MainWindowPresenter.show()
                store.switcherOpen = true
                return ok("shown")
            case "switcher-hide":
                store.switcherOpen = false
                store.restoreTerminalFocus()
                return ok("hidden")
            case "grid":
                let h = try need("host")
                var keys: [String] = []
                if let g = str("group") { keys = store.sessions(inGroup: g, host: h).filter { !$0.ended }.map(\.key) } else {
                    for ref in (str("ids") ?? "").split(separator: ",") { keys.append(try store.resolve(host: h, ref: String(ref)).key) }
                }
                guard keys.count >= 2 else { throw StoreError("A grid needs 2–\(GridLayout.maxTiles) sessions (--ids a,b,… or --group G)") }
                store.showInGrid(keys)
                return ok(layoutJSON(store))
            case "grid-clear":
                store.clearGrid()
                return ok(layoutJSON(store))
            case "grid-focus":
                let ks = store.gridKeys
                guard let i = Int(try need("index")), ks.indices.contains(i) else { throw StoreError("--index 0…\(max(0, ks.count - 1))") }
                store.focusTile(ks[i])
                return ok(layoutJSON(store))
            case "grid-move":
                guard let d = GridLayout.Direction(rawValue: try need("dir")) else { throw StoreError("--dir left|right|up|down") }
                store.moveTileFocus(d)
                return ok(layoutJSON(store))
            case "grid-expand":
                store.toggleExpand()
                return ok(layoutJSON(store))
            case "layout":
                return ok(layoutJSON(store))
            case "test-type-focused":
                // Test hook: keystrokes the way the keyboard delivers them — to whichever terminal
                // has the main window's keyboard focus (not to a named session).
                guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }),
                      let tv = w.firstResponder as? MuxTerminalView else { throw StoreError("No terminal has the keyboard") }
                let text = try need("text")
                for ch in text {
                    guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: w.windowNumber, context: nil, characters: String(ch),
                                                    charactersIgnoringModifiers: String(ch), isARepeat: false, keyCode: 0) else { continue }
                    tv.keyDown(with: ev)
                }
                let to = store.embedded.sessions.first { $0.value.view === tv }?.key
                return ok(["to": to.flatMap { store.state.sessions[$0]?.name } ?? ""])
            case "test-drag":
                // Test hook: the pane's own drop handler, given a pasteboard with --file paths or
                // --png image data (what a Finder drag or a screenshot thumbnail carries).
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                guard let pane = store.embedded.session(rec.key) else { throw StoreError("No open pane for \(rec.name)") }
                let pb = NSPasteboard(name: NSPasteboard.Name("io.github.ganeshpanaskar.muxbar.test-drag"))
                pb.clearContents()
                if let png = str("png") {
                    pb.setData(try Data(contentsOf: URL(fileURLWithPath: png)), forType: .png)
                } else {
                    let files = (a["file"] as? [String]) ?? str("file").map { [$0] } ?? []
                    pb.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL })
                }
                guard MuxTerminalView.hasDroppable(pb), (pane.view as? MuxTerminalView)?.handleDrop(pb) == true else { throw StoreError("The pane didn't take the drop") }
                return ok("dropped")
            case "test-render-text":
                // Test hook: a PNG showing --text in large letters (for "can the agent read the image").
                let text = try need("text"), out = try need("out")
                let size = NSSize(width: 900, height: 300)
                let img = NSImage(size: size)
                img.lockFocus()
                NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
                (text as NSString).draw(at: NSPoint(x: 40, y: 100), withAttributes: [
                    .font: NSFont.boldSystemFont(ofSize: 96), .foregroundColor: NSColor.systemRed])
                img.unlockFocus()
                guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                else { throw StoreError("render failed") }
                try png.write(to: URL(fileURLWithPath: out))
                return ok(out)
            case "sleep":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                let info = try await store.sleep(rec.key)
                return ok(["name": rec.name, "agent": info.agent.rawValue, "sessionID": info.sessionID, "flags": info.flags,
                           "freedKB": info.freedKB, "resume": info.resumeCommand])
            case "wake":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                try await store.wake(rec.key)
                return ok("woke \(rec.name)")
            case "sleep-check":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                await store.refresh(host: rec.host)
                let (inputs, check, _) = await store.sleepInputs(rec.key, auto: false)
                let (autoInputs, _, _) = await store.sleepInputs(rec.key, auto: true)
                let mins = store.settings.autoSleepMinutes ?? 30
                return ok(["manual": SleepPolicy.check(inputs, auto: false).map(\.description),
                           "auto": SleepPolicy.check(autoInputs, auto: true, autoMinutes: mins).map(\.description),
                           "freedKB": check?.freedKB ?? 0, "conversationID": inputs.conversationID ?? "",
                           "flags": inputs.agent.map { AgentAdapter.keptFlags($0, argv: check?.argv ?? []) } ?? [],
                           "descendants": check?.descendants.map(\.shortName) ?? []])
            case "sleep-idle":
                let h = try need("host")
                let res = await store.sleepIdle(host: h, dryRun: a["dry-run"] as? Bool == true)
                return ok(res.map { ["name": $0.name, "result": $0.result, "freedKB": $0.freedKB] })
            case "set-conversation":
                // Repair: which agent conversation a session continues on Resume/Wake (any session,
                // ended or running). --agent claude|codex, default: the session's own.
                let h = try need("host"), ref = try need("id"), conv = try need("conversation")
                let matches = store.state.sessions.values.filter { $0.host == h && ($0.key == ref || $0.name == ref || $0.tmuxID == ref) }
                guard matches.count == 1, let rec = matches.first else {
                    throw StoreError(matches.isEmpty ? "No session '\(ref)' on \(h)" : "'\(ref)' matches \(matches.count) sessions; use its key")
                }
                guard ClaudeConversations.isValidSessionID(conv) else { throw StoreError("Not a conversation id: \(conv)") }
                let agent = try str("agent").map { a -> AgentKind in
                    guard let k = AgentKind(rawValue: a) else { throw StoreError("Unknown agent \(a)") }
                    return k
                } ?? rec.agent ?? .claude
                store.mutate {
                    $0.sessions[rec.key]?.agent = agent
                    $0.sessions[rec.key]?.agentSessionID = conv
                    $0.sessions[rec.key]?.claudeSessionID = agent == .claude ? conv : nil
                }
                Log.info("set conversation of \(rec.name) on \(h): \(agent.rawValue) \(conv)")
                return ok(["name": rec.name, "agent": agent.rawValue, "conversation": conv, "ended": rec.ended])
            case "never-sleep":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                let on = (str("value") ?? "on") != "off"
                store.mutate { $0.sessions[rec.key]?.neverSleep = on }
                return ok(["name": rec.name, "neverSleep": on])
            case "hooks-status":
                let h = try need("host")
                guard store.state.hosts.contains(h) else { throw StoreError("Unknown host \(h)") }
                await store.hooks.refresh(host: h)
                return ok(["host": h, "claude": store.hooks.state(h, .claude).rawValue, "codex": store.hooks.state(h, .codex).rawValue])
            case "hooks-install", "hooks-uninstall":
                // Changes the agent's own configuration on that host, so it needs --yes (the UI asks first).
                let h = try need("host")
                guard store.state.hosts.contains(h) else { throw StoreError("Unknown host \(h)") }
                guard let agent = AgentKind(rawValue: try need("agent")) else { throw StoreError("--agent claude|codex") }
                guard a["yes"] as? Bool == true else {
                    throw StoreError("Refusing to change \(agent.displayName)'s hooks on \(h) without --yes")
                }
                let o = cmd == "hooks-install" ? try await store.hooks.install(host: h, agent: agent)
                                               : try await store.hooks.uninstall(host: h, agent: agent)
                return ok(["host": h, "agent": agent.rawValue, "state": store.hooks.state(h, agent).rawValue,
                           "outcome": o.state.rawValue, "detail": o.detail])
            case "probe-script":
                // Test hook (benchmarks): the exact status-probe script this app would run on a host.
                let h = try need("host")
                let mode: HostProbe.Mode
                switch str("mode") ?? "status" {
                case "status": mode = .status
                case "discover": mode = .discover
                case "memory": mode = .memory
                default: throw StoreError("--mode status|discover|memory")
                }
                guard let (script, nonce) = store.probeScript(host: h, mode: mode) else { throw StoreError("no tmux for \(h)") }
                return ok(["script": script, "nonce": nonce])
            case "resume-ended":
                let h = try need("host"), ref = try need("id")
                guard let rec = store.state.sessions.values.first(where: { $0.host == h && $0.ended && ($0.name == ref || $0.tmuxID == ref || $0.key == ref) })
                else { throw StoreError("No ended session '\(ref)' on \(h)") }
                return ok(sessionJSON(store)(try await store.resumeEnded(key: rec.key)))
            case "resume-all":
                let h = try need("host")
                guard store.state.hosts.contains(h) else { throw StoreError("Unknown host \(h)") }
                let r = await store.resumeAllEnded(host: h)
                return ok(["resumed": r.resumed.joined(separator: ","), "skipped": r.skipped.joined(separator: ","), "failed": r.failed.joined(separator: ",")])
            case "restore-state":
                return ok(["openPanes": store.state.openPanes.compactMap { store.state.sessions[$0]?.name },
                           "lastSelected": store.state.lastSelected.flatMap { store.state.sessions[$0]?.name } ?? ""])
            case "scroll":
                // Test hook: --lines N (positive = back), or --to POSITION (0 = live); reports info.
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                await store.refreshScrollInfo(rec.key)
                if let l = str("lines").flatMap(Int.init) { store.scrollPane(rec.key, lines: l) }
                if let pg = str("pages").flatMap(Int.init) { store.scrollPages(rec.key, pg) }
                if let t = str("to").flatMap(Int.init) { store.scrollPane(rec.key, toPosition: t) }
                try? await Task.sleep(nanoseconds: 900_000_000)
                await store.refreshScrollInfo(rec.key)
                let i = store.scrollInfo[rec.key]
                return ok(["history": i?.history ?? -1, "position": i?.position ?? -1, "inMode": i?.inMode ?? false,
                           "atLive": i?.atLive ?? true, "alternate": i?.alternate ?? false])
            case "close-pane":
                let rec = try store.resolve(host: try need("host"), ref: try need("id"))
                store.closePane(key: rec.key)
                return ok("closed pane of \(rec.name) (session keeps running)")
            case "new-in-group":
                // Test hook: opens the New Session window prefilled with host + group.
                Actions.newSession(store, host: try need("host"), group: str("group"))
                return ok("opened")
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
                    ["id": c.id, "cwd": c.cwd ?? "", "prompt": c.firstPrompt ?? "", "modified": c.modified]
                })
            case "resume":
                // --dir given: start directly from folder + session id (like the dialog's fields).
                // Otherwise look the id up among the host's conversations to find its folder.
                let h = try need("host"), cid = try need("id")
                guard ClaudeConversations.isValidSessionID(cid) else { throw StoreError("'\(cid)' isn't a valid Claude session id") }
                let c: ClaudeConversation
                if let dir = str("dir"), !dir.isEmpty {
                    c = ClaudeConversation(id: cid, cwd: dir, firstPrompt: nil, modified: 0)
                } else {
                    let list = try await store.conversations(host: h, limit: 200)
                    guard let found = list.first(where: { $0.id == cid }) else { throw StoreError("No Claude conversation \(cid) on \(h); pass --dir to start it anyway") }
                    c = found
                }
                return ok(sessionJSON(store)(try await store.resume(host: h, conversation: c, name: str("name"), group: str("group"))))
            case "embedded":
                // Built-in panes: which sessions have one, and whether its process is running.
                return ok(store.embedded.sessions.values.map { e -> [String: Any] in
                    ["key": e.key, "name": store.state.sessions[e.key]?.name ?? "",
                     "state": e.isRunning ? "running" : "exited", "pid": Int(e.pid), "starts": e.starts,
                     "mouseToApp": e.view.allowMouseReporting]
                }.sorted { ($0["name"] as! String) < ($1["name"] as! String) })
            case "open-window":
                // Test hook: open the New Session or Continue window.
                guard let id = str("id"), ["new", "continue", "settings", "setup", "history"].contains(id) else { throw StoreError("--id new|continue|settings|setup|history") }
                if id == "settings" { activateApp(); WindowOpener.openSettings?() } else { WindowOpener.open?(id) }
                return ok("opened \(id)")
            case "window":
                // Test hook: report or close the main window (exercises the reopen path).
                let w = NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
                if str("action") == "close" { w?.close(); return ok("closed") }
                if let wd = str("width").flatMap(Double.init), let w {   // resize (test layouts at a given size)
                    var f = w.frame; f.size.width = wd
                    if let ht = str("height").flatMap(Double.init) { f.size.height = ht }
                    w.setFrame(f, display: true)
                    return ok(["state": w.isVisible ? "open" : "closed", "width": Int(w.frame.width), "height": Int(w.frame.height)])
                }
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
                case "new", "continue", "setup", "history": try Snapshot.renderMainWindow(to: out, id: str("what")!)
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

    /// Single or grid, the tiles in order and each pane's size in cells (what tmux sizes to).
    static func layoutJSON(_ store: SessionStore) -> [String: Any] {
        func size(_ k: String) -> [String: Int] {
            guard let v = store.embedded.session(k)?.view else { return [:] }
            let t = v.getTerminal()
            return ["cols": t.cols, "rows": t.rows]
        }
        let tiles = store.gridKeys.map { k -> [String: Any] in
            var d: [String: Any] = ["key": k, "name": store.state.sessions[k]?.name ?? "", "focused": store.focusedTile == k]
            d.merge(size(k)) { a, _ in a }
            return d
        }
        let name = { (k: String?) in k.flatMap { store.state.sessions[$0]?.name } ?? "" }
        return ["mode": store.state.layout.rawValue, "inGrid": store.inGrid, "tiles": tiles,
                "focused": name(store.focusedTile), "selected": name(store.selectedKey),
                "selectedSize": store.selectedKey.map(size) ?? [:],
                // Names aren't unique (an ended record and its new session can share one): first wins.
                "sizes": Dictionary(store.embedded.sessions.keys.compactMap { k in
                    store.state.sessions[k].map { ($0.name, size(k)) } }, uniquingKeysWith: { a, _ in a })]
    }

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
                                    "group": r.group ?? "", "claudeSessionID": r.claudeSessionID ?? "",
                                    "origin": r.isOutside ? "outside" : "muxbar",
                                    "source": store.live[r.key]?.source.rawValue ?? "screen",
                                    "agent": store.live[r.key]?.agent?.rawValue ?? r.agent?.rawValue ?? "",
                                    "agentSessionID": r.agentSessionID ?? "",
                                    "reason": store.live[r.key]?.reason ?? "",
                                    "hookEvent": store.live[r.key]?.hookEvent ?? "",
                                    "memoryKB": store.live[r.key]?.memoryKB ?? 0,
                                    "unread": r.unread, "finishedAt": r.finishedAt ?? 0, "lastReply": r.lastReply ?? "",
                                    "sleeping": r.sleep != nil, "freedKB": r.sleep?.freedKB ?? 0, "neverSleep": r.neverSleep]
            if let t = r.tab {
                d["tab"] = ["kind": t.kind.rawValue, "windowID": t.windowID ?? -1, "tty": t.tty ?? "",
                            "itermSessionID": t.itermSessionID ?? ""]
            }
            return d
        }
    }

    static func settingsJSON(_ s: AppSettings) -> [String: Any] {
        ["terminal": s.terminal.rawValue, "defaultCommand": s.defaultCommand, "newSessionStart": s.newSessionStart, "otherCommand": s.otherCommand, "checkForUpdates": s.checkForUpdates, "passMouseToApps": s.passMouseToApps,
         "sshConfigFile": s.sshConfigFile ?? "", "disableLocalTmux": s.disableLocalTmux]
    }

    static func pollingJSON(_ store: SessionStore) -> [String: Any] {
        ["active": store.pollingActive, "interval": store.interval]
    }
}

/// `Muxbar --cli <command> [--key value ...] [--yes] [--no-attach] [--json]`
enum CLI {
    static let flags: Set<String> = ["yes", "no-attach", "json", "no-enter", "dry-run", "clear", "skip", "grid", "create-folder", "command", "apply"]

    static func run(_ argv: [String]) -> Int32 {
        guard let cmd = argv.first else {
            FileHandle.standardError.write(Data(usage.utf8))
            return 2
        }
        var args: [String: Any] = [:]
        var json = false
        var i = 1
        /// A key given more than once (--file a --file b) becomes a list.
        func put(_ key: String, _ value: String) {
            if let prev = args[key] as? String { args[key] = [prev, value] }
            else if let prev = args[key] as? [String] { args[key] = prev + [value] }
            else { args[key] = value }
        }
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
                put(key, argv[i + 1])
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
      hosts | available-hosts | hosts-add --host H [--root R] | hosts-remove --host H [--yes] | host-check --host H
      setup-status | setup-apply [--root R] [--host H --host-root R]… | setup-apply --skip
      list [--host H] | probe --host H | refresh [--host H]
      new --host H --name N [--dir D] [--cmd C] [--group G] [--no-attach]   (no --cmd = plain shell)
      type --host H --id ID --text T [--no-enter]   (test hook: keystrokes into the built-in pane)
      groups [--host H] | group-create --host H --name G | group-rename --host H --name G --to G2
      group-delete --host H --name G | group-set --host H --id ID --group G  (empty --group = ungroup)
      Groups belong to one host; a session can only join a group on its own host.
      conversations --host H [--limit N] | resume --host H --id CLAUDE_SESSION_ID [--dir D] [--name N] [--group G]
      hooks-status --host H | hooks-install --host H --agent claude|codex --yes | hooks-uninstall --host H --agent A --yes
      inbox | mark-read --host H --id ID | mark-unread --host H --id ID | mark-all-read [--host H] | preview --host H --id ID
      notified | deselect | test-viewing --mode active|inactive|real
      memory --host H [--limit N] | stop-process --host H --pid P --yes
      sleep --host H --id ID | wake --host H --id ID | sleep-check --host H --id ID | sleep-idle --host H [--dry-run]
      drop --host H --id ID --file PATH [--file …] [--yes] | paste-image --host H --id ID --file PNG
      ports --host H | forward --host H --port P [--local L] | unforward --host H --port P
      history-search --host H --query Q [--agent claude|codex|both] [--days N] | history-preview --host H --agent A --path P
      history-resume --host H --agent A --id ID [--cwd DIR]
      switcher --query Q | switcher-open --query Q --index N [--grid]
      grid --host H --ids a,b,… | grid --host H --group G | grid-clear | grid-focus --index N | grid-move --dir D | grid-expand | layout
      never-sleep --host H --id ID --value on|off | settings-set --auto-sleep-min N (0 = off) --wake-on-open true|false
      test-memory-thresholds --warn P --crit P | --clear | test-memory-samples --host H --file JSON
      rename --host H --id ID --name N | focus --host H --id ID
      kill --host H --id ID --yes | status --host H --id ID | dismiss-ended [--host H]
      workspace-root --host H | settings-set --root-host H --root PATH (empty = default)
      settings | settings-set [--terminal embedded|terminal|iterm] [--ssh-config PATH] [--default-command C]
      scroll --host H --id ID [--lines N | --to POS] | type … then check atLive
      waiting | next-waiting   (⌘J) | resume-ended --host H --id NAME | restore-state
      check-updates [--latest TAG] [--apply]   (no --apply = only report the decision) | settings-set --check-updates true|false --start shell|claude|codex|other --other-command CMD
      embedded | selected | window [--action close] | tabs | polling | simulate-sleep | simulate-wake | info | snapshot --out PNG [--what window] | quit
    ID may be a tmux id ($3), an exact session name, or a record key.

    """
}
