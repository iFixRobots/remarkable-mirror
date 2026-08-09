import AppKit
import SwiftUI

/// The two user-facing input modes supported by the mirrored tablet surface.
enum TabletInputMode: Equatable, Sendable {
    case touchAndType
    case pen
}

/// The visible framebuffer geometry. Input is normalized against this viewport,
/// never against backing pixels, so Retina scale does not affect coordinates.
enum TabletVisibleViewport {
    static let width = 954.0
    static let height = 1_696.0
}

struct TabletViewportCoordinate: Equatable, Sendable {
    let normalizedX: Double
    let normalizedY: Double

    var viewportX: Double { normalizedX * TabletVisibleViewport.width }
    var viewportY: Double { normalizedY * TabletVisibleViewport.height }
}

enum TabletCoordinateNormalizer {
    /// Converts a local AppKit point into the protocol's inclusive `0...1`
    /// coordinate space. `bounds` is measured in logical points; using no
    /// backing-scale APIs is what makes the result independent of Retina.
    static func normalize(
        _ location: CGPoint,
        in bounds: CGRect
    ) -> TabletViewportCoordinate? {
        guard
            bounds.width.isFinite,
            bounds.height.isFinite,
            bounds.width > 0,
            bounds.height > 0,
            location.x.isFinite,
            location.y.isFinite
        else {
            return nil
        }

        let x = ((location.x - bounds.minX) / bounds.width).clamped(to: 0...1)
        let y = ((location.y - bounds.minY) / bounds.height).clamped(to: 0...1)
        return TabletViewportCoordinate(
            normalizedX: x,
            normalizedY: y
        )
    }
}

enum TabletPointerKind: Equatable, Sendable {
    case touch
    case pen
    case eraser
}

enum TabletPointerPhase: Equatable, Sendable {
    case down
    case move
    case up
}

enum TabletPointerButton: Equatable, Sendable {
    case primary
    case secondary
}

struct TabletPointerEvent: Equatable, Sendable {
    let kind: TabletPointerKind
    let phase: TabletPointerPhase
    let coordinate: TabletViewportCoordinate?
}

struct TabletHardwareModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt

    static let capsLock = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)
    static let control = Self(rawValue: 1 << 2)
    static let option = Self(rawValue: 1 << 3)
    static let command = Self(rawValue: 1 << 4)
    static let numericPad = Self(rawValue: 1 << 5)
    static let function = Self(rawValue: 1 << 6)

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    init(_ flags: NSEvent.ModifierFlags) {
        var result: Self = []
        if flags.contains(.capsLock) { result.insert(.capsLock) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.numericPad) { result.insert(.numericPad) }
        if flags.contains(.function) { result.insert(.function) }
        self = result
    }
}

enum TabletHardwareKeyLocation: Equatable, Sendable {
    case standard
    case numericPad
    case left
    case right
}

struct TabletHardwareKey: Equatable, Sendable {
    let macKeyCode: UInt16
    let charactersIgnoringModifiers: String?
    let modifiers: TabletHardwareModifiers
    let location: TabletHardwareKeyLocation

    init(
        macKeyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: TabletHardwareModifiers,
        location: TabletHardwareKeyLocation? = nil
    ) {
        self.macKeyCode = macKeyCode
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
        self.modifiers = modifiers
        self.location = location ?? Self.location(
            for: macKeyCode,
            modifiers: modifiers
        )
    }

    init(event: NSEvent) {
        let modifiers = TabletHardwareModifiers(event.modifierFlags)
        let charactersIgnoringModifiers: String?
        switch event.type {
        case .keyDown, .keyUp:
            charactersIgnoringModifiers = event.charactersIgnoringModifiers
        default:
            // AppKit exposes character data only for key-down and key-up.
            charactersIgnoringModifiers = nil
        }
        self.init(
            macKeyCode: event.keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        )
    }

    var isCommandKey: Bool {
        Self.commandKeyCodes.contains(macKeyCode)
    }

    var isModifierKey: Bool {
        Self.modifierKeyCodes.contains(macKeyCode)
    }

    private static let commandKeyCodes: Set<UInt16> = [54, 55]
    private static let leftModifierKeyCodes: Set<UInt16> = [55, 56, 57, 58, 59]
    private static let rightModifierKeyCodes: Set<UInt16> = [54, 60, 61, 62]
    private static let modifierKeyCodes = leftModifierKeyCodes
        .union(rightModifierKeyCodes)
        .union([63])
    private static let numericPadKeyCodes: Set<UInt16> = [
        65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87,
        88, 89, 91, 92
    ]

    private static func location(
        for keyCode: UInt16,
        modifiers: TabletHardwareModifiers
    ) -> TabletHardwareKeyLocation {
        if numericPadKeyCodes.contains(keyCode) || modifiers.contains(.numericPad) {
            return .numericPad
        }
        if leftModifierKeyCodes.contains(keyCode) {
            return .left
        }
        if rightModifierKeyCodes.contains(keyCode) {
            return .right
        }
        return .standard
    }
}

enum TabletHardwareKeyPhase: Equatable, Sendable {
    case down
    case up
}

struct TabletHardwareKeyEvent: Equatable, Sendable {
    let phase: TabletHardwareKeyPhase
    let key: TabletHardwareKey
    let isRepeat: Bool
}

/// A committed host text insertion. The AppKit boundary keeps the complete
/// Unicode value so an IME commit is never split or reordered.
struct TabletTextCommit: Equatable, Sendable {
    static let currentProtocolMaximumUTF8Bytes = TabletInputWireCodec.maximumTextBytes

    let text: String

    /// The current tablet helper accepts only printable US ASCII plus tab,
    /// backspace, CR, and LF. Unicode and IME commits are represented here but
    /// must be rejected or handled by a future transport capability.
    var isCurrentProtocolCompatible: Bool {
        let bytes = text.utf8
        guard
            !bytes.isEmpty,
            bytes.count <= Self.currentProtocolMaximumUTF8Bytes
        else {
            return false
        }

        return bytes.allSatisfy { byte in
            (0x20...0x7E).contains(byte)
                || byte == 0x08
                || byte == 0x09
                || byte == 0x0A
                || byte == 0x0D
        }
    }
}

enum TabletHardwareTextPolicy {
    /// Ordinary printable key events already travel as ordered hardware edges.
    /// AppKit echoes those same keys through `insertText`; suppressing that echo
    /// prevents duplicate remote characters. Composition and Unicode commits
    /// remain explicit host events for a future capable transport.
    static func shouldEmitCommit(
        _ text: String,
        directHardwareCharacters: String?,
        beganWithMarkedText: Bool,
        wasMarkedText: Bool
    ) -> Bool {
        if beganWithMarkedText || wasMarkedText {
            return true
        }
        let commit = TabletTextCommit(text: text)
        if !commit.isCurrentProtocolCompatible {
            return true
        }
        return directHardwareCharacters != text
    }
}

enum TabletInputResetReason: Equatable, Sendable {
    case focusLost
    case windowLost
    case pointerCancelled
    case modeChanged
    case disabled
    case viewRemoved
}

enum TabletHostInputPayload: Equatable, Sendable {
    case pointer(TabletPointerEvent)
    case key(TabletHardwareKeyEvent)
    case text(TabletTextCommit)
    case reset(reason: TabletInputResetReason)
}

struct TabletHostInputEvent: Equatable, Sendable {
    let sequence: UInt64
    let payload: TabletHostInputPayload
}

typealias TabletInputEventHandler = @MainActor (TabletHostInputEvent) -> Void

enum TabletHostInputTranslationError: Error, Equatable, Sendable {
    case missingPointerCoordinate
    case unsupportedMacKeyCode(UInt16)
    case unsupportedText
}

/// Pure adapter from AppKit-facing host events to the existing typed input
/// protocol. The coordinator can translate synchronously and enqueue only a
/// `TabletInputEvent`; AppKit objects never cross that boundary.
enum TabletHostInputTranslator {
    static func translate(
        _ hostEvent: TabletHostInputEvent
    ) throws -> TabletInputEvent {
        switch hostEvent.payload {
        case let .pointer(pointer):
            return try translate(pointer)
        case let .key(key):
            guard let keyName = macKeyNames[key.key.macKeyCode] else {
                throw TabletHostInputTranslationError.unsupportedMacKeyCode(
                    key.key.macKeyCode
                )
            }
            guard let tabletKey = try? TabletInputKey(validating: keyName) else {
                throw TabletHostInputTranslationError.unsupportedMacKeyCode(
                    key.key.macKeyCode
                )
            }
            return .key(
                action: key.phase == .down ? .down : .up,
                key: tabletKey
            )
        case let .text(commit):
            guard commit.isCurrentProtocolCompatible else {
                throw TabletHostInputTranslationError.unsupportedText
            }
            return .text(commit.text)
        case .reset:
            return .reset
        }
    }

    private static func translate(
        _ pointer: TabletPointerEvent
    ) throws -> TabletInputEvent {
        switch pointer.kind {
        case .touch:
            switch pointer.phase {
            case .down:
                let coordinate = try requiredCoordinate(pointer.coordinate)
                return .touch(
                    .down(
                        x: coordinate.normalizedX,
                        y: coordinate.normalizedY
                    )
                )
            case .move:
                let coordinate = try requiredCoordinate(pointer.coordinate)
                return .touch(
                    .move(
                        x: coordinate.normalizedX,
                        y: coordinate.normalizedY
                    )
                )
            case .up:
                return .touch(.up)
            }
        case .pen, .eraser:
            switch pointer.phase {
            case .down:
                let coordinate = try requiredCoordinate(pointer.coordinate)
                return .pen(
                    .down(
                        x: coordinate.normalizedX,
                        y: coordinate.normalizedY,
                        tool: pointer.kind == .eraser ? .eraser : .pen
                    )
                )
            case .move:
                let coordinate = try requiredCoordinate(pointer.coordinate)
                return .pen(
                    .move(
                        x: coordinate.normalizedX,
                        y: coordinate.normalizedY
                    )
                )
            case .up:
                return .pen(.up)
            }
        }
    }

    private static func requiredCoordinate(
        _ coordinate: TabletViewportCoordinate?
    ) throws -> TabletViewportCoordinate {
        guard let coordinate else {
            throw TabletHostInputTranslationError.missingPointerCoordinate
        }
        return coordinate
    }

    /// US physical key positions supported by the current helper. Number-row
    /// and numeric-keypad digits have distinct host identities but intentionally
    /// converge on the helper's only digit key names.
    private static let macKeyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z",
        7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
        15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
        21: "4", 22: "6", 23: "5", 24: "EQUAL", 25: "9", 26: "7",
        27: "MINUS", 28: "8", 29: "0", 30: "RIGHTBRACE", 31: "O",
        32: "U", 33: "LEFTBRACE", 34: "I", 35: "P", 36: "ENTER",
        37: "L", 38: "J", 39: "APOSTROPHE", 40: "K", 41: "SEMICOLON",
        42: "BACKSLASH", 43: "COMMA", 44: "SLASH", 45: "N", 46: "M",
        47: "DOT", 48: "TAB", 49: "SPACE", 50: "GRAVE", 51: "BACKSPACE",
        53: "ESC", 56: "LEFTSHIFT", 57: "CAPSLOCK", 58: "LEFTALT",
        59: "LEFTCTRL", 60: "RIGHTSHIFT", 61: "RIGHTALT", 62: "RIGHTCTRL",

        // Numeric keypad. The helper exposes ordinary digit/operator keys, not
        // Linux KEY_KP* names, so supported positions converge intentionally.
        65: "DOT", 75: "SLASH", 76: "ENTER", 78: "MINUS", 81: "EQUAL",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5",
        88: "6", 89: "7", 91: "8", 92: "9",

        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 103: "F11", 109: "F10", 111: "F12", 114: "INSERT",
        115: "HOME", 116: "PAGEUP", 117: "DELETE", 118: "F4", 119: "END",
        120: "F2", 121: "PAGEDOWN", 122: "F1", 123: "LEFT", 124: "RIGHT",
        125: "DOWN", 126: "UP"
    ]
}

/// Pure, synchronously sequenced input state. Transport code can consume the
/// resulting Sendable values later without giving AppKit state to another
/// actor.
struct TabletInputReducer: Sendable {
    private struct ActivePointer: Equatable, Sendable {
        let kind: TabletPointerKind
        let button: TabletPointerButton
    }

    private(set) var mode: TabletInputMode
    private(set) var nextSequence: UInt64
    private var activePointer: ActivePointer?
    private var heldKeys: [UInt16: TabletHardwareKey] = [:]
    private var resetIsArmed = false

    init(
        mode: TabletInputMode,
        startingSequence: UInt64 = 1
    ) {
        precondition(startingSequence > 0, "Input sequences must be non-zero")
        self.mode = mode
        nextSequence = startingSequence
    }

    var hasActivePointer: Bool { activePointer != nil }
    var hasHeldInput: Bool { activePointer != nil || !heldKeys.isEmpty }

    func hasHeldKey(macKeyCode: UInt16) -> Bool {
        heldKeys[macKeyCode] != nil
    }

    mutating func focusGained() {
        resetIsArmed = true
    }

    mutating func setMode(_ newMode: TabletInputMode) -> TabletHostInputEvent? {
        guard mode != newMode else { return nil }
        let reset = hasHeldInput ? requestReset(reason: .modeChanged) : nil
        mode = newMode
        return reset
    }

    mutating func pointerDown(
        button: TabletPointerButton,
        at coordinate: TabletViewportCoordinate
    ) -> [TabletHostInputEvent] {
        guard let kind = pointerKind(for: button) else { return [] }

        var events: [TabletHostInputEvent] = []
        if activePointer != nil,
           let reset = requestReset(reason: .pointerCancelled) {
            events.append(reset)
        }

        activePointer = ActivePointer(
            kind: kind,
            button: button
        )
        events.append(
            makeEvent(
                .pointer(
                    TabletPointerEvent(
                        kind: kind,
                        phase: .down,
                        coordinate: coordinate
                    )
                )
            )
        )
        return events
    }

    mutating func pointerMoved(
        button: TabletPointerButton,
        to coordinate: TabletViewportCoordinate
    ) -> TabletHostInputEvent? {
        guard let activePointer, activePointer.button == button else {
            return nil
        }

        return makeEvent(
            .pointer(
                TabletPointerEvent(
                    kind: activePointer.kind,
                    phase: .move,
                    coordinate: coordinate
                )
            )
        )
    }

    mutating func pointerUp(
        button: TabletPointerButton,
        at coordinate: TabletViewportCoordinate?
    ) -> [TabletHostInputEvent] {
        guard let activePointer, activePointer.button == button else {
            return []
        }
        self.activePointer = nil

        var events: [TabletHostInputEvent] = []
        if let coordinate {
            events.append(
                makeEvent(
                    .pointer(
                        TabletPointerEvent(
                            kind: activePointer.kind,
                            phase: .move,
                            coordinate: coordinate
                        )
                    )
                )
            )
        }
        events.append(
            makeEvent(
                .pointer(
                    TabletPointerEvent(
                        kind: activePointer.kind,
                        phase: .up,
                        coordinate: nil
                    )
                )
            )
        )
        return events
    }

    mutating func keyDown(
        _ key: TabletHardwareKey,
        isRepeat: Bool
    ) -> TabletHostInputEvent? {
        guard !key.isCommandKey else { return nil }
        let routedKey = heldKeys[key.macKeyCode] ?? key
        heldKeys[key.macKeyCode] = routedKey
        return makeEvent(
            .key(
                TabletHardwareKeyEvent(
                    phase: .down,
                    key: routedKey,
                    isRepeat: isRepeat
                )
            )
        )
    }

    mutating func keyUp(
        _ key: TabletHardwareKey
    ) -> TabletHostInputEvent? {
        guard
            !key.isCommandKey,
            let routedKey = heldKeys.removeValue(forKey: key.macKeyCode)
        else {
            return nil
        }

        return makeEvent(
            .key(
                TabletHardwareKeyEvent(
                    phase: .up,
                    key: routedKey,
                    isRepeat: false
                )
            )
        )
    }

    /// `flagsChanged` supplies aggregate flags, so the held-key table is the
    /// reliable way to distinguish left/right modifier down and up edges.
    mutating func modifierFlagsChanged(
        _ key: TabletHardwareKey
    ) -> TabletHostInputEvent? {
        guard key.isModifierKey, !key.isCommandKey else { return nil }
        if heldKeys[key.macKeyCode] != nil {
            return keyUp(key)
        }
        return keyDown(key, isRepeat: false)
    }

    mutating func commitText(_ text: String) -> TabletHostInputEvent? {
        guard !text.isEmpty else { return nil }
        return makeEvent(.text(TabletTextCommit(text: text)))
    }

    mutating func requestReset(
        reason: TabletInputResetReason
    ) -> TabletHostInputEvent? {
        guard resetIsArmed else { return nil }
        activePointer = nil
        heldKeys.removeAll(keepingCapacity: true)
        resetIsArmed = false
        return sequence(.reset(reason: reason))
    }

    private func pointerKind(
        for button: TabletPointerButton
    ) -> TabletPointerKind? {
        switch (mode, button) {
        case (.touchAndType, .primary):
            return .touch
        case (.touchAndType, .secondary):
            return nil
        case (.pen, .primary):
            return .pen
        case (.pen, .secondary):
            return .eraser
        }
    }

    private mutating func makeEvent(
        _ payload: TabletHostInputPayload
    ) -> TabletHostInputEvent {
        resetIsArmed = true
        return sequence(payload)
    }

    private mutating func sequence(
        _ payload: TabletHostInputPayload
    ) -> TabletHostInputEvent {
        precondition(nextSequence < UInt64.max, "Input sequence exhausted")
        let event = TabletHostInputEvent(
            sequence: nextSequence,
            payload: payload
        )
        nextSequence += 1
        return event
    }
}

/// Transparent AppKit input layer placed over the visible mirrored framebuffer.
/// It is the only first responder in the product that forwards tablet input;
/// titlebar, toolbar, and Files controls remain ordinary local controls.
@MainActor
final class TabletInputSurfaceView: NSView, @MainActor NSTextInputClient {
    private struct HardwareTextInterpretation {
        let directCharacters: String?
        let beganWithMarkedText: Bool
    }

    private var reducer: TabletInputReducer
    private var eventHandler: TabletInputEventHandler
    private var markedText = NSAttributedString()
    private var markedSelection = NSRange(location: NSNotFound, length: 0)
    private var hardwareTextInterpretation: HardwareTextInterpretation?
    private var isPassingThroughLocalCommandShortcut = false
    private weak var observedWindow: NSWindow?
    private(set) var isInputEnabled: Bool

    init(
        mode: TabletInputMode,
        isEnabled: Bool = true,
        onEvent: @escaping TabletInputEventHandler
    ) {
        reducer = TabletInputReducer(mode: mode)
        isInputEnabled = isEnabled
        eventHandler = onEvent
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { isInputEnabled }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        isInputEnabled
    }

    func update(
        mode: TabletInputMode,
        isEnabled: Bool,
        onEvent: @escaping TabletInputEventHandler
    ) {
        eventHandler = onEvent

        if let reset = reducer.setMode(mode) {
            emit(reset)
            clearMarkedText()
        }

        guard isInputEnabled != isEnabled else { return }
        isInputEnabled = isEnabled
        if !isEnabled {
            emitReset(reason: .disabled)
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
        }
    }

    func prepareForDismantle() {
        emitReset(reason: .viewRemoved)
        stopObservingWindow()
    }

    override func becomeFirstResponder() -> Bool {
        guard isInputEnabled, super.becomeFirstResponder() else { return false }
        reducer.focusGained()
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        emitReset(reason: .focusLost)
        return true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow {
            emitReset(reason: .viewRemoved)
        }
        stopObservingWindow()
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObservingWindow()
    }

    override func mouseDown(with event: NSEvent) {
        beginPointer(.primary, with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        movePointer(.primary, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        endPointer(.primary, with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        beginPointer(.secondary, with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        movePointer(.secondary, with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        endPointer(.secondary, with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isInputEnabled else {
            super.keyDown(with: event)
            return
        }

        let key = TabletHardwareKey(event: event)
        guard
            !key.isCommandKey,
            !event.modifierFlags.contains(.command)
        else {
            isPassingThroughLocalCommandShortcut = true
            defer { isPassingThroughLocalCommandShortcut = false }
            super.keyDown(with: event)
            return
        }

        if let routed = reducer.keyDown(key, isRepeat: event.isARepeat) {
            emit(routed)
        }
        hardwareTextInterpretation = HardwareTextInterpretation(
            directCharacters: event.characters,
            beganWithMarkedText: hasMarkedText()
        )
        defer { hardwareTextInterpretation = nil }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        let key = TabletHardwareKey(event: event)
        if reducer.hasHeldKey(macKeyCode: key.macKeyCode),
           let routed = reducer.keyUp(key) {
            emit(routed)
            return
        }

        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        let key = TabletHardwareKey(event: event)
        guard !key.isCommandKey else {
            super.flagsChanged(with: event)
            return
        }

        if let routed = reducer.modifierFlagsChanged(key) {
            emit(routed)
        } else {
            super.flagsChanged(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        emitReset(reason: .pointerCancelled)
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.plainString(from: string)
        let wasMarkedText = hasMarkedText()
        clearMarkedText()
        if shouldSuppressDirectHardwareText(
            text,
            wasMarkedText: wasMarkedText
        ) {
            return
        }
        if let event = reducer.commitText(text) {
            emit(event)
        }
    }

    override func doCommand(by selector: Selector) {
        if isPassingThroughLocalCommandShortcut {
            super.doCommand(by: selector)
            return
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelOperation(nil)
        }
    }

    func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        if let attributed = string as? NSAttributedString {
            markedText = attributed.copy() as? NSAttributedString ?? attributed
        } else {
            markedText = NSAttributedString(string: Self.plainString(from: string))
        }

        let length = markedText.length
        let location = min(max(selectedRange.location, 0), length)
        let available = length - location
        markedSelection = NSRange(
            location: location,
            length: min(max(selectedRange.length, 0), available)
        )
    }

    func unmarkText() {
        clearMarkedText()
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard hasMarkedText() else { return nil }
        let available = NSRange(location: 0, length: markedText.length)
        let intersection = NSIntersectionRange(range, available)
        guard intersection.length > 0 else { return nil }
        actualRange?.pointee = intersection
        return markedText.attributedSubstring(from: intersection)
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = NSRange(location: 0, length: 0)
        guard let window else { return .zero }
        let localCaret = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: 1,
            height: 1
        )
        return window.convertToScreen(convert(localCaret, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    private func beginPointer(
        _ button: TabletPointerButton,
        with event: NSEvent
    ) {
        guard
            isInputEnabled,
            acquireFirstResponder(),
            let coordinate = coordinate(for: event)
        else {
            return
        }

        emit(reducer.pointerDown(button: button, at: coordinate))
    }

    private func movePointer(
        _ button: TabletPointerButton,
        with event: NSEvent
    ) {
        guard
            isInputEnabled,
            let coordinate = coordinate(for: event),
            let routed = reducer.pointerMoved(button: button, to: coordinate)
        else {
            return
        }
        emit(routed)
    }

    private func endPointer(
        _ button: TabletPointerButton,
        with event: NSEvent
    ) {
        guard isInputEnabled else { return }
        emit(
            reducer.pointerUp(
                button: button,
                at: coordinate(for: event)
            )
        )
    }

    private func acquireFirstResponder() -> Bool {
        guard let window else { return false }
        if window.firstResponder === self { return true }
        return window.makeFirstResponder(self)
    }

    private func coordinate(for event: NSEvent) -> TabletViewportCoordinate? {
        TabletCoordinateNormalizer.normalize(
            convert(event.locationInWindow, from: nil),
            in: bounds
        )
    }

    private func emit(_ event: TabletHostInputEvent) {
        eventHandler(event)
    }

    private func emit(_ events: [TabletHostInputEvent]) {
        events.forEach(eventHandler)
    }

    private func emitReset(reason: TabletInputResetReason) {
        clearMarkedText()
        if let event = reducer.requestReset(reason: reason) {
            emit(event)
        }
    }

    private func clearMarkedText() {
        markedText = NSAttributedString()
        markedSelection = NSRange(location: NSNotFound, length: 0)
    }

    private func shouldSuppressDirectHardwareText(
        _ text: String,
        wasMarkedText: Bool
    ) -> Bool {
        guard let interpretation = hardwareTextInterpretation else {
            return false
        }
        return !TabletHardwareTextPolicy.shouldEmitCommit(
            text,
            directHardwareCharacters: interpretation.directCharacters,
            beganWithMarkedText: interpretation.beganWithMarkedText,
            wasMarkedText: wasMarkedText
        )
    }

    private func startObservingWindow() {
        guard let window else { return }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: window
        )
    }

    private func stopObservingWindow() {
        guard let observedWindow else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didResignKeyNotification,
            object: observedWindow
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.willCloseNotification,
            object: observedWindow
        )
        self.observedWindow = nil
    }

    @objc private func windowDidResignKey(_ notification: Notification) {
        emitReset(reason: .windowLost)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        emitReset(reason: .windowLost)
    }

    private static func plainString(from value: Any) -> String {
        if let attributed = value as? NSAttributedString {
            return attributed.string
        }
        return value as? String ?? String(describing: value)
    }
}

/// SwiftUI seam for layering the AppKit input surface over the framebuffer.
@MainActor
struct TabletInputSurface: NSViewRepresentable {
    let mode: TabletInputMode
    let isEnabled: Bool
    let onEvent: TabletInputEventHandler

    func makeNSView(context: Context) -> TabletInputSurfaceView {
        TabletInputSurfaceView(
            mode: mode,
            isEnabled: isEnabled,
            onEvent: onEvent
        )
    }

    func updateNSView(
        _ view: TabletInputSurfaceView,
        context: Context
    ) {
        view.update(
            mode: mode,
            isEnabled: isEnabled,
            onEvent: onEvent
        )
    }

    static func dismantleNSView(
        _ view: TabletInputSurfaceView,
        coordinator: Void
    ) {
        view.prepareForDismantle()
    }
}

private extension BinaryFloatingPoint {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
