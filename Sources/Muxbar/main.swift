import Foundation
import MuxbarCore

let arguments = Array(CommandLine.arguments.dropFirst())
if let i = arguments.firstIndex(of: "--cli") {
    exit(CLI.run(Array(arguments[(i + 1)...])))
}
// Session lists get long: show real scroll bars in Muxbar (per-app override of System Settings →
// Appearance → Show scroll bars). Must be set before AppKit reads it at launch.
UserDefaults.standard.set("Always", forKey: "AppleShowScrollBars")
MuxbarApp.main()
