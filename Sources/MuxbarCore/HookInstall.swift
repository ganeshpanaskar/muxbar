import Foundation

/// Scripts that install, remove and check Muxbar's status hooks on a host (F1). They only ever run
/// when the user asks (Settings → Status, or `--cli hooks-install … --yes`).
/// - Claude Code: the `muxbar-status` plugin from Muxbar's local marketplace, installed with Claude's
///   own CLI (`claude plugin marketplace add` + `claude plugin install`), so Claude manages its config.
/// - Codex: Muxbar's handlers merged into `$CODEX_HOME/hooks.json` (a timestamped backup is kept and
///   every handler is tagged `"statusMessage": "muxbar-status"`, so removal takes out exactly them).
///   Codex asks the user to trust new hooks once (`/hooks`).
public enum HookInstall {
    public static let pluginID = "muxbar-status@muxbar"
    public static let marketplace = "muxbar"
    public static let tag = "muxbar-status"
    /// Where Muxbar copies agent-plugin/ on each host (a complete shell word).
    public static let defaultPluginDir = "\"$HOME/.muxbar/agent-plugin\""

    public enum State: String, Codable, Sendable {
        case installed, notInstalled, blocked, needsTrust, agentMissing, unknown
    }

    /// The agent CLI: from a login interactive shell (installers often put `claude` on PATH in ~/.zshrc), or a
    /// fixed binary folder in tests.
    public static func agentCommand(_ kind: AgentKind, binDir: String?) -> String {
        if let b = binDir { return shellQuote(b + "/" + kind.rawValue) }
        return kind.rawValue
    }

    /// Wraps `body` so it runs in the user's login interactive shell (for PATH), unless testing.
    static func inLoginShell(_ body: String, testing: Bool) -> String {
        testing ? body : "\"${SHELL:-/bin/sh}\" -lic " + shellQuote(body) + " 2>&1"
    }

    public static func claudeInstallScript(binDir: String?, pluginDir: String = defaultPluginDir) -> String {
        let cl = agentCommand(.claude, binDir: binDir)
        let body = """
        command -v \(cl) >/dev/null 2>&1 || { echo "MBX_NOAGENT"; exit 0; }
        \(cl) plugin marketplace add \(pluginDir) 2>&1; echo "MBX_RC_MARKET $?"
        \(cl) plugin install \(pluginID) 2>&1; echo "MBX_RC_INSTALL $?"
        """
        return inLoginShell(body, testing: binDir != nil)
    }

    public static func claudeUninstallScript(binDir: String?) -> String {
        let cl = agentCommand(.claude, binDir: binDir)
        let body = """
        command -v \(cl) >/dev/null 2>&1 || { echo "MBX_NOAGENT"; exit 0; }
        \(cl) plugin uninstall \(pluginID) 2>&1; echo "MBX_RC_UNINSTALL $?"
        \(cl) plugin marketplace remove \(marketplace) 2>&1; echo "MBX_RC_MARKET $?"
        """
        return inLoginShell(body, testing: binDir != nil)
    }

    public static func claudeStatusScript(binDir: String?) -> String {
        let cl = agentCommand(.claude, binDir: binDir)
        let body = """
        command -v \(cl) >/dev/null 2>&1 || { echo "MBX_NOAGENT"; exit 0; }
        echo "MBX_JSON_BEGIN"; \(cl) plugin list --json 2>/dev/null; echo; echo "MBX_JSON_END"
        """
        return inLoginShell(body, testing: binDir != nil)
    }

    public struct Outcome: Equatable, Sendable {
        public var state: State
        public var detail: String
    }

    /// Reads an install/uninstall run's output.
    public static func claudeOutcome(_ out: String, installing: Bool) -> Outcome {
        let text = cleanOutput(out)
        if out.contains("MBX_NOAGENT") { return Outcome(state: .agentMissing, detail: "claude isn't installed on this host") }
        let lower = text.lowercased()
        let policy = ["policy", "not allowed", "blocked", "managed settings", "disallowed", "forbidden"]
        if policy.contains(where: lower.contains) && !rc(out, installing ? "MBX_RC_INSTALL" : "MBX_RC_UNINSTALL") {
            return Outcome(state: .blocked, detail: text)
        }
        if installing {
            let ok = rc(out, "MBX_RC_INSTALL") || lower.contains("already installed")
            return Outcome(state: ok ? .installed : .notInstalled, detail: text)
        }
        let ok = rc(out, "MBX_RC_UNINSTALL") || lower.contains("not installed") || lower.contains("not found")
        return Outcome(state: ok ? .notInstalled : .installed, detail: text)
    }

    /// From `claude plugin list --json` (wrapped in MBX_JSON markers).
    public static func claudeState(_ out: String) -> State {
        if out.contains("MBX_NOAGENT") { return .agentMissing }
        guard let b = out.range(of: "MBX_JSON_BEGIN"), let e = out.range(of: "MBX_JSON_END", range: b.upperBound..<out.endIndex)
        else { return .unknown }
        let json = out[b.upperBound..<e.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = json.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .unknown }
        guard let p = list.first(where: { ($0["id"] as? String) == pluginID }) else { return .notInstalled }
        return (p["enabled"] as? Bool) == false ? .notInstalled : .installed
    }

    /// Codex: add (`install`) or remove (`uninstall`) Muxbar's handlers in `<codexHome>/hooks.json`,
    /// or report (`status`). Runs python3 on the host (present on macOS and most Linux distributions). Prints one line
    /// `MBX_CODEX <state> <detail>`.
    public static func codexScript(_ mode: String, codexHome: String?, hookCommand: String,
                                   events: [String] = codexEvents) -> String {
        let home = codexHome.map(shellQuotePath) ?? "\"${CODEX_HOME:-$HOME/.codex}\""
        let py = #"""
        import json, os, shutil, sys, time
        mode, home, cmd, tag = sys.argv[1], sys.argv[2], os.path.expanduser(sys.argv[3]), sys.argv[4]
        events = sys.argv[5].split(",")
        path = os.path.join(home, "hooks.json")
        try:
            data = json.load(open(path)) if os.path.exists(path) else {}
        except Exception as e:
            print("MBX_CODEX error hooks.json isn't valid JSON (%s); left unchanged" % e); sys.exit(0)
        hooks = data.get("hooks", {}) if isinstance(data, dict) else {}
        ours = lambda h: isinstance(h, dict) and h.get("statusMessage") == tag
        present = any(ours(h) for gs in hooks.values() for g in gs for h in g.get("hooks", []))
        if mode == "status":
            print("MBX_CODEX %s" % ("installed" if present else "notInstalled")); sys.exit(0)
        for ev in list(hooks):
            groups = []
            for g in hooks[ev]:
                kept = [h for h in g.get("hooks", []) if not ours(h)]
                if kept:
                    g = dict(g); g["hooks"] = kept; groups.append(g)
            if groups: hooks[ev] = groups
            else: del hooks[ev]
        if mode == "install":
            for ev in events:
                h = {"type": "command", "command": "\"%s\" codex %s" % (cmd, ev), "statusMessage": tag,
                     "timeout": 3 if ev in ("SessionEnd", "Interrupt") else 5}
                if ev != "SessionEnd": h["async"] = True
                g = {"hooks": [h]}
                if ev in ("PreToolUse", "PostToolUse", "PermissionRequest"): g["matcher"] = ".*"
                hooks.setdefault(ev, []).append(g)
        if not os.path.isdir(home):
            if mode == "uninstall": print("MBX_CODEX notInstalled"); sys.exit(0)
            os.makedirs(home, mode=0o700)
        if os.path.exists(path):
            shutil.copy2(path, "%s.muxbar-backup-%d" % (path, int(time.time())))
        if not isinstance(data, dict): data = {}
        data["hooks"] = hooks
        if not hooks: data.pop("hooks")
        tmp = path + ".muxbar-tmp"
        with open(tmp, "w") as f: json.dump(data, f, indent=2); f.write("\n")
        os.replace(tmp, path)
        print("MBX_CODEX %s %s" % ("installed" if mode == "install" else "notInstalled", path))
        """#
        return "python3 -c " + shellQuote(py) + " " + shellQuote(mode) + " " + home + " "
            + shellQuote(hookCommand) + " " + shellQuote(tag) + " " + shellQuote(events.joined(separator: ","))
    }

    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest",
                                     "Stop", "Interrupt", "PreCompact", "PostCompact", "SessionEnd"]

    public static func codexOutcome(_ out: String) -> Outcome {
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("MBX_CODEX ") }) else {
            return Outcome(state: .unknown, detail: cleanOutput(out))
        }
        let parts = line.dropFirst("MBX_CODEX ".count).split(separator: " ", maxSplits: 1).map(String.init)
        let state: State = parts.first.flatMap(State.init(rawValue:)) ?? .unknown
        return Outcome(state: state, detail: parts.count > 1 ? parts[1] : "")
    }

    static func rc(_ out: String, _ marker: String) -> Bool {
        out.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "\(marker) 0" }
    }

    /// Output for display: our markers and blank lines removed.
    static func cleanOutput(_ out: String) -> String {
        out.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("MBX_") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }
}
