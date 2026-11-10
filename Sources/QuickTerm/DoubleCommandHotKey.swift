import AppKit
import IOKit.hidsystem

/// Fires when the left and right Command keys are held down together.
///
/// The modifier state is read straight from the system, which needs no
/// Accessibility or Input Monitoring permission. Modifier-change events make
/// the response immediate when they are delivered; the timer covers the cases
/// where macOS withholds them from background apps.
final class DoubleCommandHotKey {
    var onTrigger: (() -> Void)?

    private var armed = true
    private var monitors: [Any] = []
    private var timer: Timer?

    func start() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] _ in
            self?.check()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            self?.check()
            return event
        }) {
            monitors.append(local)
        }

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.check() }
        timer.tolerance = 1.0 / 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func check() {
        // Only the device-specific bits tell the two Command keys apart;
        // CGEventSource.keyState reports either one as the left key.
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        let left = flags & UInt64(NX_DEVICELCMDKEYMASK) != 0
        let right = flags & UInt64(NX_DEVICERCMDKEYMASK) != 0

        if left && right {
            // Fire once per chord; either key has to come up before the next.
            guard armed else { return }
            armed = false
            onTrigger?()
        } else {
            armed = true
        }
    }
}
