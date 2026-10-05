import AppKit
import MuxbarCore
import SwiftUI

/// Offscreen render of the session list, used for E2E evidence and bug reports.
@MainActor
enum Snapshot {
    static func render(store: SessionStore, to path: String) throws {
        let view = VStack(alignment: .leading) {
            SessionList(compact: true)
        }
        .padding(12)
        .frame(width: 380, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environmentObject(store)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { throw StoreError("render failed") }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw StoreError("PNG encode failed") }
        try png.write(to: URL(fileURLWithPath: path))
    }

    /// Captures the open popover window (it's a separate NSPanel-like window).
    static func renderPopover(to path: String) throws {
        guard let w = NSApp.windows.first(where: { $0.className.contains("Popover") && $0.isVisible }),
              let view = w.contentView?.superview ?? w.contentView else { throw StoreError("popover not open") }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw StoreError("capture failed") }
        view.cacheDisplay(in: view.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    /// Captures Muxbar's own main window (sidebar + terminal pane) by asking AppKit to draw it.
    static func renderMainWindow(to path: String, id: String = "main") throws {
        guard let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(id) == true && $0.isVisible }),
              let view = w.contentView?.superview ?? w.contentView else { throw StoreError("main window not open") }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw StoreError("capture failed") }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw StoreError("PNG encode failed") }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
