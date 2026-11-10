import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: GhosttyRuntime?
    private var controller: NotchController?
    private let hotKey = DoubleCommandHotKey()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime = GhosttyRuntime() else {
            let alert = NSAlert()
            alert.messageText = "Quick Term couldn't start the terminal"
            alert.informativeText = "libghostty failed to initialise. Check Console for messages from quick-term."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.runtime = runtime

        let controller = NotchController(runtime: runtime)
        self.controller = controller

        hotKey.onTrigger = { [weak controller] in controller?.toggle() }
        // A second copy run for testing must not react to the shortcut too.
        if ProcessInfo.processInfo.environment["QUICKTERM_TEST"] == nil { hotKey.start() }

        // Drop down once on a manual launch so it's clear the app is running;
        // stay tucked away when started silently (e.g. at login).
        if !CommandLine.arguments.contains("--hidden") && !launchedAsLoginItem {
            controller.show()
        }
    }

    /// Opening the app again while it is running summons the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
