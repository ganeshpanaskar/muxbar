import Foundation
import Testing
@testable import MuxbarCore

@Test func hostAddressesAreValidatedSoTheyCantInjectSSHOptions() throws {
    #expect(try HostAddress.normalize("devbox.example.com") == "devbox.example.com")
    #expect(try HostAddress.normalize("devbox") == "devbox")
    #expect(try HostAddress.normalize("user@devbox") == "user@devbox")
    #expect(try HostAddress.normalize("  ssh devbox\n") == "devbox")
    #expect(try HostAddress.normalize("my_box.lan") == "my_box.lan")
    for bad in ["-oProxyCommand=touch /tmp/x", "-oProxyCommand=x", "a b", "local", "LOCAL", "h;rm -rf ~", "h$(id)", "",
                "   ", ".hidden", "user@-x", "ssh -p 2222 host", "host:22", "x\u{1B}[201~", String(repeating: "a", count: 300)] {
        #expect(throws: HostAddress.Invalid.self, "\(bad.debugDescription)") { try HostAddress.normalize(bad) }
    }
}

@Test func hostCheckExplainsEachFailureInPlainWords() {
    func r(_ out: String = "", _ err: String = "", _ code: Int32 = 255, timedOut: Bool = false) -> RunResult {
        RunResult(stdout: out, stderr: err, exitCode: code, timedOut: timedOut)
    }
    #expect(HostCheck.parse(r("MBX_CHECK os=Linux\nMBX_CHECK tmux=tmux 3.4\n", "", 0)) == .ok(os: "Linux", tmux: "tmux 3.4"))
    #expect(HostCheck.parse(r("MBX_CHECK os=Linux\nMBX_CHECK tmux=\n", "", 0)) == .noTmux(os: "Linux"))
    // Real ssh error texts (OpenSSH on macOS and Linux).
    #expect(HostCheck.parse(r("", "user@devbox-x.example.com: Permission denied (publickey).\r\n")) == .auth)
    #expect(HostCheck.parse(r("", "No ED25519 host key is known for newbox and you have requested strict checking.\r\nHost key verification failed.\r\n")) == .hostKey)
    #expect(HostCheck.parse(r("", "ssh: Could not resolve hostname nonexistent.invalid: nodename nor servname provided, or not known\n")) == .dns)
    #expect(HostCheck.parse(r("", "ssh: connect to host 127.0.0.1 port 1: Connection refused\n")) == .refused)
    #expect(HostCheck.parse(r("", "ssh: connect to host 192.0.2.1 port 22: Operation timed out\n")) == .unreachable)
    #expect(HostCheck.parse(r("", "", -1, timedOut: true)) == .unreachable)
    #expect(HostCheck.parse(r("", "kex_exchange_identification: read: Connection reset by peer\n")) == .other("kex_exchange_identification: read: Connection reset by peer"))
    #expect(HostCheck.Result.auth.message(host: "h").contains("ssh h"))
    #expect(HostCheck.Result.hostKey.message(host: "newbox").contains("ssh newbox"))
}

@Test func hostCheckScriptRunsLocally() async {
    let r = await runProcess("/bin/sh", ["-c", HostCheck.script], timeout: 20)
    let c = HostCheck.parse(r)
    if findLocalTmux() != nil {
        guard case .ok(let os, let tmux) = c else { Issue.record("\(c) \(r)"); return }
        #expect(os == "Darwin" && tmux.hasPrefix("tmux "))
    } else {
        #expect(c == .noTmux(os: "Darwin"))
    }
}

@Test func sessionsKeepTheRootTheyWereMadeUnder() {
    #expect(Workspace.rootOf(managedDir: "~/Muxbar/api/fix-login", group: "api") == "~/Muxbar")
    #expect(Workspace.rootOf(managedDir: "~/Muxbar/fix-login", group: nil) == "~/Muxbar")
    #expect(Workspace.rootOf(managedDir: "/data/ws/g/s", group: "g") == "/data/ws")
    #expect(Workspace.rootOf(managedDir: "/s", group: nil) == "/")
    #expect(Workspace.rootOf(managedDir: "s", group: "g") == nil)
    // A root changed later: the session's own root, not the new one.
    let old = Workspace.path(root: "/tmp/rootA", group: "g", session: "one")
    #expect(Workspace.path(root: Workspace.rootOf(managedDir: old, group: "g")!, group: "g", session: "renamed") == "/tmp/rootA/g/renamed")
    #expect(Workspace.isValidRoot("~/Muxbar") && Workspace.isValidRoot("/data/ws") && Workspace.isValidRoot("~"))
    #expect(!Workspace.isValidRoot("Muxbar") && !Workspace.isValidRoot("") && !Workspace.isValidRoot("~/a\nb"))
}

@Test func setupIsOfferedOnlyToFreshInstalls() throws {
    var st = AppState()
    #expect(st.looksFresh && st.settings.setupDone == nil)
    st.hosts.append("devbox")
    #expect(!st.looksFresh)
    // Settings written before setupDone existed decode as "never decided".
    let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"terminal":"embedded","memWarnPct":75}"#.utf8))
    #expect(old.setupDone == nil && old.memWarnPct == 75)
    var s = AppSettings(); s.setupDone = true
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s)).setupDone == true)
}
