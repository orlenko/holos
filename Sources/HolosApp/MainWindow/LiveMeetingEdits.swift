import AppKit
import HolosMeeting

/// A finalized phrase of the live transcript that Correct Text… and Name Speaker… act on (docs/design.md "Live
/// transcript"): where its words are in the shown text, and the hint a correction or a name starts from.
struct LiveEditTarget {
    var range: NSRange
    var hint: LiveHint
    var speakerName: String?

    /// The same phrase in the next rendering of the text: its segment and its words, which a correction keeps (an
    /// echo that splits a segment makes new phrases, and the selection is dropped rather than moved to other words).
    var key: String { "\(hint.segmentID)#\(hint.firstWord)-\(hint.endWord)" }

    /// The one phrase `selected` is in: the phrase around the insertion point, or the only phrase a selection
    /// touches. Nil for none or several.
    static func only(in selected: NSRange, among targets: [LiveEditTarget]) -> LiveEditTarget? {
        let matches = targets.filter { target in
            if selected.length == 0 {
                return selected.location >= target.range.location && selected.location < NSMaxRange(target.range)
            }
            return NSIntersectionRange(selected, target.range).length > 0
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

/// The selection inside one phrase, carried across the view's re-rendering of its text four times a second.
/// Replacing the text moves the selection to its end, which turned Correct Text… and Name Speaker… off a moment
/// after the user selected a phrase.
struct LiveSelectionAnchor: Equatable {
    var key: String
    /// Where the selection starts in the phrase's text, and its length.
    var offset: Int
    var length: Int

    /// The anchor of `selected` when it lies in exactly one phrase; the part of the selection outside it is dropped.
    init?(selected: NSRange, targets: [LiveEditTarget]) {
        guard let target = LiveEditTarget.only(in: selected, among: targets) else { return nil }
        key = target.key
        let inside = selected.length == 0 ? selected : NSIntersectionRange(selected, target.range)
        offset = inside.location - target.range.location
        length = inside.length
    }

    /// The same place in `targets`, cut to the phrase and starting inside it when its text got shorter (a correction);
    /// nil when the phrase is no longer shown.
    func range(in targets: [LiveEditTarget]) -> NSRange? {
        guard let target = targets.first(where: { $0.key == key }), target.range.length > 0 else { return nil }
        // The selection starts inside the phrase, so the phrase stays selected.
        let start = min(offset, target.range.length - 1)
        return NSRange(location: target.range.location + start, length: min(length, target.range.length - start))
    }
}

enum LiveSpeakerNames {
    /// What Name Speaker… offers: the names given in this meeting first, then the people in People, each once
    /// (letter case ignored), in that order.
    static func choices(inMeeting: [String], known: [String]) -> [String] {
        var seen = Set<String>()
        return (inMeeting + known).compactMap { name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
    }
}

/// A text field that selects `initialSelection` when it takes the keyboard, not all of its text: Correct Text…
/// opens with the words the user selected highlighted, so typing replaces only them.
final class PreselectingTextField: NSTextField {
    var initialSelection: NSRange?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let selection = initialSelection, let editor = currentEditor(),
           NSMaxRange(selection) <= (stringValue as NSString).length {
            editor.selectedRange = selection
        }
        return became
    }
}
