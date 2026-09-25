import AppKit
import ApplicationServices
import Carbon
import CryptoKit
import Foundation
import os

public enum TextInsertionError: Error, LocalizedError, Sendable {
    case secureInput
    case permissionDenied(String)
    /// The focused element offers no direct text write, as opposed to failing a safety check.
    case notWritable(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .secureInput: "Dictation is unavailable in a secure or password field."
        case .permissionDenied(let message), .notWritable(let message), .unsupported(let message): message
        }
    }
}

public enum InsertionOutcome: Sendable, Equatable {
    case inserted
    /// Keystrokes were posted to the target app; terminals cannot report what they received.
    case typed
    case needsCopy(String)
    /// The app or field changed since key-down, so pasting now would land somewhere else.
    case targetChanged(String)
    case unverified(String)
}

@MainActor public final class InsertionTarget {
    public let pid: pid_t
    public let selectedUTF16Range: NSRange
    fileprivate let element: AXUIElement
    fileprivate let snapshot: InsertionSnapshot

    fileprivate init(element: AXUIElement, snapshot: InsertionSnapshot) {
        self.element = element
        self.snapshot = snapshot
        self.pid = snapshot.pid
        self.selectedUTF16Range = snapshot.selection
    }
}

struct InsertionSnapshot: Equatable {
    let pid: pid_t
    let selection: NSRange
    let totalUTF16Length: Int
    let window: NSRange
    let fingerprint: String
    let secure: Bool
}

enum InsertionPolicy {
    static func permits(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value) ||
                CharacterSet.newlines.contains($0)
        }
    }

    static func window(selection: NSRange, totalLength: Int) -> NSRange? {
        guard totalLength >= 0, selection.location >= 0, selection.length >= 0,
              selection.location <= totalLength,
              selection.length <= 256,
              selection.length <= totalLength - selection.location else { return nil }
        let start = max(0, selection.location - 32)
        let selectedEnd = selection.location + selection.length
        let end = selectedEnd + min(32, totalLength - selectedEnd)
        return NSRange(location: start, length: end - start)
    }

    static func fingerprint(_ sample: String) -> String {
        SHA256.hash(data: Data(sample.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The part of `transcript` not yet written, or nil when it no longer extends what was written.
    static func pending(_ transcript: String, after written: String) -> String? {
        transcript.hasPrefix(written) ? String(transcript.dropFirst(written.count)) : nil
    }

    static func matches(_ target: InsertionSnapshot, _ live: InsertionSnapshot) -> Bool {
        !target.secure && !live.secure && target.pid == live.pid &&
            target.selection == live.selection && target.totalUTF16Length == live.totalUTF16Length &&
            target.window == live.window && target.fingerprint == live.fingerprint
    }
}

/// Where a terminal's keystrokes land, as far as Accessibility reports it: the process, its focused window and,
/// where the terminal exposes one, its focused element (Terminal and iTerm2 expose a text area per session, so
/// switching tabs or panes changes it). `Handle` is an Accessibility element in the app and a plain value in tests.
struct TerminalFocus<Handle: Equatable>: Equatable {
    var pid: pid_t
    var window: Handle?
    var element: Handle?

    enum Tracking: Equatable {
        /// The focused element: a switch of tab, pane or window is detected.
        case session
        /// Only the focused window: a switch of window, or of tab where each tab is its own window, is detected;
        /// a switch of pane inside one window is not.
        case window
        /// Only the frontmost app: no switch inside the terminal is detected.
        case app
    }

    var tracking: Tracking { element != nil ? .session : window != nil ? .window : .app }

    /// The focus at key-down: the first of two consecutive reads that agree, taking the first read and up to
    /// `retries` more. Nil when no two consecutive reads agree: focus moved while it was being captured (or the
    /// terminal hands out a new identity on every read), so which session was focused at key-down is unknown.
    /// A disagreement never weakens tracking, since typing into an app-only target could reach the session the
    /// user just switched away from.
    static func settled(retries: Int = 3, _ read: () -> TerminalFocus) -> TerminalFocus? {
        var previous = read()
        for _ in 0..<max(retries, 1) {
            let next = read()
            if next == previous { return previous }
            previous = next
        }
        return nil
    }

    /// Whether keystrokes may still go to the focus captured at key-down (`self`): the same process, and every
    /// identity it reported then still reported and unchanged. An identity it did not report is not checked.
    func admits(_ live: TerminalFocus) -> Bool {
        guard pid == live.pid else { return false }
        if let window, live.window != window { return false }
        if let element, live.element != element { return false }
        return true
    }

    /// `admits`, reading only the identities this focus tracks: `read` is asked for the live focus at `tracking`
    /// and is not called at all for app-only tracking, whose process is already checked against the frontmost app.
    /// Each Accessibility read can wait out its timeout, so reading what `admits` would ignore only stalls typing.
    func stillAdmitted(_ read: (Tracking) -> TerminalFocus) -> Bool {
        tracking == .app || admits(read(tracking))
    }
}

/// An Accessibility element compared by identity (`CFEqual`), for `TerminalFocus`.
struct AXHandle: Equatable {
    let element: AXUIElement
    static func == (lhs: AXHandle, rhs: AXHandle) -> Bool { CFEqual(lhs.element, rhs.element) }
}

@MainActor public enum TextInsertion {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "insertion")

    public static func isSecureInputActive() -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard AXIsProcessTrusted(), let element = try? focusedElement() else { return false }
        return secureSubrole(element)
    }

    public static func captureTarget() throws -> InsertionTarget {
        if IsSecureEventInputEnabled() { throw TextInsertionError.secureInput }
        guard AXIsProcessTrusted() else {
            throw TextInsertionError.permissionDenied("Accessibility permission is required to capture the target text field.")
        }
        let element = try focusedElement()
        let snapshot = try readSnapshot(element)
        var writable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &writable) == .success,
              writable.boolValue else {
            throw TextInsertionError.notWritable("The focused field does not support direct selected-text insertion. Copy the transcript instead.")
        }
        return InsertionTarget(element: element, snapshot: snapshot)
    }

    public static func insert(_ text: String, into target: InsertionTarget) -> InsertionOutcome {
        guard InsertionPolicy.permits(text) else {
            return .needsCopy("Text contains a line break or control character; copy it explicitly.")
        }
        guard !isSecureInputActive() else {
            return .needsCopy("The focused field uses secure input; insertion was skipped.")
        }
        guard let liveElement = try? focusedElement(), CFEqual(liveElement, target.element),
              let live = try? readSnapshot(liveElement),
              InsertionPolicy.matches(target.snapshot, live) else {
            log.notice("Insert refused: focus or field state differs from the snapshot")
            return .targetChanged("Focus, selection, or nearby text changed; copy the transcript explicitly.")
        }
        var writable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(liveElement, kAXSelectedTextAttribute as CFString, &writable) == .success,
              writable.boolValue else {
            return .needsCopy("The focused field cannot replace selected text directly.")
        }

        // Exactly one write attempt. A failure could still have changed the target, so never retry.
        let status = AXUIElementSetAttributeValue(liveElement, kAXSelectedTextAttribute as CFString,
                                                  text as CFString)
        guard status == .success else {
            log.notice("Insert unverified: AXSelectedText write returned \(status.rawValue)")
            return .unverified("Accessibility did not confirm insertion; inspect the field before copying.")
        }
        let insertedUnits = text.utf16.count
        let remainingUnits = target.snapshot.totalUTF16Length - target.selectedUTF16Range.length
        guard insertedUnits <= 4_096, remainingUnits <= Int.max - insertedUnits else {
            return .unverified("Could not verify the inserted text; inspect the field before copying.")
        }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == target.pid,
              let focused = try? focusedElement(), CFEqual(focused, target.element),
              let length = try? characterCount(target.element),
              length == remainingUnits + insertedUnits,
              let observed = try? stringForRange(target.element,
                  NSRange(location: target.selectedUTF16Range.location, length: insertedUnits)),
              observed == text else {
            log.notice("Insert unverified: read-back did not match")
            return .unverified("Could not verify the inserted text; inspect the field before copying.")
        }
        return .inserted
    }

    /// The focused element right now, if Accessibility can report one.
    public static func currentFocus() -> AXUIElement? { try? focusedElement() }

    /// Whether `element` still has keyboard focus in the frontmost app.
    public static func stillFocused(_ element: AXUIElement) -> Bool {
        guard let focused = try? focusedElement() else { return false }
        return CFEqual(focused, element)
    }

    /// The part of a growing transcript not yet written, or nil when it no longer extends `written`.
    public static func unwritten(_ transcript: String, after written: String) -> String? {
        InsertionPolicy.pending(transcript, after: written)
    }

    /// After a verified insert, the target for the next streamed chunk: the caret must sit right after
    /// the inserted text and the field must not have changed otherwise. Nil stops streaming.
    public static func advance(_ target: InsertionTarget, past text: String) -> InsertionTarget? {
        let inserted = text.utf16.count
        let expectedSelection = NSRange(location: target.selectedUTF16Range.location + inserted, length: 0)
        let expectedLength = target.snapshot.totalUTF16Length - target.selectedUTF16Range.length + inserted
        guard let live = try? readSnapshot(target.element) else {
            log.notice("Advance failed: field snapshot unreadable")
            return nil
        }
        guard live.pid == target.pid, live.selection == expectedSelection,
              live.totalUTF16Length == expectedLength else {
            log.notice("""
                Advance failed: selection \(live.selection.location),\(live.selection.length) \
                expected \(expectedSelection.location),0; length \(live.totalUTF16Length) expected \(expectedLength)
                """)
            return nil
        }
        return InsertionTarget(element: target.element, snapshot: live)
    }

    /// Chromium browsers and Electron apps build their accessibility tree only when an assistive app
    /// asks for it; until then the system reports no focused element. Safe to call for any app.
    public static func enableAccessibility(for app: NSRunningApplication) {
        // Only Chromium and Electron apps need this; asking every activated app would put a cross-process
        // call on the main actor for apps that gain nothing from it.
        guard chromiumBrowserBundleIDs.contains(app.bundleIdentifier ?? "") || isElectron(app) else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // A hung app must not stall Holos's menu and hotkey handling.
        AXUIElementSetMessagingTimeout(element, 0.25)
        let manual = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard manual != .success, chromiumBrowserBundleIDs.contains(app.bundleIdentifier ?? "") else { return }
        // Older Chromium builds only respond to the VoiceOver switch.
        let enhanced = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        log.notice("Enabled accessibility for \(app.bundleIdentifier ?? "?", privacy: .public) via AXEnhancedUserInterface: \(enhanced.rawValue)")
    }

    private static func isElectron(_ app: NSRunningApplication) -> Bool {
        guard let bundle = app.bundleURL else { return false }
        let framework = bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }

    static let chromiumBrowserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    /// The focused element when it accepts typing (a text field, text area, combo box, or rich-text
    /// editor such as a web contenteditable), even if it does not support direct Accessibility writes.
    static func focusedEditableElement() -> AXUIElement? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let element = try? focusedElement(),
              !secureSubrole(element) else { return nil }
        if isWebEditable(element) { return element }
        let role = (try? attribute(element, kAXRoleAttribute as CFString)) as? String
        let editableRoles = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].map { $0 as String }
        guard let role, editableRoles.contains(role) else { return nil }
        // A read-only or disabled field would silently ignore keystrokes while Holos reports success.
        if let enabled = (try? attribute(element, kAXEnabledAttribute as CFString)) as? Bool, !enabled { return nil }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return element
    }

    /// Editable web content (inputs, text areas, rich-text editors) reports its editable root through
    /// this attribute. Browsers accept Accessibility writes there but do not read them back reliably.
    static func isWebEditable(_ element: AXUIElement) -> Bool {
        (try? attribute(element, "AXEditableAncestor" as CFString)) != nil
    }

    static func focusedElement() throws -> AXUIElement {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            throw TextInsertionError.unsupported("No frontmost application is available for insertion.")
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        guard let value = try? attribute(system, kAXFocusedUIElementAttribute as CFString),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw TextInsertionError.unsupported("No accessible focused text field is available.")
        }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.4)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == frontmost.processIdentifier else {
            throw TextInsertionError.unsupported("The focused field no longer belongs to the frontmost application.")
        }
        return element
    }

    /// The terminal's focused window and element right now; either is nil when the app does not report it.
    /// `tracking` limits what is read: `.window` skips the focused element and `.app` reads nothing.
    static func terminalFocus(pid: pid_t,
                              reading tracking: TerminalFocus<AXHandle>.Tracking = .session) -> TerminalFocus<AXHandle> {
        guard tracking != .app, AXIsProcessTrusted() else { return TerminalFocus(pid: pid) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        func handle(_ key: String) -> AXHandle? {
            guard let value = try? attribute(app, key as CFString),
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return AXHandle(element: value as! AXUIElement)
        }
        return TerminalFocus(pid: pid, window: handle(kAXFocusedWindowAttribute),
                             element: tracking == .session ? handle(kAXFocusedUIElementAttribute) : nil)
    }

    private static func readSnapshot(_ element: AXUIElement) throws -> InsertionSnapshot {
        if IsSecureEventInputEnabled() || secureSubrole(element) { throw TextInsertionError.secureInput }
        guard let role = try? attribute(element, kAXRoleAttribute as CFString) as? String,
              role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) else {
            throw TextInsertionError.notWritable("The focused element is not a supported plain text field.")
        }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            throw TextInsertionError.unsupported("Could not identify the focused field's application.")
        }
        let total = try characterCount(element)
        let selection = try selectedRange(element)
        guard let window = InsertionPolicy.window(selection: selection, totalLength: total) else {
            throw TextInsertionError.unsupported("The selected text range is unavailable or too large for safe insertion.")
        }
        let sample = try stringForRange(element, window)
        guard sample.utf16.count == window.length else {
            throw TextInsertionError.unsupported("The focused field returned an inconsistent text range.")
        }
        return InsertionSnapshot(pid: pid, selection: selection, totalUTF16Length: total,
                                 window: window, fingerprint: InsertionPolicy.fingerprint(sample),
                                 secure: false)
    }

    private static func secureSubrole(_ element: AXUIElement) -> Bool {
        guard let subrole = try? attribute(element, kAXSubroleAttribute as CFString) as? String else { return false }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private static func characterCount(_ element: AXUIElement) throws -> Int {
        guard let number = try? attribute(element, kAXNumberOfCharactersAttribute as CFString) as? NSNumber,
              number.intValue >= 0 else {
            throw TextInsertionError.unsupported("The focused field does not expose a bounded text length.")
        }
        return number.intValue
    }

    private static func selectedRange(_ element: AXUIElement) throws -> NSRange {
        let raw = try attribute(element, kAXSelectedTextRangeAttribute as CFString)
        guard CFGetTypeID(raw) == AXValueGetTypeID() else {
            throw TextInsertionError.unsupported("The focused field has no selected-text range.")
        }
        let value = raw as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange,
              AXValueGetValue(value, .cfRange, &range) else {
            throw TextInsertionError.unsupported("The selected-text range has an unsupported format.")
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func stringForRange(_ element: AXUIElement, _ range: NSRange) throws -> String {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            throw TextInsertionError.unsupported("Could not inspect the focused text range.")
        }
        var raw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
            kAXStringForRangeParameterizedAttribute as CFString, parameter, &raw) == .success,
              let text = raw as? String else {
            throw TextInsertionError.unsupported("The focused field does not support bounded text inspection.")
        }
        return text
    }

    private static func attribute(_ element: AXUIElement, _ key: CFString) throws -> CFTypeRef {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &raw) == .success, let raw else {
            throw TextInsertionError.unsupported("The focused field does not expose \(key).")
        }
        return raw
    }
}

/// Terminals draw their input line rather than exposing a writable text field, so text reaches them
/// only as keystrokes. Keystrokes go to the captured process and cannot be read back.
@MainActor public final class KeystrokeTarget {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "insertion")

    /// Marks Holos's own keystrokes so the hotkey monitor does not treat them as typing.
    public static let syntheticEventMarker: Int64 = 0x484F_4C4F_53

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
        "net.kovidgoyal.kitty", "org.alacritty", "dev.warp.Warp-Stable",
    ]

    public let pid: pid_t
    public let appName: String
    /// For a field in a regular app, the element that must still have focus before each chunk.
    private let element: AXUIElement?
    /// For a terminal, the window and session focused at key-down, which must still have focus before each chunk.
    private let terminalFocus: TerminalFocus<AXHandle>?

    private init(pid: pid_t, appName: String, element: AXUIElement? = nil,
                 terminalFocus: TerminalFocus<AXHandle>? = nil) {
        self.pid = pid
        self.appName = appName
        self.element = element
        self.terminalFocus = terminalFocus
    }

    /// A target when the frontmost app is a known terminal; nil otherwise. Typing stops when the terminal's
    /// focused window or session (tab or pane) changes, as far as the terminal reports them to Accessibility.
    /// Throws when the terminal's focus kept changing while it was captured: the session focused at key-down is
    /// unknown, so this dictation must not be typed anywhere.
    public static func captureTerminal() throws -> KeystrokeTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier, terminalBundleIDs.contains(bundleID) else { return nil }
        let pid = app.processIdentifier
        guard let focus = TerminalFocus.settled({ TextInsertion.terminalFocus(pid: pid) }) else {
            log.notice("Terminal \(bundleID, privacy: .public) focus changed during capture; typing refused")
            throw TextInsertionError.unsupported("The terminal's focus changed as dictation started.")
        }
        log.notice("Terminal \(bundleID, privacy: .public) focus tracked by \(String(describing: focus.tracking), privacy: .public)")
        return KeystrokeTarget(pid: pid, appName: app.localizedName ?? bundleID, terminalFocus: focus)
    }

    /// A target for a focused editable field that cannot take a direct Accessibility write, such as a
    /// web editor. Typing stops as soon as focus leaves that exact element.
    /// A target for editable web content, which is typed into rather than written through Accessibility.
    public static func captureWebEditor() -> KeystrokeTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = TextInsertion.focusedEditableElement(),
              TextInsertion.isWebEditable(element) else { return nil }
        return KeystrokeTarget(pid: app.processIdentifier, appName: app.localizedName ?? "the browser", element: element)
    }

    public static func captureEditableField() -> KeystrokeTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let element = TextInsertion.focusedEditableElement() else { return nil }
        return KeystrokeTarget(pid: app.processIdentifier, appName: app.localizedName ?? "the app", element: element)
    }

    private func stillTargeted() -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }
        if let terminalFocus {
            return terminalFocus.stillAdmitted { TextInsertion.terminalFocus(pid: pid, reading: $0) }
        }
        guard let element else { return true }
        guard let focused = try? TextInsertion.focusedElement() else { return false }
        return CFEqual(focused, element)
    }

    public func type(_ text: String) -> InsertionOutcome {
        guard InsertionPolicy.permits(text) else {
            return .needsCopy("Text contains a line break or control character; copy it explicitly.")
        }
        guard !IsSecureEventInputEnabled() else {
            return .needsCopy("Secure keyboard entry is on; typing was skipped.")
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            return .targetChanged("\(appName) is no longer frontmost; copy the transcript explicitly.")
        }
        guard stillTargeted() else {
            let moved = terminalFocus == nil ? "a different field" : "a different terminal tab, pane or window"
            return .targetChanged("Focus moved to \(moved); copy the transcript explicitly.")
        }
        // A private source keeps the held shortcut modifier out of the typed characters.
        let source = CGEventSource(stateID: .privateState)
        let started = ContinuousClock.now
        let heldFlags = CGEventSource.flagsState(.hidSystemState)
        defer {
            let elapsed = started.duration(to: .now)
            Self.log.notice("""
                Typed \(text.count) characters into \(self.appName, privacy: .public) (pid \(self.pid)) in \
                \(elapsed.components.attoseconds / 1_000_000_000_000_000 + elapsed.components.seconds * 1000) ms; \
                option held: \(heldFlags.contains(.maskAlternate)), secure input: \(IsSecureEventInputEnabled())
                """)
        }
        for (index, character) in text.enumerated() {
            // Recheck in bounded steps so a focus change mid-chunk stops typing into the wrong control.
            if index > 0, index.isMultiple(of: 16), !stillTargeted() {
                return .unverified("Focus moved while typing; check \(appName) before pasting the rest.")
            }
            let units = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                    return .unverified("Could not create a keystroke; inspect \(appName) before copying.")
                }
                event.flags = []
                units.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventMarker)
                event.postToPid(pid)
            }
        }
        return .typed
    }
}
