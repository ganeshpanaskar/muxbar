import Foundation
import Testing
@testable import MuxbarCore

@Test func dropNamesAreSafeShortAndKeepTheExtension() {
    let d = Date(timeIntervalSince1970: 1_792_000_000)   // a fixed moment
    let time = { () -> String in let f = DateFormatter(); f.dateFormat = "HHmmss"; return f.string(from: d) }()
    #expect(DropNaming.remoteName(original: "Screenshot 2026-10-14 at 4.05.12 PM.png", date: d)
            == "\(time)-Screenshot-2026-10-14-at-4.05.12-PM.png")
    #expect(DropNaming.remoteName(original: "/x/y/naïve file ;rm -rf ~.txt", date: d) == "\(time)-na-ve-file-rm-rf.txt")
    let long = DropNaming.remoteName(original: String(repeating: "a", count: 300) + ".jpeg", date: d, unique: "2")
    #expect(long.count <= 80 && long.hasSuffix("-2.jpeg"))
    #expect(DropNaming.remoteName(original: "...", date: d) == "\(time)-drop")
    #expect(DropNaming.remoteDir(date: d).hasPrefix("~/.muxbar/drops/2026-"))
}

@Test func pastedPathsAreQuotedOnlyWhenNeeded() {
    #expect(DropNaming.pasteText(["/home/u/.muxbar/drops/2026-10-14/160512-shot.png"]) == "/home/u/.muxbar/drops/2026-10-14/160512-shot.png ")
    #expect(DropNaming.pasteText(["/Users/u/Desktop/My Shot.png", "/tmp/a"]) == "'/Users/u/Desktop/My Shot.png' /tmp/a ")
    #expect(DropNaming.pasteText(["/tmp/it's"]) == "'/tmp/it'\\''s' ")
}

@Test func pasteBytesAreBracketedOnlyWhenAskedAndControlCharactersAreRefused() {
    #expect(DropNaming.pasteBytes("/tmp/a.png ", bracketed: true) == "\u{1B}[200~/tmp/a.png \u{1B}[201~")
    #expect(DropNaming.pasteBytes("/tmp/a.png ", bracketed: false) == "/tmp/a.png ")
    #expect(!DropNaming.unsafeToPaste("/Users/me/Screen Shot 2026-10-14 at 1.02.03 PM.png"))
    #expect(!DropNaming.unsafeToPaste("/tmp/café ünïcode.png"))
    #expect(DropNaming.unsafeToPaste("/tmp/x\u{1B}[201~\rrm -rf ~.png"))
    #expect(DropNaming.unsafeToPaste("/tmp/two\nlines.png"))
    #expect(DropNaming.unsafeToPaste("/tmp/c1\u{9B}201~.png"))
}

@Test func uploadScriptWritesPrivatelyAndReportsThePath() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("muxbar-unit-drop-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let bytes = Data((0..<300_000).map { UInt8($0 % 251) })
    let r = await runProcess("/bin/sh", ["-c", DropNaming.uploadScript(dir: "~/.muxbar/drops/2026-10-14", name: "120000-x.png")],
                             timeout: 20, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], stdin: bytes)
    let up = try #require(DropNaming.parseUpload(r.stdout), "\(r.stdout) \(r.stderr)")
    #expect(up.bytes == bytes.count && up.path.hasSuffix("/.muxbar/drops/2026-10-14/120000-x.png"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: up.path)) == bytes)
    let mode = try FileManager.default.attributesOfItem(atPath: up.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
    // Cleanup removes only old drops.
    let old = home.appendingPathComponent(".muxbar/drops/2026-09-01/old.png")
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: old)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-9 * 86400)], ofItemAtPath: old.path)
    _ = await runProcess("/bin/sh", ["-c", DropNaming.cleanupScript], timeout: 20, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
    #expect(!FileManager.default.fileExists(atPath: old.path) && !FileManager.default.fileExists(atPath: old.deletingLastPathComponent().path))
    #expect(FileManager.default.fileExists(atPath: up.path))
}
