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
        installClickMonitor()
        Updater.shared.start(store: store)
        // Holding ⌥ gives text selection back even when apps get the mouse.
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            self?.store.applyMousePolicy(optionDown: e.modifierFlags.contains(.option))
            return e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.server?.stop()
                // Panes end with the app (their tmux sessions keep running). Without this, a
                // remote pane's `ssh -t … attach` outlived Muxbar as an orphan still attached to
                // its session.
                let n = self?.store.embedded.sessions.count ?? 0
                self?.store.embedded.stopAll(quitting: true)
                Log.info("quitting: ended \(n) pane process(es)")
            }
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
        // A fresh install asks for the root folder and remote hosts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { SetupPresenter.showIfNeeded() }
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
    /// Clicks in a pane: after SwiftTerm has handled one, copy a selection it made or open the web
    /// link under the pointer (the pane's mouse handlers can't be overridden).
    func installClickMonitor() {
        var dragged = false
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window = event.window else { return event }
            switch event.type {
            case .leftMouseDown: dragged = false; return event
            case .leftMouseDragged: dragged = true; return event
            default: break
            }
            let hit = self.store.embedded.sessions.values.first { pane in
                pane.view.window === window && !pane.view.isHiddenOrHasHiddenAncestor
                    && pane.view.bounds.contains(pane.view.convert(event.locationInWindow, from: nil))
            }
            guard let v = hit?.view as? MuxTerminalView else { return event }
            let wasDrag = dragged, count = event.clickCount, at = event.locationInWindow
            dragged = false
            let command = event.modifierFlags.contains(.command)
            DispatchQueue.main.async { v.clickFinished(clickCount: count, dragged: wasDrag, at: at) }
            return command && v.takesCommandClick() ? nil : event
        }
    }

    func installWheelMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = event.window else { return event }
            // The pane under the pointer (in the grid that isn't always the selected one).
            let hit = self.store.embedded.sessions.first { _, pane in
                guard pane.isRunning, pane.view.window === window, !pane.view.isHiddenOrHasHiddenAncestor else { return false }
                return pane.view.bounds.contains(pane.view.convert(event.locationInWindow, from: nil))
            }
            guard let (key, _) = hit, let rec = self.store.state.sessions[key], rec.tmuxID != nil, !rec.ended else { return event }
            // Sent at once (not after the wheel stops); the store coalesces while a command runs.
            self.store.scrollWheel(key, deltaY: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
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
            CommandGroup(after: .pasteboard) {
                Button("Paste Image to Session") { Actions.pasteImage(AppModel.shared.store) }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Quick Switch…") {
                    let s = AppModel.shared.store
                    s.switcherQuery = ""
                    MainWindowPresenter.show()
                    s.switcherOpen.toggle()
                    if !s.switcherOpen { s.restoreTerminalFocus() }
                }
                .keyboardShortcut("k", modifiers: .command)
                Button("Next in Inbox (waiting, then finished)") { Actions.nextWaiting(AppModel.shared.store) }
                    .keyboardShortcut("j", modifiers: .command)
                Button("Search History…") { WindowOpener.open?("history") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Divider()
                Button("Grid / Single View") { AppModel.shared.store.toggleExpand() }
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Focus Tile Left") { AppModel.shared.store.moveTileFocus(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
                Button("Focus Tile Right") { AppModel.shared.store.moveTileFocus(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
                Button("Focus Tile Above") { AppModel.shared.store.moveTileFocus(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.control, .command])
                Button("Focus Tile Below") { AppModel.shared.store.moveTileFocus(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.control, .command])
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

        Window("Set up Muxbar", id: "setup") {
            SetupView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)

        Window("Search History", id: "history") {
            HistoryView()
                .environmentObject(store)
        }

        Window("Continue Claude Session", id: "continue") {
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
    // A test instance runs while the user works: never take focus or cover their windows.
    if TestEnv.isTest {
        for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true && w.isVisible { w.orderBack(nil) }
        return
    }
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
