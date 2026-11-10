import AppKit
import GhosttyKit

// libghostty finds its shell integration, terminfo and bundled themes through
// this directory. Inside the .app bundle it is discovered automatically; this
// covers running the bare binary during development.
if ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil,
   let bundled = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
   FileManager.default.fileExists(atPath: bundled) {
    setenv("GHOSTTY_RESOURCES_DIR", bundled, 1)
}

// Only the program name is passed on: libghostty would otherwise read launch
// arguments as its own CLI flags.
var argv: [UnsafeMutablePointer<CChar>?] = [CommandLine.unsafeArgv[0], nil]
guard ghostty_init(1, &argv) == GHOSTTY_SUCCESS else {
    FileHandle.standardError.write(Data("quick-term: ghostty_init failed\n".utf8))
    exit(1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
