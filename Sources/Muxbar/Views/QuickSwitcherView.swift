import AppKit
import MuxbarCore
import SwiftUI

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var query = ""
    /// Frozen while the palette is open: recomputed only when the query changes.
    @Published var rows: [QuickSwitch.Row] = []
    @Published var selection = 0

    func update(_ store: SessionStore, query q: String) {
        rows = store.switcherRows(query: q)
        selection = 0
    }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(0, selection + d), rows.count - 1)
    }
}

/// ⌘K: jump to any session (or run a command) by typing a few letters.
struct QuickSwitcherView: View {
    @EnvironmentObject var store: SessionStore
    @StateObject private var m = SwitcherModel()
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Switch to a session, or type a command", text: $m.query)
                        .textFieldStyle(.plain).font(.title3)
                        .focused($fieldFocused)
                        .onChange(of: m.query) { _, q in m.update(store, query: q) }
                        .onKeyPress(.downArrow) { m.move(1); return .handled }
                        .onKeyPress(.upArrow) { m.move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onKeyPress(.return, phases: .down) { press in
                            open(m.selection, grid: press.modifiers.contains(.option)); return .handled
                        }
                        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                            guard press.modifiers.contains(.command), let n = Int(press.characters), (1...9).contains(n) else { return .ignored }
                            open(n - 1, grid: false); return .handled
                        }
                }
                .padding(12)
                Divider()
                if m.rows.isEmpty {
                    Text(m.query.isEmpty ? "No sessions yet" : "No match").foregroundStyle(.secondary).padding(16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(m.rows.enumerated()), id: \.offset) { i, row in
                                    if i == 0 || m.rows[i - 1].section != row.section {
                                        Text(row.section).font(.caption).foregroundStyle(.secondary)
                                            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
                                    }
                                    SwitcherRow(row: row, index: i, selected: i == m.selection)
                                        .id(i)
                                        .onTapGesture { open(i, grid: NSEvent.modifierFlags.contains(.option)) }
                                }
                            }
                            .padding(.bottom, 6)
                        }
                        .frame(maxHeight: 380)
                        .onChange(of: m.selection) { _, s in proxy.scrollTo(s) }
                    }
                }
                Divider()
                Text("↑↓ move · ⏎ open · ⌥⏎ add to grid · ⌘1–9 open · esc close")
                    .font(.caption2).foregroundStyle(.secondary).padding(6)
            }
            .frame(width: 580)
            .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
            .shadow(radius: 24)
            .padding(.top, 54)
        }
        .onAppear {
            m.query = store.switcherQuery
            m.update(store, query: m.query)
            fieldFocused = true
            store.refreshFirstPrompts()
        }
    }

    private func open(_ i: Int, grid: Bool) {
        guard m.rows.indices.contains(i) else { return }
        store.openSwitcherRow(m.rows[i], toGrid: grid)
    }

    private func close() {
        store.switcherOpen = false
        store.restoreTerminalFocus()
    }
}

/// One palette row; badges read live state (the order doesn't change while open).
struct SwitcherRow: View {
    @EnvironmentObject var store: SessionStore
    var row: QuickSwitch.Row
    var index: Int
    var selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if row.item.kind == .session, let rec = store.state.sessions[row.item.id] {
                Circle().fill(store.status(of: rec).color).frame(width: 8, height: 8)
                if let a = rec.agent ?? store.live[rec.key]?.agent {
                    Text(a.displayName).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.name).lineLimit(1)
                    Text([store.hostLabel(rec.host), rec.group, rec.path.map { ($0 as NSString).lastPathComponent }]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if rec.unread { Circle().fill(Color.blue).frame(width: 7, height: 7).help("Unread") }
                if rec.sleep != nil { Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo).help("Sleeping") }
                if let kb = store.live[rec.key]?.memoryKB, kb >= 1_048_576 {
                    Text(formatKB(kb)).font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "command").foregroundStyle(.secondary).frame(width: 8)
                Text(row.item.title).lineLimit(1)
                Spacer()
            }
            if index < 9 { Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : .clear).padding(.horizontal, 4))
        .contentShape(Rectangle())
    }
}
