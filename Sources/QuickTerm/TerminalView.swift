import AppKit
import Carbon.HIToolbox
import GhosttyKit

/// An NSView hosting one libghostty surface (a terminal and its shell).
///
/// The keyboard handling follows Ghostty's own macOS app closely: getting
/// dead keys, IME composition and option-as-alt right depends on the exact
/// order of these AppKit calls.
final class TerminalView: NSView, NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    private(set) weak var runtime: GhosttyRuntime?

    var title = ""
    var pwd: String?
    var cellSizeInPixels: CGSize = .zero

    private var focused = false
    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    private var cursor: NSCursor = .iBeam

    init?(runtime: GhosttyRuntime, frame: NSRect, workingDirectory: String? = nil) {
        guard let app = runtime.app else { return nil }
        self.runtime = runtime
        super.init(frame: frame)

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let directory = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path
        surface = directory.withCString { cwd in
            config.working_directory = cwd
            return ghostty_surface_new(app, &config)
        }
        guard surface != nil else { return nil }

        updateTrackingAreas()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { close() }

    /// Ends the shell and frees the surface. Safe to call more than once.
    func close() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    // MARK: Geometry

    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncSize()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let window else { return }

        // The surface renders at native resolution itself, so Core Animation
        // must not rescale the layer when the display's scale changes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()

        guard let surface else { return }
        let scale = Double(window.backingScaleFactor)
        ghostty_surface_set_content_scale(surface, scale, scale)
        if let id = window.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, id)
        }
        syncSize()
    }

    private func syncSize() {
        guard let surface else { return }
        let pixels = convertToBacking(bounds.size)
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
    }

    /// The directory a split made from this terminal should start in.
    var inheritedWorkingDirectory: String? {
        guard let surface else { return nil }
        let inherited = ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        return inherited.working_directory.map { String(cString: $0) }
    }

    func setVisible(_ visible: Bool) {
        guard let surface else { return }
        ghostty_surface_set_occlusion(surface, visible)
    }

    func setColorScheme(dark: Bool) {
        guard let surface else { return }
        ghostty_surface_set_color_scheme(
            surface, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            setFocused(window?.isKeyWindow ?? false)
            runtime?.delegate?.runtimeDidFocus(self)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    func setFocused(_ focused: Bool) {
        guard let surface, self.focused != focused else { return }
        self.focused = focused
        ghostty_surface_set_focus(surface, focused)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let new: NSCursor
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: new = .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER: new = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: new = .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: new = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: new = .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: new = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: new = .contextualMenu
        default: new = .iBeam
        }
        guard new != cursor else { return }
        cursor = new
        window?.invalidateCursorRects(for: self)
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        Self.ghosttyMods(event.modifierFlags)
    }

    private func sendMouseButton(
        _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent
    ) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, state, button, mods(event))
    }

    private func otherButton(_ event: NSEvent) -> ghostty_input_mouse_button_e {
        switch event.buttonNumber {
        case 2: return GHOSTTY_MOUSE_MIDDLE
        case 3: return GHOSTTY_MOUSE_FOUR
        case 4: return GHOSTTY_MOUSE_FIVE
        default: return GHOSTTY_MOUSE_UNKNOWN
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking a split focuses it.
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }
    override func mouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event) }
    override func rightMouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) }
    override func rightMouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) }
    override func otherMouseDown(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_PRESS, otherButton(event), event) }
    override func otherMouseUp(with event: NSEvent) { sendMouseButton(GHOSTTY_MOUSE_RELEASE, otherButton(event), event) }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let position = convert(event.locationInWindow, from: nil)
        // libghostty's origin is the top-left corner.
        ghostty_surface_mouse_pos(surface, position.x, bounds.height - position.y, mods(event))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        // A position outside the viewport tells libghostty the pointer left.
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            x *= 2
            y *= 2
        }

        // Packed as libghostty's ScrollMods: bit 0 is precision, bits 1-3 the
        // momentum phase.
        let momentum: Int32
        switch event.momentumPhase {
        case .began: momentum = 1
        case .stationary: momentum = 2
        case .changed: momentum = 3
        case .ended: momentum = 4
        case .cancelled: momentum = 5
        case .mayBegin: momentum = 6
        default: momentum = 0
        }
        ghostty_surface_mouse_scroll(surface, x, y, (precise ? 1 : 0) | (momentum << 1))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            interpretKeyEvents([event])
            return
        }

        // Settings such as macos-option-as-alt change which modifiers take
        // part in producing text.
        let translationModsGhostty = Self.modifierFlags(
            ghostty_surface_key_translation_mods(surface, Self.ghosttyMods(event.modifierFlags)))

        // The event carries hidden bits that matter for some dead keys, so
        // only the four known flags are replaced.
        var translationMods = event.modifierFlags
        for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            if translationModsGhostty.contains(flag) {
                translationMods.insert(flag)
            } else {
                translationMods.remove(flag)
            }
        }

        // The original event must be reused when nothing changed: AppKit
        // relies on its identity for input methods such as Korean.
        let translationEvent: NSEvent
        if translationMods == event.modifierFlags {
            translationEvent = event
        } else {
            translationEvent = NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: translationMods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        // Non-nil marks that a keyDown is in progress; insertText collects
        // into it instead of sending text straight away.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        let markedTextBefore = markedText.length > 0
        let keyboardBefore: String? = markedTextBefore ? nil : Self.keyboardLayoutID

        lastPerformKeyEvent = nil
        interpretKeyEvents([translationEvent])

        // If the key switched the keyboard layout, an input method took it.
        if !markedTextBefore && keyboardBefore != Self.keyboardLayoutID { return }

        syncPreedit(clearIfNeeded: markedTextBefore)

        // Still composing if preedit text exists, or if this key just ended
        // it (e.g. backspace cancelling a composition must not also delete).
        let composing = markedText.length > 0 || markedTextBefore

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts where !Self.isComposingControlInput(text, composing: composing) {
                if markedTextBefore {
                    _ = sendCommittedText(text)
                } else {
                    _ = sendKey(action, event: event, translationEvent: translationEvent, text: text)
                }
            }
        } else {
            if Self.isComposingControlInput(event.characters, composing: composing) { return }
            _ = sendKey(
                action, event: event, translationEvent: translationEvent,
                text: Self.text(for: translationEvent), composing: composing)
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = sendKey(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused, let surface else { return false }

        // Anything bound in the Ghostty config goes straight to the terminal.
        var keyEvent = Self.keyEvent(event, action: GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { text in
            keyEvent.text = text
            return ghostty_surface_key_is_binding(surface, keyEvent, nil)
        }
        if isBinding {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Pass ctrl+return through instead of opening a context menu.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"

        case "/":
            // ctrl+/ beeps in AppKit; terminals expect it as ctrl+_.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"

        default:
            // AppKit synthesises events with a zero timestamp (e.g. cmd+. as
            // escape); those are never ours.
            if event.timestamp == 0 { return false }

            guard event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) else {
                lastPerformKeyEvent = nil
                return false
            }

            // Let AppKit try the key first. If nothing claims it, doCommand
            // re-sends the same event and it is encoded for the terminal here.
            if let last = lastPerformKeyEvent {
                lastPerformKeyEvent = nil
                if last == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            lastPerformKeyEvent = event.timestamp
            return false
        }

        guard let final = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }
        keyDown(with: final)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        let mod: UInt32
        switch Int(event.keyCode) {
        case kVK_CapsLock: mod = GHOSTTY_MODS_CAPS.rawValue
        case kVK_Shift, kVK_RightShift: mod = GHOSTTY_MODS_SHIFT.rawValue
        case kVK_Control, kVK_RightControl: mod = GHOSTTY_MODS_CTRL.rawValue
        case kVK_Option, kVK_RightOption: mod = GHOSTTY_MODS_ALT.rawValue
        case kVK_Command, kVK_RightCommand: mod = GHOSTTY_MODS_SUPER.rawValue
        default: return
        }
        if hasMarkedText() { return }

        // A modifier event is a press only if that side's key is now down;
        // otherwise it is the release of one side while the other is held.
        var action = GHOSTTY_ACTION_RELEASE
        if Self.ghosttyMods(event.modifierFlags).rawValue & mod != 0 {
            let raw = event.modifierFlags.rawValue
            let sidePressed: Bool
            switch Int(event.keyCode) {
            case kVK_RightShift: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
            case kVK_RightControl: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
            case kVK_RightOption: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
            case kVK_RightCommand: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
            default: sidePressed = true
            }
            if sidePressed { action = GHOSTTY_ACTION_PRESS }
        }
        _ = sendKey(action, event: event)
    }

    private func sendKey(
        _ action: ghostty_input_action_e,
        event: NSEvent,
        translationEvent: NSEvent? = nil,
        text: String? = nil,
        composing: Bool = false
    ) -> Bool {
        guard let surface else { return false }
        var keyEvent = Self.keyEvent(event, action: action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing

        // Control characters are encoded by libghostty from the key itself.
        if let text, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F {
            return text.withCString { pointer in
                keyEvent.text = pointer
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    /// Text committed by an input method, sent as typed input with no key.
    private func sendCommittedText(_ text: String) -> Bool {
        guard let surface else { return false }
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        return text.withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    // MARK: Editing commands

    private func perform(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    @IBAction func copy(_ sender: Any?) { perform("copy_to_clipboard") }
    @IBAction func paste(_ sender: Any?) { perform("paste_from_clipboard") }
    @IBAction override func selectAll(_ sender: Any?) { perform("select_all") }

    // MARK: NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        // Outside a keyDown (e.g. switching layouts mid-composition) nothing
        // else will push the preedit text to the terminal.
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)

        let scale = window?.backingScaleFactor ?? 2
        let cellHeight = cellSizeInPixels.height / scale
        // libghostty's origin is top-left; AppKit's is bottom-left.
        let rect = NSRect(x: x, y: bounds.height - y, width: range.length == 0 ? 0 : width, height: max(height, cellHeight))
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let characters: String
        switch string {
        case let value as NSAttributedString: characters = value.string
        case let value as String: characters = value
        default: return
        }

        // Inserting text always ends a composition.
        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(characters)
            return
        }
        if !characters.isEmpty { _ = sendCommittedText(characters) }
    }

    /// Stops AppKit beeping for unhandled commands, and re-sends cmd/ctrl keys
    /// that nothing in AppKit claimed so they reach the terminal.
    override func doCommand(by selector: Selector) {
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let string = markedText.string
            string.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(string.utf8.count))
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: Conversions

    private static var keyboardLayoutID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// A lone control character arriving mid-composition belongs to the input
    /// method, not the terminal.
    private static func isComposingControlInput(_ text: String?, composing: Bool) -> Bool {
        guard composing, let text, text.unicodeScalars.count == 1,
              let scalar = text.unicodeScalars.first else { return false }
        return scalar.value < 0x20
    }

    /// The text a key event should carry for libghostty.
    private static func text(for event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.unicodeScalars.count == 1, let scalar = characters.unicodeScalars.first {
            // libghostty encodes control characters itself, so it gets the
            // character without control applied.
            if scalar.value < 0x20 {
                return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
            }
            // Function keys live in the private use area; they carry no text.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
        }
        return characters
    }

    private static func keyEvent(
        _ event: NSEvent,
        action: ghostty_input_action_e,
        translationMods: NSEvent.ModifierFlags? = nil
    ) -> ghostty_input_key_s {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = action
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.text = nil
        keyEvent.composing = false
        keyEvent.mods = ghosttyMods(event.modifierFlags)
        // Control and command never contribute to the text a key produces;
        // every other modifier is assumed to have.
        keyEvent.consumed_mods = ghosttyMods(
            (translationMods ?? event.modifierFlags).subtracting([.control, .command]))
        keyEvent.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
            keyEvent.unshifted_codepoint = scalar.value
        }
        return keyEvent
    }

    static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }

        let raw = flags.rawValue
        if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(mods)
    }

    private static func modifierFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
        var flags = NSEvent.ModifierFlags()
        if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
        if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
        if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
        if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
        return flags
    }
}
