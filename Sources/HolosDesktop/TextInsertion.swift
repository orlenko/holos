import AppKit
import ApplicationServices
import Carbon
import CryptoKit
import Foundation

public enum TextInsertionError: Error, LocalizedError, Sendable {
    case secureInput
    case permissionDenied(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .secureInput: "Dictation is unavailable in a secure or password field."
        case .permissionDenied(let message), .unsupported(let message): message
        }
    }
}

public enum InsertionOutcome: Sendable, Equatable {
    case inserted
    case needsCopy(String)
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

    static func matches(_ target: InsertionSnapshot, _ live: InsertionSnapshot) -> Bool {
        !target.secure && !live.secure && target.pid == live.pid &&
            target.selection == live.selection && target.totalUTF16Length == live.totalUTF16Length &&
            target.window == live.window && target.fingerprint == live.fingerprint
    }
}

@MainActor public enum TextInsertion {
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
            throw TextInsertionError.unsupported("The focused field does not support direct selected-text insertion. Copy the transcript instead.")
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
            return .needsCopy("Focus, selection, or nearby text changed; copy the transcript explicitly.")
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
            return .unverified("Could not verify the inserted text; inspect the field before copying.")
        }
        return .inserted
    }

    private static func focusedElement() throws -> AXUIElement {
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

    private static func readSnapshot(_ element: AXUIElement) throws -> InsertionSnapshot {
        if IsSecureEventInputEnabled() || secureSubrole(element) { throw TextInsertionError.secureInput }
        guard let role = try? attribute(element, kAXRoleAttribute as CFString) as? String,
              role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) else {
            throw TextInsertionError.unsupported("The focused element is not a supported plain text field.")
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
