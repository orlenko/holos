import AppKit
import ApplicationServices
import Carbon

/// Why the text selected in the front app could not be read.
public enum SelectedTextError: Error, LocalizedError, Equatable, Sendable {
    case accessibilityNotGranted
    case secureInput
    /// Nothing is selected, or the app does not tell Accessibility what is.
    case noSelection(app: String?)

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            "Reading the selection aloud needs Accessibility access for Voice is Local. Turn it on in System Settings."
        case .secureInput:
            "A password field or secure input is active, so the selection is not read."
        case .noSelection(let app):
            "No selected text found" + (app.map { " in \($0)" } ?? "") + ". Select some text, then press the shortcut "
                + "again; some apps do not share their selection."
        }
    }
}

/// The text selected in the front app, read through Accessibility (`kAXSelectedTextAttribute`) from the focused
/// element or, for web content whose focus sits on a child, the nearest element above it that has a selection. It
/// never copies: the pasteboard is left alone.
@MainActor
public enum SelectedText {
    /// How many elements above the focused one are asked for a selection.
    static let maximumAncestors = 8

    /// The selected text and the name of the app it is in.
    public static func read() throws -> (text: String, app: String?) {
        guard AXIsProcessTrusted() else { throw SelectedTextError.accessibilityNotGranted }
        if IsSecureEventInputEnabled() { throw SelectedTextError.secureInput }
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.localizedName
        // Chromium and Electron apps share their selection only once an assistive app has asked for their tree.
        if let front { TextInsertion.enableAccessibility(for: front) }
        let system = AXUIElementCreateSystemWide()
        // A hung app must not stall the main actor.
        AXUIElementSetMessagingTimeout(system, 0.4)
        guard let focused = element(system, kAXFocusedUIElementAttribute) else {
            throw SelectedTextError.noSelection(app: app)
        }
        if string(focused, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            throw SelectedTextError.secureInput
        }
        var current: AXUIElement? = focused
        for _ in 0...maximumAncestors {
            guard let element = current else { break }
            AXUIElementSetMessagingTimeout(element, 0.4)
            if let text = string(element, kAXSelectedTextAttribute).flatMap(cleaned) { return (text, app) }
            current = Self.element(element, kAXParentAttribute)
        }
        throw SelectedTextError.noSelection(app: app)
    }

    /// The text without the blank space around it; nil when nothing is left.
    nonisolated static func cleaned(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &raw) == .success else { return nil }
        return raw as? String
    }
}
