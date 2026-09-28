import Foundation

/// How dictated words compare: which words carry meaning, and whether one word could be a mishearing of another.
/// Shared by the choice of learned corrections to show the model, the guard on its reply, and the recognizer's
/// vocabulary. Words are compared as `AIFixGuard.words` gives them (lowercased, plain apostrophes).
public enum SpokenWords {
    /// Function words of the dictation languages tried so far (English and French). They appear in almost every
    /// sentence, so sharing one says nothing about whether a correction applies: "a Bundo -> ubuntu" shares "a"
    /// with most English text.
    static let stopWords: Set<String> = [
        // English
        "about", "above", "after", "again", "against", "all", "also", "and", "any", "are", "aren't", "because",
        "been", "before", "being", "below", "between", "both", "but", "can", "can't", "cannot", "could",
        "couldn't", "did", "didn't", "does", "doesn't", "doing", "don't", "down", "during", "each", "even", "ever",
        "few", "for", "from", "further", "get", "got", "had", "hadn't", "has", "hasn't", "have", "haven't",
        "having", "her", "here", "here's", "hers", "herself", "him", "himself", "his", "how", "i'd", "i'll", "i'm",
        "i've", "into", "isn't", "it's", "its", "itself", "just", "let's", "may", "might", "more", "most", "much",
        "must", "mustn't", "myself", "nor", "not", "now", "off", "once", "one", "only", "other", "our", "ours",
        "ourselves", "out", "over", "own", "same", "she", "she'd", "she'll", "she's", "should", "shouldn't", "some",
        "such", "than", "that", "that's", "the", "their", "theirs", "them", "themselves", "then", "there",
        "there's", "these", "they", "they'd", "they'll", "they're", "they've", "this", "those", "through", "too",
        "under", "until", "very", "was", "wasn't", "we'd", "we'll", "we're", "we've", "were", "weren't", "what",
        "what's", "when", "where", "which", "while", "who", "who's", "whom", "why", "will", "with", "won't",
        "would", "wouldn't", "yes", "yet", "you", "you'd", "you'll", "you're", "you've", "your", "yours",
        "yourself", "yourselves", "okay", "really", "like", "well", "still", "thing",
        "things", "going", "gonna", "want", "wanna",
        // French
        "au", "aux", "avec", "ce", "ceci", "cela", "celle", "celles", "celui", "ces", "cet", "cette", "ceux",
        "c'est", "chez", "comme", "dans", "des", "donc", "dont", "elle", "elles", "est", "et", "été",
        "être", "eux", "fait", "faut", "ici", "il", "ils", "j'ai", "je", "la", "le", "les", "leur", "leurs", "lui",
        "mais", "mes", "moi", "mon", "même", "nos", "notre", "nous", "n'est", "n'y", "ont", "ou", "où", "par",
        "pas", "peu", "peut", "plus", "pour", "qu'il", "qu'elle", "quand", "que", "quel", "quelle", "quels",
        "quelles", "qui", "quoi", "sans", "ses", "son", "sont", "sous", "sur", "ta", "tes", "toi", "ton", "tous",
        "tout", "toute", "toutes", "très", "trop", "une", "vos", "votre", "vous", "était", "avoir", "avait", "aussi",
        "alors", "encore", "bien", "oui", "non", "voilà", "y'a", "d'un", "d'une", "l'on", "s'il",
    ]

    /// A word that carries meaning: not a function word and at least three letters.
    public static func isContent(_ word: String) -> Bool {
        let word = word.lowercased().replacingOccurrences(of: "’", with: "'")
        return letters(word).count >= 3 && !stopWords.contains(word)
    }

    /// Lowercased letters and digits of `text`, without diacritics, apostrophes, hyphens or spaces: "C'est" is
    /// "cest", "ça" is "ca", "on Ubuntu" is "onubuntu".
    public static func letters(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }

    /// Whether `heard` could be a mishearing of `meant` (or the reverse), compared as `letters`: the same letters,
    /// at most one letter apart, 70 % of the letters the same (by edit distance), or the same `phoneticKey`
    /// ("their" and "there", "cold" and "called", "pear" and "pair"). "windows" and "Ubuntu" are none of these.
    public static func isClose(_ heard: String, _ meant: String) -> Bool {
        let a = letters(heard), b = letters(meant)
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let distance = editDistance(Array(a), Array(b))
        if distance <= 1 { return true }
        if Double(distance) <= 0.3 * Double(max(a.count, b.count)) { return true }
        return phoneticKey(a) == phoneticKey(b)
    }

    /// A rough sound of `letters` (from `letters(_:)`), close to Soundex: consonants by group (b f p v, c g j k q s
    /// x z, d t, l, m n, r), a run of one group counted once, vowels dropped, and "V" first when the word starts
    /// with a vowel, so "count" is not "Uguntu". Digits stay as they are.
    static func phoneticKey(_ letters: String) -> String {
        var key = letters.first.map { "aeiou".contains($0) } == true ? "V" : ""
        var last: Character?
        for letter in letters {
            let code: Character?
            switch letter {
            case "b", "f", "p", "v": code = "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": code = "2"
            case "d", "t": code = "3"
            case "l": code = "4"
            case "m", "n": code = "5"
            case "r": code = "6"
            case "h", "w", "y": continue  // silent or glides: they do not separate a repeated consonant
            default: code = letter.isNumber ? letter : nil
            }
            if let code, code != last { key.append(code) }
            last = code
        }
        return key
    }

    /// Letter-level Levenshtein distance.
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = previous
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
