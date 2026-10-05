import AppKit
import MuxbarCore
import SwiftUI
import WebKit

/// App icon: C2 Graphite normally, C8 Midnight Glow in dark mode. Light/dark bundle icon
/// variants need Xcode's asset compiler, so the Dock icon is swapped at runtime instead
/// (Finder keeps showing the C2 bundle icon).
@MainActor
final class AppIconController {
    static let shared = AppIconController()
    private var observation: NSKeyValueObservation?

    func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            Task { @MainActor in AppIconController.shared.apply() }
        }
    }

    var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    func apply() {
        let name = isDark ? "AppIcon-dark" : "AppIcon-light"
        if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }
}

/// The 09 Card Shuffle menu-bar glyph, drawn natively (template image, crisp at any scale).
/// `phase` 0…1 runs the shuffle: the front card dips and fades, then the deck re-forms.
enum MenuGlyph {
    static func image(phase: Double?) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ w: CGFloat, _ a: CGFloat) {
                ctx.setStrokeColor(NSColor.black.withAlphaComponent(a).cgColor)
                ctx.setLineWidth(w)
                ctx.move(to: CGPoint(x: x1, y: y1)); ctx.addLine(to: CGPoint(x: x2, y: y2)); ctx.strokePath()
            }
            line(5.5, 2.2, 12.5, 2.2, 1.4, 0.55)   // back card
            line(3.8, 4.6, 14.2, 4.6, 1.4, 1)      // middle card
            // Front card: matches muxbar-09-menubar-anim.svg keyTimes 0;0.6;0.8;1.
            var dy: CGFloat = 0, alpha: CGFloat = 1
            if let p = phase {
                let ease = { (t: Double) -> Double in t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
                if p > 0.6 && p <= 0.8 { let t = ease((p - 0.6) / 0.2); dy = 2.5 * t; alpha = 1 - 0.8 * t }
                else if p > 0.8 { let t = ease((p - 0.8) / 0.2); dy = 2.5 * (1 - t); alpha = 0.2 + 0.8 * t }
            }
            ctx.saveGState()
            ctx.translateBy(x: 0, y: dy)
            ctx.setAlpha(alpha)
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 2.25, y: 7, width: 13.5, height: 9), cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
            ctx.strokePath()
            ctx.setLineWidth(1.4)
            ctx.move(to: CGPoint(x: 5.2, y: 9.8)); ctx.addLine(to: CGPoint(x: 7.2, y: 11.5)); ctx.addLine(to: CGPoint(x: 5.2, y: 13.2))
            ctx.strokePath()
            ctx.move(to: CGPoint(x: 8.8, y: 13.2)); ctx.addLine(to: CGPoint(x: 11, y: 13.2)); ctx.strokePath()
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Static glyph with a small dot: the "waiting" signal when Reduce Motion is on.
    static func waitingStatic() -> NSImage {
        let base = image(phase: nil)
        let img = NSImage(size: base.size, flipped: true) { r in
            base.draw(in: r)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 13, y: 0.5, width: 4.5, height: 4.5)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Drives the menu-bar glyph: still normally; shuffles while any session waits for input.
@MainActor
final class MenuGlyphAnimator: ObservableObject {
    @Published private(set) var image = MenuGlyph.image(phase: nil)
    private var timer: Timer?
    private var start = Date()
    private(set) var animating = false

    func update(waiting: Bool) {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if waiting && reduce {
            stop(); image = MenuGlyph.waitingStatic(); return
        }
        guard waiting != animating else { return }
        if waiting {
            animating = true
            start = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let p = Date().timeIntervalSince(self.start).truncatingRemainder(dividingBy: 2) / 2
                    self.image = MenuGlyph.image(phase: p)
                }
            }
        } else {
            stop()
            image = MenuGlyph.image(phase: nil)
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil; animating = false
    }
}

/// The animated Card Shuffle icon (C2, or C8 in dark mode), shown while no session is selected.
struct LaunchAnimationView: NSViewRepresentable {
    var dark: Bool

    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero)
        w.setValue(false, forKey: "drawsBackground")
        load(w)
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        if context.coordinator.dark != dark { load(w) }
        context.coordinator.dark = dark
    }

    func makeCoordinator() -> Coord { Coord(dark: dark) }
    final class Coord { var dark: Bool; init(dark: Bool) { self.dark = dark } }

    private func load(_ w: WKWebView) {
        guard let url = Bundle.main.url(forResource: dark ? "launch-dark" : "launch-light", withExtension: "svg"),
              let svg = try? String(contentsOf: url, encoding: .utf8) else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let html = """
        <html><head><style>html,body{margin:0;height:100%;background:transparent;display:flex;
        align-items:center;justify-content:center;overflow:hidden}svg{width:100%;height:100%}
        \(reduce ? "*{animation:none!important}" : "")</style></head><body>\(svg)</body></html>
        """
        w.loadHTMLString(html, baseURL: nil)
    }
}
