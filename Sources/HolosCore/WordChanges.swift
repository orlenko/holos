import Foundation

/// The words an edit added and removed (docs/design.md "Tidy Up"), for marking them and for `TextTidier.verdict`.
/// A word is a run of letters and digits, apostrophes inside it included ("don't", "l’heure"); words compare
/// lowercased, with ’ as '. Punctuation, capitals, spacing and line breaks are never changes.
public enum WordChanges {
    public struct Word: Sendable, Equatable {
        /// The word as compared: lowercased, ’ as '.
        public var word: String
        /// Where it is in its text, in UTF-16 offsets (`NSRange` units).
        public var range: Range<Int>
    }

    /// One place where the edit differs: the words it added there, and the original's words it removed.
    public struct Change: Sendable, Codable, Equatable {
        /// UTF-16 offset in the edit where the change is: its first added word, or where removed words were.
        public var location: Int
        /// UTF-16 length of the added words in the edit, the text between them included; 0 when it only removed.
        public var length: Int
        /// The removed words as written in the original, the text between them included; empty when it only added.
        public var removed: String

        public init(location: Int, length: Int, removed: String) {
            self.location = location
            self.length = length
            self.removed = removed
        }
    }

    /// The words of `text`, in order.
    public static func words(in text: String) -> [Word] {
        text.matches(of: wordPattern).map { match in
            let start = text.utf16.distance(from: text.startIndex, to: match.range.lowerBound)
            let length = text.utf16.distance(from: match.range.lowerBound, to: match.range.upperBound)
            let word = String(match.output).lowercased().replacingOccurrences(of: "’", with: "'")
            return Word(word: word, range: start ..< start + length)
        }
    }

    /// The changes from `original` to `edited`, in order: each run of removed and added words between two words both
    /// texts keep (Swift's `difference`, a shortest edit script).
    public static func between(_ original: String, _ edited: String) -> [Change] {
        let before = words(in: original)
        let after = words(in: edited)
        let difference = after.map(\.word).difference(from: before.map(\.word))
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        let source = original.utf16
        var changes: [Change] = []
        var i = 0
        var j = 0
        while i < before.count || j < after.count {
            let firstRemoved = i
            while i < before.count, removed.contains(i) { i += 1 }
            let firstInserted = j
            while j < after.count, inserted.contains(j) { j += 1 }
            if i > firstRemoved || j > firstInserted {
                let removedText = i > firstRemoved
                    ? text(source, before[firstRemoved].range.lowerBound ..< before[i - 1].range.upperBound) : ""
                if j > firstInserted {
                    let start = after[firstInserted].range.lowerBound
                    changes.append(Change(location: start, length: after[j - 1].range.upperBound - start,
                                          removed: removedText))
                } else {
                    let location = j > 0 ? after[j - 1].range.upperBound : 0
                    changes.append(Change(location: location, length: 0, removed: removedText))
                }
            }
            // The pair both texts keep (or the end of one text, once the other has no changes left).
            i += 1
            j += 1
        }
        return changes
    }

    private static func text(_ utf16: String.UTF16View, _ range: Range<Int>) -> String {
        let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end = utf16.index(start, offsetBy: range.count)
        return String(utf16[start ..< end]) ?? ""
    }

    // Built on each use: `Regex` is not `Sendable`, so it cannot be a stored static.
    private static var wordPattern: Regex<Substring> { /[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/ }
}
