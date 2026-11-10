import AppKit
import GhosttyKit

protocol GhosttyRuntimeDelegate: AnyObject {
    /// The terminal background colour changed (config reload, theme switch, OSC 11).
    func runtimeBackgroundDidChange(_ color: NSColor)
    func runtimeSurfaceDidClose(_ view: TerminalView)
    func runtimeTitleDidChange(_ view: TerminalView)
    func runtimeDidFocus(_ view: TerminalView)
    func runtimeRequestsSplit(from view: TerminalView, direction: SplitView.Direction, workingDirectory: String?)
    /// Move focus to another split: a direction, or `nil` with an offset of
    /// -1/+1 for previous/next.
    func runtimeRequestsFocus(from view: TerminalView, direction: SplitView.Direction?, offset: Int)
    func runtimeRequestsToggle()
    func runtimeRequestsHide()
}

/// Owns the libghostty app and config, and routes its callbacks.
final class GhosttyRuntime {
    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    weak var delegate: GhosttyRuntimeDelegate?

    /// Per-app overrides layered on top of the user's normal Ghostty config.
    static let userOverridesURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quick-term/config")

    /// Defaults that make the terminal sit well inside the glass panel. The
    /// user's override file is loaded after these and wins.
    private static let builtinOverrides = """
    background-opacity = 0
    background-blur = false
    window-padding-x = 18
    window-padding-y = 6,14
    window-padding-balance = false
    confirm-close-surface = false
    quit-after-last-window-closed = false
    """

    init?() {
        guard let config = Self.loadConfig() else { return nil }
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in
                guard let userdata else { return }
                let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
                DispatchQueue.main.async { runtime.tick() }
            },
            action_cb: { app, target, action in
                GhosttyRuntime.handle(action: action, target: target, app: app)
            },
            read_clipboard_cb: { userdata, location, state, mimes, mimesLen, list in
                GhosttyRuntime.readClipboard(
                    userdata, location: location, state: state,
                    mimes: mimes, mimesLen: mimesLen, list: list)
            },
            confirm_read_clipboard_cb: { userdata, confirm, state, request in
                GhosttyRuntime.confirmReadClipboard(
                    userdata, confirm: confirm, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyRuntime.writeClipboard(
                    userdata, location: location, content: content, len: len, confirm: confirm)
            },
            close_surface_cb: { userdata, _ in
                guard let view = GhosttyRuntime.view(from: userdata) else { return }
                DispatchQueue.main.async {
                    view.runtime?.delegate?.runtimeSurfaceDidClose(view)
                }
            }
        )

        guard let app = ghostty_app_new(&runtime, config) else { return nil }
        self.app = app

        NotificationCenter.default.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_keyboard_changed(app)
        }
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    func setFocus(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func setColorScheme(dark: Bool) {
        guard let app else { return }
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Config

    private static func loadConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }

        // The user's normal Ghostty config: ~/.config/ghostty/config and friends.
        ghostty_config_load_default_files(cfg)

        // libghostty only loads config from files, so the built-in overrides
        // are written out to a scratch file first.
        let builtin = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-term-builtin.conf")
        if (try? builtinOverrides.write(to: builtin, atomically: true, encoding: .utf8)) != nil {
            ghostty_config_load_file(cfg, builtin.path)
        }

        if FileManager.default.fileExists(atPath: userOverridesURL.path) {
            ghostty_config_load_file(cfg, userOverridesURL.path)
        }

        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        for i in 0..<ghostty_config_diagnostics_count(cfg) {
            let message = String(cString: ghostty_config_get_diagnostic(cfg, i).message)
            NSLog("quick-term: config: %@", message)
        }
        return cfg
    }

    func reloadConfig() {
        guard let app, let new = Self.loadConfig() else { return }
        ghostty_app_update_config(app, new)
        if let old = config { ghostty_config_free(old) }
        config = new
    }

    func openConfig() {
        let path = ghostty_config_open_path()
        defer { ghostty_string_free(path) }
        guard let ptr = path.ptr, path.len > 0 else { return }
        let data = Data(bytes: ptr, count: Int(path.len))
        guard let string = String(data: data, encoding: .utf8) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: string))
    }

    /// The configured terminal background for the current colour scheme.
    var backgroundColor: NSColor {
        guard let config else { return .black }
        return Self.backgroundColor(of: config)
    }

    /// How opaque splits other than the focused one are drawn.
    var unfocusedSplitOpacity: CGFloat {
        guard let config else { return 0.7 }
        var value: Double = 0.7
        let key = "unfocused-split-opacity"
        _ = ghostty_config_get(config, &value, key, UInt(key.utf8.count))
        return CGFloat(value)
    }

    private static func backgroundColor(of config: ghostty_config_t) -> NSColor {
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return .black }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255, alpha: 1)
    }

    // MARK: Actions

    private static func view(from userdata: UnsafeMutableRawPointer?) -> TerminalView? {
        guard let userdata else { return nil }
        return Unmanaged<TerminalView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func handle(
        action: ghostty_action_s, target: ghostty_target_s, app: ghostty_app_t?
    ) -> Bool {
        guard let app, let userdata = ghostty_app_userdata(app) else { return false }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
        let view: TerminalView? = target.tag == GHOSTTY_TARGET_SURFACE
            ? target.target.surface.flatMap { Self.view(from: ghostty_surface_userdata($0)) }
            : nil

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view else { return false }
            view.title = String(cString: action.action.set_title.title)
            runtime.delegate?.runtimeTitleDidChange(view)
            return true

        case GHOSTTY_ACTION_PWD:
            guard let view else { return false }
            view.pwd = String(cString: action.action.pwd.pwd)
            runtime.delegate?.runtimeTitleDidChange(view)
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            guard let view else { return false }
            let size = action.action.cell_size
            view.cellSizeInPixels = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view?.setCursorShape(action.action.mouse_shape)
            return view != nil

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let payload = action.action.open_url
            let data = Data(bytes: payload.url, count: Int(payload.len))
            guard let string = String(data: data, encoding: .utf8) else { return false }
            // Bare paths (e.g. from cmd-clicking a file name) have no scheme.
            let url = URL(string: string).flatMap { $0.scheme == nil ? nil : $0 }
                ?? URL(fileURLWithPath: (string as NSString).expandingTildeInPath)
            NSWorkspace.shared.open(url)
            return true

        case GHOSTTY_ACTION_OPEN_CONFIG:
            runtime.openConfig()
            return true

        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // Deferred: reloading swaps the config out from under this callback.
            DispatchQueue.main.async { runtime.reloadConfig() }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            guard target.tag == GHOSTTY_TARGET_APP else { return false }
            let color = backgroundColor(of: action.action.config_change.config)
            runtime.delegate?.runtimeBackgroundDidChange(color)
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            guard change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND else { return false }
            runtime.delegate?.runtimeBackgroundDidChange(NSColor(
                srgbRed: CGFloat(change.r) / 255, green: CGFloat(change.g) / 255,
                blue: CGFloat(change.b) / 255, alpha: 1))
            return true

        case GHOSTTY_ACTION_NEW_SPLIT:
            guard let view else { return false }
            let direction: SplitView.Direction
            switch action.action.new_split {
            case GHOSTTY_SPLIT_DIRECTION_LEFT: direction = .left
            case GHOSTTY_SPLIT_DIRECTION_UP: direction = .up
            case GHOSTTY_SPLIT_DIRECTION_DOWN: direction = .down
            default: direction = .right
            }
            // Read now, while the source surface is certainly alive; the new
            // surface is created after this callback returns.
            let directory = view.inheritedWorkingDirectory ?? view.pwd
            DispatchQueue.main.async {
                runtime.delegate?.runtimeRequestsSplit(from: view, direction: direction, workingDirectory: directory)
            }
            return true

        case GHOSTTY_ACTION_GOTO_SPLIT:
            guard let view else { return false }
            let direction: SplitView.Direction?
            var offset = 0
            switch action.action.goto_split {
            case GHOSTTY_GOTO_SPLIT_LEFT: direction = .left
            case GHOSTTY_GOTO_SPLIT_RIGHT: direction = .right
            case GHOSTTY_GOTO_SPLIT_UP: direction = .up
            case GHOSTTY_GOTO_SPLIT_DOWN: direction = .down
            case GHOSTTY_GOTO_SPLIT_PREVIOUS: (direction, offset) = (nil, -1)
            default: (direction, offset) = (nil, 1)
            }
            DispatchQueue.main.async {
                runtime.delegate?.runtimeRequestsFocus(from: view, direction: direction, offset: offset)
            }
            return true

        case GHOSTTY_ACTION_TOGGLE_QUICK_TERMINAL, GHOSTTY_ACTION_TOGGLE_VISIBILITY:
            DispatchQueue.main.async { runtime.delegate?.runtimeRequestsToggle() }
            return true

        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_ALL_WINDOWS:
            DispatchQueue.main.async { runtime.delegate?.runtimeRequestsHide() }
            return true

        case GHOSTTY_ACTION_QUIT:
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        default:
            return false
        }
    }

    // MARK: Clipboard

    private static let selectionPasteboard = NSPasteboard(name: .init("local.quick-term.selection"))

    private static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return selectionPasteboard
        default: return nil
        }
    }

    private typealias ClipboardEntry = (mime: String, data: Data)

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        guard let view = view(from: userdata), let surface = view.surface, let state,
              let pasteboard = pasteboard(for: location) else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        var contents: [ClipboardEntry] = []
        if let mimes {
            for i in 0..<mimesLen where String(cString: mimes[i]) == "text/plain" {
                if let string = pasteboard.terminalString, contents.isEmpty {
                    contents.append((mime: "text/plain", data: Data(string.utf8)))
                }
            }
        }
        let available = list && pasteboard.terminalString != nil ? ["text/plain"] : []

        if contents.isEmpty && !list { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        complete(surface, contents: contents, available: available, state: state, confirmed: false)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// libghostty asks before letting a program read the clipboard, and before
    /// pasting text that could run commands on its own (e.g. contains newlines
    /// while the shell isn't in bracketed-paste mode).
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = view(from: userdata), let surface = view.surface, let state else { return }

        // The confirmation is asynchronous, so the borrowed C data is copied.
        let c = confirm.pointee
        var contents: [ClipboardEntry] = []
        if let items = c.contents {
            for i in 0..<c.contents_len {
                let item = items[i]
                contents.append((mime: String(cString: item.mime), data: Data(bytes: item.data, count: item.len)))
            }
        }
        var available: [String] = []
        if let names = c.available {
            for i in 0..<c.available_len { available.append(String(cString: names[i])) }
        }

        guard let window = view.window else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_PASTE:
            alert.messageText = "Paste this text?"
            alert.informativeText = "It may run commands as soon as it is pasted."
            alert.addButton(withTitle: "Paste")
        default:
            alert.messageText = "Allow clipboard access?"
            alert.informativeText = "A program in the terminal wants to use the clipboard."
            alert.addButton(withTitle: "Allow")
        }
        alert.addButton(withTitle: "Cancel")
        if let text = contents.first(where: { $0.mime == "text/plain" }),
           let string = String(data: text.data, encoding: .utf8) {
            let preview = NSTextField(wrappingLabelWithString: String(string.prefix(600)))
            preview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            preview.frame = NSRect(x: 0, y: 0, width: 320, height: 90)
            alert.accessoryView = preview
        }

        alert.beginSheetModal(for: window) { [weak view] response in
            // The surface may have been closed while the sheet was up.
            guard let view, view.surface == surface else { return }
            if response == .alertFirstButtonReturn {
                complete(surface, contents: contents, available: available, state: state, confirmed: true)
            } else {
                ghostty_surface_deny_clipboard_request(surface, state)
            }
            view.window?.makeFirstResponder(view)
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>,
        len: Int,
        confirm: Bool
    ) {
        // `confirm` is set for writes requested by terminal programs (OSC 52)
        // when the config asks for confirmation; those are dropped.
        guard !confirm, len > 0, let pasteboard = pasteboard(for: location) else { return }
        for i in 0..<len {
            let item = content[i]
            guard String(cString: item.mime) == "text/plain" else { continue }
            let string = String(decoding: Data(bytes: item.data, count: item.len), as: UTF8.self)
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
            return
        }
    }

    private static func complete(
        _ surface: ghostty_surface_t,
        contents: [ClipboardEntry],
        available: [String],
        state: UnsafeMutableRawPointer,
        confirmed: Bool
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        var cDatas: [UnsafeMutableRawPointer] = []
        defer {
            cStrings.forEach { free($0) }
            cDatas.forEach { $0.deallocate() }
        }

        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime) else { continue }
            cStrings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(entry.data.count, 1), alignment: 1)
            cDatas.append(buffer)
            entry.data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: entry.data.count)
            cContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: buffer.assumingMemoryBound(to: CChar.self),
                len: entry.data.count))
        }

        var cAvailable: [UnsafePointer<CChar>] = []
        for mime in available {
            guard let string = strdup(mime) else { continue }
            cStrings.append(string)
            cAvailable.append(UnsafePointer(string))
        }

        cContents.withUnsafeBufferPointer { contentsBuffer in
            cAvailable.withUnsafeBufferPointer { availableBuffer in
                var payload = ghostty_clipboard_complete_s(
                    contents: contentsBuffer.baseAddress,
                    contents_len: contentsBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &payload, state)
            }
        }
    }
}

extension NSPasteboard {
    /// What pasting into the terminal should produce: copied files become
    /// shell-escaped paths, anything else is its plain string.
    var terminalString: String? {
        let parts: [String] = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               url.isFileURL {
                return url.path.shellEscaped
            }
            return item.string(forType: .string)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

extension String {
    var shellEscaped: String {
        var result = ""
        for character in self {
            if "\\ ()[]{}<>\"'`!#$&;|*?\t".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
