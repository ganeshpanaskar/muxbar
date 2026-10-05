import AppKit
import MuxbarCore

/// Keeps a source install current: on launch and once a day it asks GitHub for the latest release.
/// Same-major releases are installed in the background (git fetch of the tag + install.sh, which
/// relaunches the app; sessions keep running in tmux). A new major version asks first.
@MainActor
final class Updater {
    static let shared = Updater()
    private weak var store: SessionStore?
    private var timer: Timer?
    private var asked = Set<String>()   // major versions already offered this run
    private(set) var running = false
    private(set) var lastResult = "not checked"

    static var currentVersion: SemVer {
        SemVer(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? SemVer(0, 0, 0)
    }

    static var logPath: String { MuxbarPaths.logDir + "/update.log" }

    func start(store: SessionStore) {
        self.store = store
        announceIfJustUpdated()
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in _ = Task<Void, Never> { await self?.check() } }
        timer = Timer.scheduledTimer(withTimeInterval: Updates.interval, repeats: true) { _ in
            MainActor.assumeIsolated { _ = Task<Void, Never> { await Updater.shared.check() } }
        }
    }

    /// - Parameters:
    ///   - manual: the user asked ("Check now"): report the result even when up to date, and
    ///     check even if automatic checks are off.
    ///   - simulated: test hook — use this release instead of asking GitHub.
    ///   - apply: false = only decide (test hook).
    @discardableResult
    func check(manual: Bool = false, simulated: ReleaseInfo? = nil, apply: Bool = true) async -> Updates.Decision {
        guard let store, manual || simulated != nil || store.settings.checkForUpdates else { return .upToDate }
        let latest: ReleaseInfo?, reached: Bool
        if let simulated { (latest, reached) = (simulated, true) } else { (latest, reached) = await Self.fetchLatest() }
        let decision = Updates.decide(current: Self.currentVersion, latest: latest)
        switch decision {
        case .upToDate:
            lastResult = reached ? "up to date (\(Self.currentVersion))" : "couldn't reach GitHub"
            if manual { store.banner = reached ? "Muxbar \(Self.currentVersion) is the latest version." : "Couldn't check for updates (no connection to GitHub)." }
        case .automatic(let r):
            lastResult = "updating to \(r.tag)"
            if apply { install(r) }
        case .askFirst(let r):
            lastResult = "major update \(r.tag) available"
            if apply && (manual || !asked.contains(r.tag)) {
                asked.insert(r.tag)
                askAboutMajor(r)
            }
        }
        Log.info("update check: \(lastResult)")
        return decision
    }

    /// The latest release, and whether GitHub answered (404 = no releases published yet).
    private static func fetchLatest() async -> (ReleaseInfo?, Bool) {
        var req = URLRequest(url: Updates.latestReleaseAPI, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Muxbar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return (nil, false) }
        switch code {
        case 200: return (Updates.parseRelease(data), true)
        case 404: return (nil, true)
        default: return (nil, false)
        }
    }

    private func askAboutMajor(_ r: ReleaseInfo) {
        let alert = NSAlert()
        alert.messageText = "Muxbar \(r.version) is available"
        let notes = r.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "This is a major update (you have \(Self.currentVersion)), so it may change how things work."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(700)) + (notes.count > 700 ? "…" : ""))
            + "\n\nUpdating rebuilds and restarts Muxbar. Your sessions keep running in tmux."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(r)
        case .alertThirdButtonReturn: if let u = URL(string: r.url) { NSWorkspace.shared.open(u) }
        default: break
        }
    }

    /// Runs the update script detached; install.sh quits and relaunches this app. If the script
    /// fails, the app is still running and shows why.
    private func install(_ r: ReleaseInfo) {
        guard !running, let store else { return }
        guard Updates.isSafeTag(r.tag) else { Log.error("update: ignoring odd tag \(r.tag)"); return }
        guard let conf = try? String(contentsOfFile: NSHomeDirectory() + "/.muxbar/install.conf", encoding: .utf8),
              let src = Updates.sourceDir(conf: conf),
              FileManager.default.isExecutableFile(atPath: src + "/install.sh") else {
            store.banner = "Muxbar \(r.version) is available. Update with: git pull && ./install.sh"
            return
        }
        running = true
        store.banner = "Updating Muxbar to \(r.version)… it will restart by itself."
        Log.info("update: installing \(r.tag) from \(src)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", Updates.updateScript(sourceDir: src, tag: r.tag)]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        FileManager.default.createFile(atPath: Self.logPath, contents: nil)
        let log = FileHandle(forWritingAtPath: Self.logPath)
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let code = proc.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let u = Updater.shared
                    u.running = false
                    guard code != 0 else { return }
                    let why = (try? String(contentsOfFile: Updater.logPath, encoding: .utf8))?
                        .split(separator: "\n").last.map(String.init) ?? "exit \(code)"
                    u.lastResult = "update failed: \(why)"
                    u.store?.banner = "Couldn't update to \(r.version): \(why). Details: \(Updater.logPath)"
                    Log.error("update: failed (\(code)): \(why)")
                }
            }
        }
        do { try p.run() } catch {
            running = false
            store.banner = "Couldn't start the update: \(error.localizedDescription)"
        }
    }

    /// After a relaunch into a newer version, say so once.
    private func announceIfJustUpdated() {
        let d = UserDefaults.standard
        let now = Self.currentVersion.description
        if let prev = d.string(forKey: "lastRunVersion"), let pv = SemVer(prev), pv < Self.currentVersion {
            store?.banner = "Muxbar was updated to \(now)."
        }
        d.set(now, forKey: "lastRunVersion")
    }
}
