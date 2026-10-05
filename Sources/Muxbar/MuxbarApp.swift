import AppKit
import MuxbarCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel {
    static let shared = AppModel()
    let store: SessionStore
    private var server: ControlServer?

    private init() {
        MuxbarPaths.ensureDirs()
        Log.path = MuxbarPaths.logDir + "/app.log"
        Log.info("Muxbar \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") starting (pid \(ProcessInfo.processInfo.processIdentifier))")
        store = SessionStore()
        let store = self.store
        server = ControlServer { req in
            await MainActor.run { () -> Task<[String: Any], Never> in
                Task { @MainActor in await ControlHandler.handle(store, req) }
            }.value
        }
        server?.start()
        installWheelMonitor()
        Updater.shared.start(store: store)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.server?.stop() }
        }
    }
}

/// Opening Muxbar.app again (Finder, Spotlight, `open`) shows the main window. The menu-bar
/// icon can be hidden behind the notch on a crowded menu bar, so the window must be reachable.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIconController.shared.start()
        DispatchQueue.main.async { activateApp() }
        // Window restoration can keep the main window closed across launches; always show it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { MainWindowPresenter.show() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        activateApp()
        if let w = sender.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
            return false
        }
        return true   // lets SwiftUI recreate the main window
    }
}

extension AppModel {
    /// Wheel/trackpad over a tmux-backed pane scrolls the session's history (SwiftTerm can't pass
    /// the wheel to tmux itself). Plain panes keep SwiftTerm's own scrollback.
    func installWheelMonitor() {
        var pending: CGFloat = 0
        var flush: DispatchWorkItem?
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let key = self.store.selectedKey,
                  let rec = self.store.state.sessions[key], rec.tmuxID != nil, !rec.ended,
                  let pane = self.store.embedded.session(key), pane.isRunning,
                  event.window === pane.view.window else { return event }
            let p = pane.view.convert(event.locationInWindow, from: nil)
            guard pane.view.bounds.contains(p) else { return event }
            // Precise (trackpad) deltas are points; classic wheel deltas are lines.
            pending += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 16 : event.scrollingDeltaY * 3
            flush?.cancel()
            let work = DispatchWorkItem { [weak self] in
                let lines = Int(pending.rounded())
                pending -= CGFloat(lines)
                if lines != 0 { self?.store.scrollPane(key, lines: lines) }
            }
            flush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            return nil
        }
    }
}

struct MuxbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppModel.shared.store

    var body: some Scene {
        // First scene: SwiftUI opens it at launch and on reopen.
        Window("Muxbar", id: "main") {
            MainWindow()
                .background(MainWindowOpenerCapture())
                .environmentObject(store)
                .frame(minWidth: 560, minHeight: 380)
        }
        .defaultSize(width: 720, height: 520)
        .commands {
            CommandMenu("Go") {
                Button("Next Waiting Session") { Actions.nextWaiting(AppModel.shared.store) }
                    .keyboardShortcut("j", modifiers: .command)
            }
        }

        MenuBarExtra {
            MenuContent()
                .environmentObject(store)
        } label: {
            MenuBarIcon().environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("New Session", id: "new") {
            NewSessionView()
                .environmentObject(store)
                .frame(width: 460)
        }
        .windowResizability(.contentSize)

        Window("Continue Agent Session", id: "continue") {
            ContinueView()
                .environmentObject(store)
                .frame(width: 640, height: 480)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

struct MenuBarIcon: View {
    @EnvironmentObject var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var glyph = MenuGlyphAnimator()

    var body: some View {
        let waiting = store.state.sessions.values.contains { store.status(of: $0) == .waiting }
        Image(nsImage: glyph.image)
            .task {
                MainWindowPresenter.openMain = { openWindow(id: "main") }
                WindowOpener.open = { openWindow(id: $0) }
                WindowOpener.openSettings = { openSettings() }
            }
            .onAppear { glyph.update(waiting: waiting); MenuGlyphState.shared.animator = glyph }
            .onChange(of: waiting) { _, w in glyph.update(waiting: w) }
    }
}

/// SwiftUI openWindow captured for test hooks.
@MainActor
enum WindowOpener {
    static var open: ((String) -> Void)?
    static var openSettings: (() -> Void)?
}

/// Lets the CLI report the menu-bar glyph state (test hook).
@MainActor
final class MenuGlyphState {
    static let shared = MenuGlyphState()
    weak var animator: MenuGlyphAnimator?
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// macOS 14+ uses cooperative activation and may ignore `activate(ignoringOtherApps:)`, so also
/// order the main window front explicitly.
@MainActor
func activateApp() {
    NSApp.activate()
    for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true && w.isVisible {
        w.orderFrontRegardless()
    }
}

/// Also capture openWindow from the main window itself, in case the menu-bar label never ran.
struct MainWindowOpenerCapture: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task {
                if MainWindowPresenter.openMain == nil { MainWindowPresenter.openMain = { openWindow(id: "main") } }
                if WindowOpener.open == nil { WindowOpener.open = { openWindow(id: $0) } }
            }
    }
}
