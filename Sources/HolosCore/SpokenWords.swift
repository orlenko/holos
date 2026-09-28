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

    /// Whether `heard` could be a mishearing of `meant` (or the reverse), for the guard on a model's reply. Compared
    /// as `letters`: the same letters; homophones the rules miss (`homophones`: "one" and "won", "you" and "ewe");
    /// at most one letter apart or 70 % of the letters the same (by edit distance); the same `sound` ("write" and
    /// "right", "ate" and "eight", "knight" and "night", "their" and "there"); or the same `roughSound` with at least
    /// half the letters the same ("cold" and "called", "a bundo" and "ubuntu"). "windows" and "Ubuntu" are none of
    /// these, nor "opened" and "Ubuntu", nor "point" and "Bundo".
    public static func isClose(_ heard: String, _ meant: String) -> Bool {
        let a = letters(heard), b = letters(meant)
        if a == b || areHomophones(a, b) { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let distance = editDistance(Array(a), Array(b))
        let longer = max(a.count, b.count)
        if distance <= 1 || Double(distance) <= 0.3 * Double(longer) { return true }
        let soundA = sound(a), soundB = sound(b)
        if soundA == soundB { return true }
        return 2 * distance <= longer && roughSound(soundA) == roughSound(soundB)
    }

    /// Whether `word`, in a text, could be `heard`, a word of a taught heard phrase, misheard again a little
    /// differently ("bundu" for "Bundo", "Timox" for "Timok's", "mix" for "Max"). Stricter than `isClose`: a match
    /// lets the taught spelling replace the word. The same letters or homophones; otherwise the same first letter or
    /// first sound, and at most one letter apart, 70 % of the letters the same, or the same `sound` with at least
    /// half the letters the same. "point" is not "Bundo" (both "pnt" roughly), nor "tax" "Max".
    public static func isVariant(_ word: String, of heard: String) -> Bool {
        let a = letters(word), b = letters(heard)
        if a == b || areHomophones(a, b) { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let soundA = sound(a), soundB = sound(b)
        guard a.first == b.first || soundA.first == soundB.first else { return false }
        let distance = editDistance(Array(a), Array(b))
        let longer = max(a.count, b.count)
        if distance <= 1 || Double(distance) <= 0.3 * Double(longer) { return true }
        return 2 * distance <= longer && soundA == soundB
    }

    /// Homophones whose spellings `sound` does not bring together, as `letters`: a vowel said with a glide the
    /// spelling does not show ("one" and "won", "you" and "ewe"), a silent "h" before a vowel ("our" and "hour"), and
    /// French words whose silent endings differ ("vert" and "verre", "sans" and "cent").
    static let homophones: [Set<String>] = [
        ["one", "won"], ["two", "to", "too"], ["you", "ewe", "yew", "u"], ["eight", "ate"], ["our", "hour"],
        ["air", "heir"], ["wood", "would"], ["ill", "isle", "aisle"],
        ["sans", "cent", "sang", "sent", "sen"], ["vers", "vert", "verre", "ver"], ["foi", "fois", "foie"],
        ["cour", "cours", "court"], ["temps", "tant", "tend", "tends"], ["vin", "vingt", "vain"],
        ["eau", "haut", "au", "aux", "o"], ["sept", "set", "cet", "cette"], ["pain", "pin", "peint"],
        ["point", "poing"], ["cou", "coup", "cout"], ["sot", "seau", "saut", "sceau"], ["mot", "maux"],
        ["pere", "paire", "pair", "perd"],
    ]

    static func areHomophones(_ a: String, _ b: String) -> Bool {
        homophones.contains { $0.contains(a) && $0.contains(b) }
    }

    /// A rough pronunciation of `letters` (from `letters(_:)`). Silent letters are dropped: a first "k", "g", "p"
    /// or "m" before "n", "w" before "r", "p" before "s" or "t", the "w" or "h" of a first "wh" ("which", "whole"),
    /// "gh" after the first letter ("night", "eight"), a last "e" after a consonant, a "w" or "h" not before a vowel.
    /// Spellings of one sound become one: "ph" f, "ck" and "q" k, "c" before e, i or y s, "dg" and "g" before e, i or
    /// y j, "th" θ, "sh", "ch" and "tch" X, "x" ks, "z" s, a last "mb" m. Each run of vowels (with a "y", "w" or "h"
    /// after them) is one "a", and a sound repeated is kept once. Consonants keep their identity: "point" is "pant"
    /// and "Bundo" "banda".
    static func sound(_ letters: String) -> String {
        var s = Array(letters)
        if s.count > 2 {
            switch String(s[0...1]) {
            case "kn", "gn", "pn", "mn", "wr", "ps", "pt": s.removeFirst()
            case "wh": s.remove(at: s[2] == "o" ? 0 : 1)
            default: break
            }
        }
        if s.count > 2, s.last == "e", !isVowel(s[s.count - 2]) { s.removeLast() }
        func vowel(at index: Int) -> Bool {
            guard index < s.count else { return false }
            return isVowel(s[index]) || (s[index] == "y" && !(index + 1 < s.count && isVowel(s[index + 1])))
        }
        func at(_ index: Int) -> Character? { index < s.count ? s[index] : nil }
        var out: [Character] = []
        func emit(_ sound: Character) { if out.last != sound { out.append(sound) } }
        var i = 0
        while i < s.count {
            let next = at(i + 1), afterNext = at(i + 2)
            let afterVowel = out.last == "a"
            var step = 1
            switch s[i] {
            case "a", "e", "i", "o", "u": emit("a")
            case "y": emit(!afterVowel && vowel(at: i + 1) ? "y" : "a")
            case "w": if !afterVowel && vowel(at: i + 1) { emit("w") }
            case "h": if vowel(at: i + 1) { emit("h") }
            case "c":
                if next == "h" { emit("X"); step = 2 }
                else if let next, "eiy".contains(next) { emit("s") }
                else { emit("k"); if next == "k" { step = 2 } }
            case "s": if next == "h" { emit("X"); step = 2 } else { emit("s") }
            case "t":
                if next == "h" { emit("θ"); step = 2 }
                else if !(next == "c" && afterNext == "h") { emit("t") }
            case "p": if next == "h" { emit("f"); step = 2 } else { emit("p") }
            case "g":
                if next == "h" { if i == 0 { emit("g") }; step = 2 }
                else if let next, "eiy".contains(next) { emit("j") }
                else if !(next == "n" && afterNext == nil) { emit("g") }
            case "d": if !(next == "g" && afterNext.map { "eiy".contains($0) } == true) { emit("d") }
            case "q": emit("k")
            case "x": emit("k"); emit("s")
            case "z": emit("s")
            case "m": emit("m"); if next == "b" && afterNext == nil { step = 2 }
            case let other: emit(other)
            }
            i += step
        }
        return String(out)
    }

    /// `sound` with voiced and voiceless consonants made one (b p, d t, g k, v f, j X) and the vowels dropped, but
    /// for a leading one: "cold" and "called" are both "klt", "a bundo" and "ubuntu" both "apnt".
    static func roughSound(_ sound: String) -> String {
        var out: [Character] = []
        for (index, sound) in sound.enumerated() {
            if sound == "a" {
                if index == 0 { out.append("a") }
                continue
            }
            let merged: Character = switch sound {
            case "b": "p"
            case "d": "t"
            case "g": "k"
            case "v": "f"
            case "j": "X"
            default: sound
            }
            if out.last != merged { out.append(merged) }
        }
        return String(out)
    }

    static func isVowel(_ letter: Character) -> Bool { "aeiou".contains(letter) }

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
