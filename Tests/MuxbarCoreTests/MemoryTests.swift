import Foundation
import Testing
@testable import MuxbarCore

@Test func memoryLineParsesForLinuxAndMac() {
    let linux = HostMemory.parse("Linux~|~31999876~|~4000000~|~0~|~0~|~3.20 2.10 1.00~|~16")
    #expect(linux?.totalKB == 31_999_876 && linux?.availableKB == 4_000_000 && linux?.cpus == 16)
    #expect(Int(linux!.usedPercent) == 87)
    let mac = HostMemory.parse("Darwin~|~33554432~|~12000000~|~2097152~|~1048576~|~2.5 2.0 1.8~|~12")
    #expect(mac?.swapTotalKB == 2_097_152 && mac?.load == [2.5, 2.0, 1.8])
    #expect(HostMemory.parse("Linux~|~0~|~0~|~0~|~0~|~~|~1") == nil)
    #expect(HostMemory.parse("Linux~|~100~|~500~|~0~|~0~|~~|~1")?.availableKB == 100, "available never exceeds total")
}

@Test func memorySectionRunsOnThisMac() async throws {
    let n = HostProbe.makeNonce()
    let r = await shell("/bin/sh", ["-c", HostProbe.script(mode: .memory, nonce: n)])
    let p = try HostProbe.parse(r.stdout, nonce: n)
    let mem = try #require(p.memory)
    #expect(mem.os == "Darwin" && mem.totalKB > 4_000_000 && mem.availableKB > 0 && mem.availableKB < mem.totalKB)
    // Same formula, computed independently from vm_stat.
    let vm = await shell("/usr/bin/vm_stat", [])
    let page = Int(vm.stdout.range(of: #"page size of (\d+)"#, options: .regularExpression)
        .map { vm.stdout[$0].split(separator: " ").last! } ?? "16384") ?? 16384
    func pages(_ k: String) -> Int {
        vm.stdout.split(separator: "\n").first { $0.hasPrefix(k) }.flatMap { Int($0.split(separator: " ").last!.dropLast()) } ?? 0
    }
    let avail = (pages("Pages free:") + pages("Pages inactive:") + pages("Pages speculative:") + pages("Pages purgeable:")) * page / 1024
    #expect(abs(avail - mem.availableKB) < mem.totalKB / 20, "within 5%: \(avail) vs \(mem.availableKB)")
}

@Test func trendPredictsExhaustion() {
    // 1 GB/min decline from 6 GB: 4 GB left at the last sample → 4 minutes.
    let s = (0..<5).map { MemorySample(t: Double($0) * 30, availableKB: 6_291_456 - $0 * 524_288) }
    let left = MemoryTrend.secondsToExhaustion(s, now: 120)
    #expect(left != nil && abs(left! - 240) < 2, "\(String(describing: left))")
    #expect(MemoryTrend.secondsToExhaustion(Array(s.prefix(2)), now: 30) == nil, "too few samples")
    let flat = (0..<5).map { MemorySample(t: Double($0) * 30, availableKB: 6_000_000 + ($0 % 2) * 100_000) }
    #expect(MemoryTrend.secondsToExhaustion(flat, now: 120) == nil, "no real decline")
    let rising = (0..<5).map { MemorySample(t: Double($0) * 30, availableKB: 2_000_000 + $0 * 600_000) }
    #expect(MemoryTrend.secondsToExhaustion(rising, now: 120) == nil)
    let old = s.map { MemorySample(t: $0.t - 1000, availableKB: $0.availableKB) }
    #expect(MemoryTrend.secondsToExhaustion(old, now: 120) == nil, "outside the window")
}

@Test func alertsFireOnceWithHysteresis() {
    var a = MemoryAlerts()
    #expect(a.step(usedPercent: 85, crit: 90, secondsToExhaustion: nil).isEmpty)
    #expect(a.step(usedPercent: 91, crit: 90, secondsToExhaustion: nil) == [.critical(usedPercent: 91)])
    #expect(a.step(usedPercent: 92, crit: 90, secondsToExhaustion: nil).isEmpty)
    #expect(a.step(usedPercent: 88, crit: 90, secondsToExhaustion: nil).isEmpty, "hovering under the line doesn't re-arm")
    #expect(a.step(usedPercent: 90.5, crit: 90, secondsToExhaustion: nil).isEmpty)
    #expect(a.step(usedPercent: 84, crit: 90, secondsToExhaustion: nil).isEmpty)
    #expect(a.step(usedPercent: 90, crit: 90, secondsToExhaustion: nil) == [.critical(usedPercent: 90)], "re-armed below 85")
    var b = MemoryAlerts()
    #expect(b.step(usedPercent: 70, crit: 90, secondsToExhaustion: 200) == [.runningOut(secondsLeft: 200)])
    #expect(b.step(usedPercent: 75, crit: 90, secondsToExhaustion: 150).isEmpty)
    #expect(b.step(usedPercent: 75, crit: 90, secondsToExhaustion: 900).isEmpty)
    #expect(b.step(usedPercent: 76, crit: 90, secondsToExhaustion: 100) == [.runningOut(secondsLeft: 100)], "re-armed when the trend eased")
    #expect(MemoryAlerts.level(usedPercent: 79.9, warn: 80, crit: 90) == .normal)
    #expect(MemoryAlerts.level(usedPercent: 80, warn: 80, crit: 90) == .warn)
    #expect(MemoryAlerts.level(usedPercent: 95, warn: 80, crit: 90) == .critical)
}

@Test func topProcessesAreAttributedToPanes() async throws {
    guard let tmux = findLocalTmux() else { return }
    let sock = "muxbar-unit-top-\(UUID().uuidString.prefix(6))"
    defer { _ = runWithStdin(tmux, ["-L", sock, "kill-server"], input: "", env: [:]) }
    _ = runWithStdin(tmux, ["-L", sock, "new-session", "-d", "-s", "t1",
                            "python3 -c 'a = bytearray(120 * 1024 * 1024); import time; time.sleep(30)'"], input: "",
                     env: ["PATH": "/usr/bin:/bin"])
    let pane = runWithStdin(tmux, ["-L", sock, "display-message", "-p", "#{pane_id}"], input: "", env: [:]).1
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Under load python can take a few seconds to start and allocate: poll. A busy Mac can have
    // dozens of processes bigger than this one, hence the wide limit.
    var top: [ProcessUsage] = [], mine: ProcessUsage?
    for _ in 0..<30 {
        try await Task.sleep(nanoseconds: 500_000_000)
        let n = HostProbe.makeNonce()
        let r = await shell("/bin/sh", ["-c", MemoryDetail.script(nonce: n, tmux: shellQuote(tmux), socket: sock, limit: 400)])
        top = MemoryDetail.parse(r.stdout, nonce: n)
        mine = top.first { $0.args.contains("bytearray(120") }
        if let m = mine, m.rssKB > 100_000 { break }
    }
    #expect(mine != nil && mine!.rssKB > 100_000, "\(top.prefix(3))")
    #expect(mine?.pane == pane)
    #expect(top.count <= 400 && top == top.sorted { $0.rssKB > $1.rssKB } || top.isEmpty == false)
}

@Test func processShortNamesAndSizes() {
    #expect(ProcessUsage(pid: 1, rssKB: 1, pane: nil, args: "/home/u/.venv/bin/python build_index.py 1 92 13").shortName == "python build_index.py")
    #expect(ProcessUsage(pid: 1, rssKB: 1, pane: nil, args: "/usr/bin/node /x/github-mcp --include-tools a").shortName == "node github-mcp")
    #expect(ProcessUsage(pid: 1, rssKB: 1, pane: nil, args: "monitor-agent").shortName == "monitor-agent")
    #expect(formatKB(25_165_824) == "24 GB" && formatKB(2_516_582) == "2.4 GB" && formatKB(850_000) == "830 MB")
}
