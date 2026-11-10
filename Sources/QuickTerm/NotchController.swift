import AppKit
import GhosttyKit
import ServiceManagement

/// A borderless panel that takes keyboard focus without activating the app,
/// so the app you were in stays frontmost and gets focus back on dismissal.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // The panel's transparent margin overlaps the menu bar; AppKit would
    // otherwise push the whole panel down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the glass card in the middle of the screen and the terminals inside it.
final class NotchController: NSObject, NSWindowDelegate, GhosttyRuntimeDelegate {
    private let runtime: GhosttyRuntime
    private let panel: NotchPanel
    private let glass = NSGlassEffectView()
    private let clip = NSView()
    private let header = HeaderView()
    private let shadow = CALayer()
    private let shadowMask = CAShapeLayer()
    private let splits = SplitView()
    /// The split that has, or last had, keyboard focus.
    private weak var focused: TerminalView?

    private var geometry: Geometry?
    private var isShown = false
    private var appearanceObservation: NSKeyValueObservation?

    // Spring state. `progress` is 0 when dismissed and 1 when fully open.
    private var progress: CGFloat = 0
    private var velocity: CGFloat = 0
    private var target: CGFloat = 0
    private var displayLink: CADisplayLink?
    private var onSettle: (() -> Void)?

    private enum Metrics {
        /// Transparent room around the card for its shadow and spring overshoot.
        static let margin: CGFloat = 64
        static let radius: CGFloat = 26
        static let headerHeight: CGFloat = 30
        static let defaultSize = CGSize(width: 1066, height: 611)
        /// How strongly the glass is tinted with the terminal background.
        static let tintAlpha: CGFloat = 0.5
        /// How small the card starts.
        static let startScale: CGFloat = 0.97
    }

    init(runtime: GhosttyRuntime) {
        self.runtime = runtime
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true)
        super.init()

        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false

        let root = NSView()
        root.wantsLayer = true
        panel.contentView = root

        // The shadow is its own layer so that it scales with the card. Its
        // mask removes the part under the card, which would otherwise show
        // through the glass and darken it.
        shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.4
        shadow.shadowRadius = 30
        shadow.shadowOffset = CGSize(width: 0, height: -14)
        shadowMask.fillRule = .evenOdd
        shadow.mask = shadowMask
        root.layer?.addSublayer(shadow)

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.layer?.cornerRadius = Metrics.radius
        clip.layer?.cornerCurve = .continuous
        clip.autoresizingMask = [.width, .height]
        clip.addSubview(header)
        clip.addSubview(splits)

        glass.style = .regular
        glass.cornerRadius = Metrics.radius
        glass.contentView = clip
        root.addSubview(glass)

        header.menuProvider = { [weak self] in self?.makeMenu() }
        runtime.delegate = self
        updateTint(runtime.backgroundColor)

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncColorScheme() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    // MARK: Showing and hiding

    func toggle() {
        isShown ? hide() : show()
    }

    func show() {
        guard !isShown, let geometry = Geometry.current(preferredSize: preferredSize) else { return }
        isShown = true
        layout(geometry)

        guard let terminal = ensureTerminal(geometry) else {
            isShown = false
            NSSound.beep()
            return
        }

        apply(progress)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(terminal)
        splits.terminals.forEach { $0.setVisible(true) }
        animate(to: 1)
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        animate(to: 0) { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
            self.splits.terminals.forEach { $0.setVisible(false) }
        }
    }

    private var preferredSize: CGSize {
        let defaults = UserDefaults.standard
        let width = defaults.double(forKey: "width")
        let height = defaults.double(forKey: "height")
        return CGSize(
            width: width > 0 ? width : Metrics.defaultSize.width,
            height: height > 0 ? height : Metrics.defaultSize.height)
    }

    /// The terminal to focus when the card opens, starting a shell if none is running.
    private func ensureTerminal(_ geometry: Geometry) -> TerminalView? {
        if let existing = focused ?? splits.terminals.first { return existing }
        guard let view = TerminalView(runtime: runtime, frame: splits.soleFrame) else { return nil }
        view.setColorScheme(dark: isDark)
        splits.add(view)
        header.title = ""
        return view
    }

    private func disposeTerminals() {
        for view in splits.terminals {
            splits.remove(view)
            view.close()
        }
        focused = nil
    }

    // MARK: Layout

    /// Where everything goes for a given screen. `card` is in the panel's
    /// own coordinates.
    private struct Geometry {
        var window: NSRect
        var card: NSRect

        var headerFrame: NSRect {
            NSRect(x: 0, y: card.height - Metrics.headerHeight, width: card.width, height: Metrics.headerHeight)
        }

        var terminalFrame: NSRect {
            NSRect(x: 0, y: 0, width: card.width, height: card.height - Metrics.headerHeight)
        }

        static func current(preferredSize: CGSize) -> Geometry? {
            // Whichever screen the pointer is on.
            let pointer = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
                ?? NSScreen.main else { return nil }

            // Centred in the area below the menu bar.
            let area = screen.visibleFrame.union(
                NSRect(x: screen.frame.minX, y: screen.frame.minY, width: screen.frame.width, height: 0))
            let margin = Metrics.margin
            let size = CGSize(
                width: min(preferredSize.width, area.width - 32),
                height: min(preferredSize.height, area.height - 32))

            return Geometry(
                window: NSRect(
                    x: (area.midX - size.width / 2).rounded() - margin,
                    y: (area.midY - size.height / 2).rounded() - margin,
                    width: size.width + 2 * margin,
                    height: size.height + 2 * margin),
                card: NSRect(x: margin, y: margin, width: size.width, height: size.height))
        }
    }

    private func layout(_ geometry: Geometry) {
        self.geometry = geometry
        panel.setFrame(geometry.window, display: false)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glass.frame = geometry.card
        clip.frame = glass.bounds
        header.frame = geometry.headerFrame
        splits.frame = geometry.terminalFrame
        splits.layoutSubtreeIfNeeded()

        let bounds = CGRect(origin: .zero, size: geometry.window.size)
        let card = CGPath(
            roundedRect: geometry.card, cornerWidth: Metrics.radius, cornerHeight: Metrics.radius, transform: nil)
        shadow.frame = bounds
        shadow.shadowPath = card
        let hole = CGMutablePath()
        hole.addRect(bounds)
        hole.addPath(card)
        shadowMask.frame = bounds
        shadowMask.path = hole
        CATransaction.commit()
    }

    /// Poses the whole card for a spring position: a fade with a slight
    /// scale. Nothing is resized, so the shell never reflows mid-animation.
    private func apply(_ p: CGFloat) {
        guard let root = panel.contentView?.layer else { return }
        let unit = min(max(p, 0), 1)
        let scale = lerp(Metrics.startScale, 1, p)
        // The card is centred in the panel, and sublayerTransform works
        // around the layer's centre, so a plain scale is all it takes.
        let transform = CATransform3DMakeScale(scale, scale, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayerTransform = transform
        CATransaction.commit()

        panel.alphaValue = unit
    }

    @objc private func screensDidChange() {
        guard isShown, let geometry = Geometry.current(preferredSize: preferredSize) else { return }
        layout(geometry)
        apply(progress)
    }

    // MARK: Spring

    private func animate(to target: CGFloat, completion: (() -> Void)? = nil) {
        self.target = target
        onSettle = completion

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            progress = target
            velocity = 0
            settle()
            return
        }

        guard displayLink == nil, let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func step(_ link: CADisplayLink) {
        // Critically damped both ways: quick, with no bounce. Closing is a
        // little faster than opening.
        let opening = target > 0.5
        let stiffness: CGFloat = opening ? 1600 : 2500
        let damping: CGFloat = opening ? 80 : 100

        let frame = min(max(link.targetTimestamp - link.timestamp, 1.0 / 240), 1.0 / 30)
        let substeps = 4
        let dt = CGFloat(frame) / CGFloat(substeps)
        for _ in 0..<substeps {
            let acceleration = stiffness * (target - progress) - damping * velocity
            velocity += acceleration * dt
            progress += velocity * dt
        }
        progress = max(progress, 0)

        if abs(target - progress) < 0.01 && abs(velocity) < 0.5 {
            progress = target
            velocity = 0
            settle()
        } else {
            apply(progress)
        }
    }

    private func settle() {
        displayLink?.invalidate()
        displayLink = nil
        apply(progress)
        let completion = onSettle
        onSettle = nil
        completion?()
    }

    // MARK: Appearance

    private var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func syncColorScheme() {
        runtime.setColorScheme(dark: isDark)
        splits.terminals.forEach { $0.setColorScheme(dark: isDark) }
    }

    /// The terminal itself is transparent; tinting the glass with its
    /// background colour keeps the theme's contrast over any wallpaper.
    private func updateTint(_ background: NSColor) {
        glass.tintColor = background.withAlphaComponent(Metrics.tintAlpha)
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        runtime.setFocus(true)
        focused?.setFocused(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        runtime.setFocus(false)
        focused?.setFocused(false)
        // A sheet (the paste confirmation) takes key status without the user
        // having left the panel.
        if panel.attachedSheet == nil && ProcessInfo.processInfo.environment["QUICKTERM_TEST"] == nil { hide() }
    }

    // MARK: GhosttyRuntimeDelegate

    func runtimeBackgroundDidChange(_ color: NSColor) {
        updateTint(color)
    }

    func runtimeTitleDidChange(_ view: TerminalView) {
        guard view === focused else { return }
        header.title = view.title
    }

    func runtimeRequestsToggle() { toggle() }
    func runtimeRequestsHide() { hide() }

    func runtimeDidFocus(_ view: TerminalView) {
        focused = view
        header.title = view.title
        let dimmed = runtime.unfocusedSplitOpacity
        for terminal in splits.terminals {
            terminal.alphaValue = terminal === view ? 1 : dimmed
        }
    }

    func runtimeRequestsSplit(from view: TerminalView, direction: SplitView.Direction, workingDirectory: String?) {
        guard view.surface != nil, view.superview === splits,
              let new = TerminalView(runtime: runtime, frame: view.frame, workingDirectory: workingDirectory) else {
            NSSound.beep()
            return
        }
        new.setColorScheme(dark: isDark)
        splits.add(new, beside: view, direction: direction)
        splits.layoutSubtreeIfNeeded()
        new.setVisible(isShown)
        panel.makeFirstResponder(new)
    }

    func runtimeRequestsFocus(from view: TerminalView, direction: SplitView.Direction?, offset: Int) {
        let destination = direction.map { splits.neighbour(of: view, $0) } ?? splits.sibling(of: view, offset: offset)
        if let destination { panel.makeFirstResponder(destination) }
    }

    /// A shell exited (or its split was closed with cmd+w). Other splits take
    /// over its space; when the last one goes the card is dismissed and the
    /// next summon starts a fresh shell.
    func runtimeSurfaceDidClose(_ view: TerminalView) {
        guard view.superview === splits else { return }

        if splits.terminals.count > 1 {
            let next = splits.sibling(of: view, offset: -1)
            let hadFocus = view === focused
            splits.remove(view)
            view.close()
            splits.layoutSubtreeIfNeeded()
            if hadFocus, let next { panel.makeFirstResponder(next) }
            return
        }

        guard isShown else {
            disposeTerminals()
            return
        }
        isShown = false
        animate(to: 0) { [weak self] in
            guard let self else { return }
            self.disposeTerminals()
            if !self.isShown { self.panel.orderOut(nil) }
        }
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Ghostty Config", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Quick Term", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func reloadConfig() { runtime.reloadConfig() }
    @objc private func openConfig() { runtime.openConfig() }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("quick-term: launch at login: %@", error.localizedDescription)
            NSSound.beep()
        }
    }
}

/// The slim strip along the top of the card showing the terminal title.
/// Right-clicking it opens the app menu.
private final class HeaderView: NSView {
    var menuProvider: (() -> NSMenu?)?

    var title: String = "" {
        didSet { titleLabel.stringValue = title }
    }

    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .tertiaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingHead
        titleLabel.maximumNumberOfLines = 1
        addSubview(titleLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        let height = titleLabel.intrinsicContentSize.height
        titleLabel.frame = NSRect(
            x: 40, y: ((bounds.height - height) / 2).rounded() - 2,
            width: max(bounds.width - 80, 0), height: height)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }
}

private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}
