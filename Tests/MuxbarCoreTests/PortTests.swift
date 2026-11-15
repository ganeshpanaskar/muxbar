import Foundation
import Testing
@testable import MuxbarCore

/// `ss -ltnpH` lines as a Linux host prints them, plus IPv6 and interface-suffixed forms.
let ssFixture = """
LISTEN 0      10             0.0.0.0:8443  0.0.0.0:*
LISTEN 0      256        192.168.0.1:53    0.0.0.0:*
LISTEN 0      4096         127.0.0.1:17922 0.0.0.0:* users:(("otelcol-contrib",pid=2401,fd=8))
LISTEN 0      128            0.0.0.0:22    0.0.0.0:*
LISTEN 0      5            127.0.0.1:8765  0.0.0.0:* users:(("python3",pid=4242,fd=3))
LISTEN 0      5              0.0.0.0:8766  0.0.0.0:* users:(("python3",pid=4243,fd=3))
LISTEN 0      511               [::]:3000     [::]:* users:(("node",pid=5150,fd=21))
LISTEN 0      511            0.0.0.0:3000  0.0.0.0:* users:(("node",pid=5150,fd=20))
LISTEN 0      128              [::1]:5432     [::]:* users:(("postgres",pid=777,fd=6))
LISTEN 0      128          10.0.0.12:9000  0.0.0.0:* users:(("java",pid=888,fd=9))
LISTEN 0      128      127.0.0.53%lo:53    0.0.0.0:* users:(("systemd-resolve",pid=999,fd=12))
LISTEN 0      128                  *:22          *:* users:(("sshd",pid=1,fd=3))
"""

@Test func ssLinesBecomeForwardablePortsOfYours() {
    let ports = PortScan.merge(ssFixture.split(separator: "\n").compactMap { PortScan.parseSS(String($0)) })
    let byPort = Dictionary(uniqueKeysWithValues: ports.map { ($0.port, $0) })
    // Only sockets with users:( (yours), reachable through loopback, never 22.
    #expect(ports.map(\.port) == [3000, 5432, 8765, 8766, 17922])
    #expect(byPort[8765]?.process == "python3" && byPort[8765]?.pid == 4242 && byPort[8765]?.address == "127.0.0.1")
    #expect(byPort[8766]?.address == "0.0.0.0")
    #expect(byPort[3000]?.address == "0.0.0.0")            // IPv4 wins over [::] for the same port
    #expect(byPort[5432]?.target == "[::1]")               // an IPv6-only loopback server
    #expect(byPort[8765]?.target == "127.0.0.1")
    #expect(byPort[9000] == nil && byPort[53] == nil)       // other interface; resolver on 127.0.0.53
}

@Test func procNetTCPAddressesAndTheFallbackPath() throws {
    #expect(PortScan.parseProcAddress("0100007F:2229")! == ("127.0.0.1", 8745))
    #expect(PortScan.parseProcAddress("00000000:20FB")! == ("0.0.0.0", 8443))
    #expect(PortScan.parseProcAddress("0100A8C0:0035")! == ("192.168.0.1", 53))
    #expect(PortScan.parseProcAddress("00000000000000000000000000000000:0016")! == ("::", 22))
    #expect(PortScan.parseProcAddress("00000000000000000000000001000000:1538")! == ("::1", 5432))
    #expect(PortScan.parseProcAddress("0000000000000000FFFF00000100007F:1F90")! == ("127.0.0.1", 8080))
    #expect(PortScan.parseProcAddress("zz") == nil)
    // A whole probe in fallback mode: PTCP + PFD (inode → pid) + PO (pid → pane).
    let n = "abc"
    let out = """
    @@\(n) VER tmux 3.4
    @@\(n) S~|~$1~|~1~|~1~|~0~|~web
    @@\(n) P~|~$1~|~1~|~1~|~zsh~|~1~|~%3~|~100~|~/tmp
    @@\(n) PORTS
    @@\(n) PTCP~|~0100007F:223D~|~555
    @@\(n) PTCP~|~0100007F:1F91~|~556
    @@\(n) PFD~|~4242~|~555
    @@\(n) PO~|~4242~|~%3~|~python3
    @@\(n) END
    """
    let r = try HostProbe.parse(out, nonce: n)
    #expect(r.ports == [ListeningPort(port: 8765, address: "127.0.0.1", pid: 4242, process: "python3", pane: "%3")])
    // No PORTS marker (macOS, or an older probe): not scanned at all.
    #expect(try HostProbe.parse("@@\(n) VER tmux 3.4\n@@\(n) END\n", nonce: n).ports == nil)
}

@Test func localPortIsTheSameNumberOrTheNextFreeAndPrivilegedPortsMoveUp() {
    #expect(PortScan.localPort(for: 8080) { _ in true } == 8080)
    #expect(PortScan.localPort(for: 8080) { $0 != 8080 && $0 != 8081 } == 8082)
    #expect(PortScan.localPort(for: 80) { _ in true } == 10080)
    #expect(PortScan.localPort(for: 443) { _ in true } == 10443)
    #expect(PortScan.localPort(for: 65535) { _ in false } == nil)
    // A port we hold is not free; it is once we let go.
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0; addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(fd, 1)
    var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let held = Int(UInt16(bigEndian: bound.sin_port))
    #expect(!PortScan.isFreeLocal(held))
    // A connection that closes server-side first leaves the port in TIME_WAIT: still free for a
    // new listener (ssh binds with SO_REUSEADDR too).
    let c = socket(AF_INET, SOCK_STREAM, 0)
    var to = bound
    _ = withUnsafePointer(to: &to) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(c, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    let s2 = accept(fd, nil, nil)
    close(s2)      // server side closes first → TIME_WAIT on `held`
    usleep(100_000)
    close(c)
    close(fd)
    usleep(300_000)   // let the close handshake finish (server side → TIME_WAIT)
    #expect(PortScan.isFreeLocal(held))
}

@Test func forwardsAreLoopbackOnlyThroughTheExistingMaster() {
    let a = PortScan.controlArguments("forward", host: "devbox", local: 8081, target: "127.0.0.1", remote: 8080, sshConfigFile: nil)
    #expect(a.contains("-O") && a.contains("forward") && a.contains("127.0.0.1:8081:127.0.0.1:8080"))
    #expect(a.suffix(2) == ["--", "devbox"])
    #expect(a.contains { $0.hasPrefix("ControlPath=") })
}
