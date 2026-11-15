import AppKit
import MuxbarCore
import SwiftUI

/// F10: 2–6 live sessions side by side (2), 2×2 (3–4) or 3×2 (5–6).
struct GridPane: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        let keys = store.gridKeys
        let cols = GridLayout.columns(keys.count)
        let rows = stride(from: 0, to: keys.count, by: cols).map { Array(keys[$0..<min($0 + cols, keys.count)]) }
        VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.self) { k in GridTile(key: k) }
                    // Keep columns aligned when the last row is short (3 tiles in 2×2).
                    ForEach(0..<(cols - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
        .padding(6)
    }
}

struct GridTile: View {
    @EnvironmentObject var store: SessionStore
    var key: String

    var body: some View {
        let focused = store.focusedTile == key
        VStack(spacing: 0) {
            if let rec = store.state.sessions[key] {
                TileHeader(rec: rec, focused: focused)
                Divider()
                if rec.ended {
                    VStack(spacing: 8) {
                        Text("Ended").font(.headline)
                        Button("Resume Session") { Actions.resumeEnded(store, rec) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let pane = store.embedded.session(key) {
                    ZStack(alignment: .bottom) {
                        PaneView(pane: pane, rec: rec, takeFocus: focused, tile: true)
                        if let sl = rec.sleep {
                            HStack(spacing: 6) {
                                Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo)
                                Text("Asleep · freed \(formatKB(sl.freedKB))").font(.caption)
                                Spacer()
                                Button("Wake") { Actions.wake(store, rec) }.controlSize(.small)
                            }
                            .padding(6)
                            .background(.regularMaterial)
                        }
                    }
                } else {
                    Text("Connecting…").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1))
    }
}

struct TileHeader: View {
    @EnvironmentObject var store: SessionStore
    var rec: SessionRecord
    var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.status(of: rec).color).frame(width: 8, height: 8)
            if let a = rec.agent ?? store.live[rec.key]?.agent {
                Text(a.displayName).font(.caption2).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
            }
            // Names often share a prefix (muxbar-e2e-g1, -g2…): keep both ends; the host gives way first.
            Text(rec.name).font(.callout).fontWeight(focused ? .semibold : .regular).lineLimit(1)
                .truncationMode(.middle).layoutPriority(1)
            Text(store.hostLabel(rec.host)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if rec.unread { Circle().fill(Color.blue).frame(width: 7, height: 7).help("Unread") }
            if rec.sleep != nil { Image(systemName: "moon.zzz.fill").foregroundStyle(.indigo).font(.caption) }
            Spacer(minLength: 4)
            Button { store.focusTile(rec.key); store.toggleExpand() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Show alone (⌘⏎)")
            Button { store.removeFromGrid(rec.key) } label: { Image(systemName: "xmark") }
                .help("Remove from the grid (keeps running)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(focused ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { store.focusTile(rec.key) }
    }
}
