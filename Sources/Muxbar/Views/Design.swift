import AppKit
import MuxbarCore
import SwiftUI

/// Shared look: agent badges, status pills, the one-line "what is it doing" text, memory bars and
/// the session cards on the home screen.
enum Theme {
    /// Claude's clay and a graphite for Codex, so the two read apart at a glance.
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.20, green: 0.24, blue: 0.29)
    static let asleep = Color.indigo
}

/// What a session shows as its state: the agent's status, plus Muxbar's own (asleep, finished
/// and not seen yet, ended).
enum Presence: Equatable {
    case working, waiting, done, idle, asleep, shell, ended, unknown

    var color: Color {
        switch self {
        case .working: return .blue
        case .waiting: return .orange
        case .done: return .green
        case .idle: return .green
        case .asleep: return Theme.asleep
        case .shell, .unknown: return .secondary
        case .ended: return .gray
        }
    }

    var title: String {
        switch self {
        case .working: return "Working"
        case .waiting: return "Needs you"
        case .done: return "Done"
        case .idle: return "Idle"
        case .asleep: return "Asleep"
        case .shell: return "Shell"
        case .ended: return "Ended"
        case .unknown: return "Unknown"
        }
    }

    var symbol: String? {
        switch self {
        case .waiting: return "hand.raised.fill"
        case .working: return "bolt.fill"
        case .done: return "checkmark.circle.fill"
        case .asleep: return "moon.zzz.fill"
        case .ended: return "stop.circle"
        default: return nil
        }
    }

    /// Worth a pill in a list row (idle and shells stay quiet).
    var isNotable: Bool { [.working, .waiting, .done, .asleep].contains(self) }
}

extension SessionStore {
    func presence(of rec: SessionRecord) -> Presence {
        if rec.ended { return .ended }
        if rec.sleep != nil { return .asleep }
        switch status(of: rec) {
        case .working: return .working
        case .waiting: return .waiting
        case .idle, .running: return rec.unread ? .done : .idle
        case .notClaude, .notRunning: return agentKind(of: rec) == nil ? .shell : .idle
        case .unknown: return agentKind(of: rec) == nil ? .shell : .unknown
        case .ended: return .ended
        }
    }

    /// The agent running in the session now, else the one it last ran (for its badge).
    func agentKind(of rec: SessionRecord) -> AgentKind? { live[rec.key]?.agent ?? rec.agent }

    /// One line saying what the session is doing, for its row, header and card.
    func activity(of rec: SessionRecord) -> String {
        let info = live[rec.key]
        let agent = agentKind(of: rec)?.displayName ?? "Agent"
        func firstLine(_ s: String?) -> String? {
            guard let s else { return nil }
            let l = s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return l.isEmpty ? nil : l
        }
        switch presence(of: rec) {
        case .ended:
            return rec.agent != nil ? "Ended · Resume continues the \(agent) conversation" : "Ended"
        case .asleep:
            return "Asleep · freed \(formatKB(rec.sleep?.freedKB ?? 0)) · opens awake"
        case .waiting:
            let why: String
            switch info?.reason ?? "" {
            case "permission": why = "Asking permission to continue"
            case "question": why = "Asking you a question"
            default: why = "Waiting for your input"
            }
            return info?.hookTS.map { why + " · " + timeAgo($0) } ?? why
        case .working:
            switch info?.hookEvent ?? "" {
            case "PreToolUse", "PostToolUse": return "Running tools…"
            case "PreCompact": return "Compacting the conversation…"
            default: return "Thinking…"
            }
        case .done, .idle:
            if let r = firstLine(rec.lastReply) ?? firstLine(info?.reply) { return r }
            if presence(of: rec) == .done { return "Finished · " + timeAgo(rec.finishedAt ?? rec.lastActivity ?? rec.created) }
            return "Idle · " + relativeAge(rec.lastActivity)
        case .shell:
            if let c = info?.command, !["zsh", "bash", "sh", "fish", "-zsh", "login"].contains(c) { return "Running \(c)" }
            return "Shell · " + relativeAge(rec.lastActivity)
        case .unknown:
            return "Checking… · " + relativeAge(rec.lastActivity)
        }
    }

    /// The folder as people say it: ~/… on this Mac, the path on a host.
    func displayFolder(_ rec: SessionRecord) -> String {
        guard var p = rec.path, !p.isEmpty else { return "~" }
        // macOS reports /tmp and /var under /private.
        if rec.host == localHost, p.hasPrefix("/private/tmp") || p.hasPrefix("/private/var") { p = String(p.dropFirst("/private".count)) }
        let home = NSHomeDirectory()
        if rec.host == localHost, p == home || p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        if let r = p.range(of: #"^/home/[^/]+"#, options: .regularExpression) { return "~" + p[r.upperBound...] }
        return p
    }
}

/// Claude or Codex mark, or a terminal for a plain shell; the status as a small dot on its corner.
struct AgentBadge: View {
    var kind: AgentKind?
    var presence: Presence
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(fill)
            if kind == nil {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            }
            glyph
        }
        .frame(width: size, height: size)
        .opacity(presence == .ended ? 0.45 : 1)
        .overlay(alignment: .bottomTrailing) {
            if presence != .ended && presence != .shell && presence != .unknown {
                StatusDot(status: presence == .waiting ? .waiting : (presence == .working ? .working : .idle))
                    .foregroundStyle(presence.color)
                    .overlay(Circle().fill(presence.color).frame(width: size * 0.34, height: size * 0.34))
                    .frame(width: size * 0.34, height: size * 0.34)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).frame(width: size * 0.48, height: size * 0.48))
                    .offset(x: size * 0.16, y: size * 0.16)
            }
        }
        .accessibilityLabel((kind?.displayName ?? "Shell") + ", " + presence.title)
    }

    private var fill: Color {
        switch kind {
        case .claude?: return Theme.claude
        case .codex?: return Theme.codex
        case nil: return Color.secondary.opacity(0.08)
        }
    }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .claude?:
            Image(systemName: "sparkle").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
        case .codex?:
            Text(">_").font(.system(size: size * 0.42, weight: .heavy, design: .monospaced)).foregroundStyle(.white)
        case nil:
            Image(systemName: "terminal").font(.system(size: size * 0.46, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

/// "Working" with a spinner, "Needs you", "Done", "Asleep", "Ended". `iconOnly` for the sidebar,
/// where the name needs the room.
struct StatusPill: View {
    var presence: Presence
    var compact = false
    var iconOnly = false

    var body: some View {
        if iconOnly { icon } else { full }
    }

    private var icon: some View {
        Image(systemName: presence.symbol ?? "circle.fill").font(.system(size: 10, weight: .bold))
            .foregroundStyle(presence.color)
            .symbolEffect(.pulse, isActive: presence == .working || presence == .waiting)
        .frame(width: 20, height: 20)
        .background(Circle().fill(presence.color.opacity(0.14)))
        .help(presence.title)
    }

    private var full: some View {
        HStack(spacing: 4) {
            if let s = presence.symbol {
                Image(systemName: s).font(.system(size: compact ? 8 : 9, weight: .bold))
                    .symbolEffect(.pulse, isActive: presence == .working)
            } else {
                Circle().fill(presence.color).frame(width: 6, height: 6)
            }
            Text(presence.title).font(.system(size: compact ? 10 : 11, weight: .semibold))
        }
        .foregroundStyle(presence.color)
        .padding(.horizontal, compact ? 6 : 8).padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(presence.color.opacity(0.14)))
        .fixedSize()
    }
}

/// A host's memory as a thin bar with "used/total GB" (orange and red as it fills).
struct MemoryBar: View {
    var mem: HostMemory
    var level: MemoryLevel
    var width: CGFloat = 38

    var body: some View {
        let color: Color = level == .critical ? .red : (level == .warn ? .orange : .secondary)
        HStack(spacing: 5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(level == .normal ? Color.secondary.opacity(0.6) : color)
                    .frame(width: max(3, width * min(1, mem.usedPercent / 100)))
            }
            .frame(width: width, height: 4)
            Text("\(Int((Double(mem.usedKB) / 1_048_576).rounded()))/\(Int((Double(mem.totalKB) / 1_048_576).rounded())) GB")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(level == .normal ? Color.secondary : color)
        }
    }
}

/// A session on the home screen: what it is, where, what it's doing, and its last reply.
struct SessionCard: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var hover = HoverState()
    var rec: SessionRecord

    var body: some View {
        let p = store.presence(of: rec)
        Button { Actions.focus(store, rec) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    AgentBadge(kind: store.agentKind(of: rec), presence: p, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rec.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text("\(store.hostLabel(rec.host)) · \(store.displayFolder(rec))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    StatusPill(presence: p, compact: true)
                }
                Text(store.activity(of: rec))
                    .font(.callout)
                    .foregroundStyle(p == .waiting ? Color.orange : .primary.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                HStack(spacing: 8) {
                    if let g = rec.group { Label(g, systemImage: "folder").labelStyle(.titleAndIcon) }
                    Spacer()
                    if let kb = store.live[rec.key]?.memoryKB, kb > 0 { Text(formatKB(kb)).monospacedDigit() }
                    Text(timeAgo(rec.lastActivity ?? rec.created))
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(hover.on ? 1 : 0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(p == .waiting ? Color.orange.opacity(0.6) : Color.secondary.opacity(hover.on ? 0.35 : 0.16), lineWidth: p == .waiting ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help("Open \(rec.name)")
    }
}

/// Home screen when no session is selected: what needs you, what's working, what finished.
struct HomeDashboard: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let live = store.state.hosts.flatMap { store.sessions(for: $0) }.filter { !$0.ended }
        let by: (Presence) -> [SessionRecord] = { p in
            live.filter { store.presence(of: $0) == p }.sorted { ($0.lastActivity ?? 0) > ($1.lastActivity ?? 0) }
        }
        let waiting = by(.waiting), working = by(.working), done = by(.done)
        let rest = live.filter { ![.waiting, .working, .done].contains(store.presence(of: $0)) }
            .sorted { ($0.lastActivity ?? 0) > ($1.lastActivity ?? 0) }
        if live.isEmpty {
            VStack(spacing: 14) {
                LaunchAnimationView(dark: colorScheme == .dark).frame(width: 200, height: 200)
                Text("No sessions yet").font(.title2).fontWeight(.semibold)
                Text("Start Claude, Codex or a shell on this Mac or a remote host.").foregroundStyle(.secondary)
                Button { openWindow(id: "new") } label: { Label("New Session", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Sessions").font(.system(size: 26, weight: .bold))
                        Text(summary(waiting: waiting.count, working: working.count, done: done.count, all: live.count))
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button { openWindow(id: "new") } label: { Label("New Session", systemImage: "plus") }
                            .buttonStyle(.borderedProminent)
                    }
                    section("Needs you", "hand.raised.fill", .orange, waiting)
                    section("Working", "bolt.fill", .blue, working)
                    section("Finished", "checkmark.circle.fill", .green, done)
                    section("Everything else", "square.stack", .secondary, rest)
                }
                .padding(24)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func summary(waiting: Int, working: Int, done: Int, all: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if working > 0 { parts.append("\(working) working") }
        if done > 0 { parts.append("\(done) finished") }
        parts.append("\(all) open")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func section(_ title: String, _ symbol: String, _ color: Color, _ recs: [SessionRecord]) -> some View {
        if !recs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(title).font(.headline)
                    Text("\(recs.count)").font(.subheadline).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(recs) { SessionCard(rec: $0) }
                }
            }
        }
    }
}

/// Where the session runs; on this Mac a click shows the folder in Finder, elsewhere it copies the path.
struct FolderChip: View {
    @EnvironmentObject var store: SessionStore
    var rec: SessionRecord

    var body: some View {
        Button {
            if rec.host == localHost, let p = rec.path {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p)
            } else if let p = rec.path {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(p, forType: .string)
                store.banner = "Copied \(p)"
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: rec.host == localHost ? "laptopcomputer" : "server.rack").font(.system(size: 10))
                Text(store.hostLabel(rec.host)).fontWeight(.medium)
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "folder").font(.system(size: 10))
                Text(store.displayFolder(rec)).lineLimit(1).truncationMode(.head)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(rec.host == localHost ? "Show the folder in Finder" : "Copy the folder's path on \(rec.host)")
    }
}
