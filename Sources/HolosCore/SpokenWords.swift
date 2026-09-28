import Foundation

/// How dictated words compare: which words carry meaning, and whether one word could be a mishearing of another.
/// Shared by the choice of learned corrections to show the model, the guard on its reply, and the recognizer's
/// vocabulary. Words are compared as `AIFixGuard.words` gives them (lowercased, plain apostrophes).
public enum SpokenWords {
    /// Function words of the dictation languages tried so far (English and French). They appear in almost every
    /// sentence, so sharing one says nothing about whether a correction applies: "a Bundo -> ubuntu" shares "a"
    /// with most English text. Each language has its own: the French "son" is the English "son".
    static let englishStopWords: Set<String> = [
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
    ]

    static let frenchStopWords: Set<String> = [
        "au", "aux", "avec", "ce", "ceci", "cela", "celle", "celles", "celui", "ces", "cet", "cette", "ceux",
        "c'est", "chez", "comme", "dans", "des", "donc", "dont", "elle", "elles", "est", "et", "été",
        "être", "eux", "fait", "faut", "ici", "il", "ils", "j'ai", "je", "la", "le", "les", "leur", "leurs", "lui",
        "mais", "mes", "moi", "mon", "même", "nos", "notre", "nous", "n'est", "n'y", "ont", "ou", "où", "par",
        "pas", "peu", "peut", "plus", "pour", "qu'il", "qu'elle", "quand", "que", "quel", "quelle", "quels",
        "quelles", "qui", "quoi", "sans", "ses", "son", "sont", "sous", "sur", "ta", "tes", "toi", "ton", "tous",
        "tout", "toute", "toutes", "très", "trop", "une", "vos", "votre", "vous", "était", "avoir", "avait", "aussi",
        "alors", "encore", "bien", "oui", "non", "voilà", "y'a", "d'un", "d'une", "l'on", "s'il",
    ]

    static let allStopWords = englishStopWords.union(frenchStopWords)

    /// The function words of `language` (a locale identifier such as "en-US" or "fr_CA"): English, French, or both
    /// when the language is not given or is another one.
    static func stopWords(for language: String?) -> Set<String> {
        switch language.map(DictationLanguage.languageCode) {
        case "en": englishStopWords
        case "fr": frenchStopWords
        default: allStopWords
        }
    }

    /// A word that carries meaning in `language` (see `stopWords`): not a function word and at least three letters.
    public static func isContent(_ word: String, language: String? = nil) -> Bool {
        let word = word.lowercased().replacingOccurrences(of: "’", with: "'")
        return letters(word).count >= 3 && !stopWords(for: language).contains(word)
    }

    /// Lowercased letters and digits of `text`, without diacritics, apostrophes, hyphens or spaces: "C'est" is
    /// "cest", "ça" is "ca", "on Ubuntu" is "onubuntu".
    public static func letters(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return String(folded.filter { $0.isLetter || $0.isNumber })
    }

    /// Words that change what a sentence says when swapped, by language: negations, counted as one kind ("do not"
    /// and "don't" say the same; the French "ne" is left out, speech drops it), words of quantity or frequency,
    /// and modal verbs ("should", "might"; French ones by verb, "peux" and "peut" being one), each its own kind. A
    /// fix must keep them all ("I do agree" is not "I do not agree", "should" not "could"). Adding or dropping any
    /// word but `glue` is refused apart.
    static let englishNegations: Set<String> = [
        "not", "no", "never", "nothing", "none", "nobody", "nowhere", "neither", "nor", "cannot", "without",
        // Contractions dictated without their apostrophe ("dont"); those with one end in "n't".
        "dont", "cant", "wont", "isnt", "arent", "wasnt", "werent", "doesnt", "didnt", "hasnt", "havent", "hadnt",
        "couldnt", "wouldnt", "shouldnt", "mustnt", "neednt", "aint",
    ]
    static let frenchNegations: Set<String> = ["pas", "jamais", "rien", "personne", "aucun", "aucune", "ni", "sans",
                                               "non", "nul", "nulle", "guère"]
    static let englishQuantities: Set<String> = ["only", "all", "always", "every", "any", "some", "both", "more",
                                                 "less", "most", "least"]
    static let frenchQuantities: Set<String> = ["tout", "tous", "toute", "toutes", "seulement", "toujours", "chaque",
                                                "quelques", "plusieurs", "plus", "moins"]
    static let englishModals: Set<String> = ["can", "could", "should", "would", "will", "shall", "may", "might",
                                             "must", "ought"]
    /// Forms of the French modal verbs, by verb.
    static let frenchModals: [String: String] = [
        "peux": "pouvoir", "peut": "pouvoir", "pouvons": "pouvoir", "pouvez": "pouvoir", "peuvent": "pouvoir",
        "pourrais": "pouvoir", "pourrait": "pouvoir", "pourrions": "pouvoir", "pourriez": "pouvoir",
        "pourraient": "pouvoir", "dois": "devoir", "doit": "devoir", "devons": "devoir", "devez": "devoir",
        "doivent": "devoir", "devrais": "devoir", "devrait": "devoir", "devrions": "devoir", "devriez": "devoir",
        "devraient": "devoir", "faut": "falloir", "faudrait": "falloir",
    ]

    /// How many times each meaning word (see `englishNegations`) is in `words` (from `AIFixGuard.words`), for
    /// `language` (both English and French when nil or another one): negations all count as "not", "I'll" as
    /// "will" and "I'd" as "would", French modals as their verb.
    static func meaningWords(in words: [String], language: String?) -> [String: Int] {
        let code = language.map(DictationLanguage.languageCode)
        let english = code != "fr", french = code != "en"
        var counts: [String: Int] = [:]
        for word in words {
            let kind: String? =
                if (english && (englishNegations.contains(word) || word.hasSuffix("n't")))
                    || (french && frenchNegations.contains(word)) { "not" }
                else if english && word.hasSuffix("'ll") { "will" }
                else if english && word.hasSuffix("'d") { "would" }
                else if (english && (englishQuantities.contains(word) || englishModals.contains(word)))
                    || (french && frenchQuantities.contains(word)) { word }
                else if french { frenchModals[word] }
                else { nil }
            if let kind { counts[kind, default: 0] += 1 }
        }
        return counts
    }

    /// Words a fix may add or drop, by language: articles and the prepositions and conjunctions that tie words
    /// together ("to the store", "je ne sais pas"). Any other word, a pronoun, an auxiliary, a modal or a negation,
    /// says something: "You should go" is not "You go".
    static let englishGlue: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from",
                                          "by", "as", "and", "that"]
    static let frenchGlue: Set<String> = ["le", "la", "les", "un", "une", "des", "du", "de", "à", "au", "aux", "en",
                                         "et", "que", "ne"]

    static func isGlue(_ word: String, language: String?) -> Bool {
        switch language.map(DictationLanguage.languageCode) {
        case "en": englishGlue.contains(word)
        case "fr": frenchGlue.contains(word)
        default: englishGlue.contains(word) || frenchGlue.contains(word)
        }
    }

    /// Hesitations a fix may drop.
    static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm", "euh", "heu"]

    /// Whether `heard` could be a mishearing of `meant` (or the reverse), for the guard on a model's reply. Compared
    /// as `letters`: the same letters; homophones of `language` the rules miss (`homophones`: "one" and "won", "you"
    /// and "ewe"); at most one letter apart or 70 % of the letters the same (by edit distance); the same `sound`
    /// ("write" and "right", "ate" and "eight", "knight" and "night", "their" and "there"); or the same `roughSound`
    /// with at least half the letters the same ("cold" and "called", "a bundo" and "ubuntu"). "windows" and "Ubuntu"
    /// are none of these, nor "opened" and "Ubuntu", nor "point" and "Bundo".
    public static func isClose(_ heard: String, _ meant: String, language: String? = nil) -> Bool {
        let a = letters(heard), b = letters(meant)
        if a == b || areHomophones(spelling(heard), spelling(meant), language: language) { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let distance = editDistance(Array(a), Array(b))
        let longer = max(a.count, b.count)
        if distance <= 1 || Double(distance) <= 0.3 * Double(longer) { return true }
        let soundA = sound(a), soundB = sound(b)
        if soundA == soundB { return true }
        return 2 * distance <= longer && roughSound(soundA) == roughSound(soundB)
    }

    /// `isClose` for a word split in two or two joined into one ("Onobunto" and "on Ubuntu", "semi colon" and
    /// "semicolon"), each side given as its words run together. The letters may differ only as much as the shorter
    /// side allows, so a long word close to its fix does not carry an extra word: "internationalisation" is not
    /// "internationalization Ubuntu".
    static func isCloseSplit(_ heard: String, _ meant: String) -> Bool {
        let a = letters(heard), b = letters(meant)
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let distance = editDistance(Array(a), Array(b))
        let shorter = min(a.count, b.count)
        if distance <= 1 || Double(distance) <= 0.3 * Double(shorter) { return true }
        let soundA = sound(a), soundB = sound(b)
        if soundA == soundB { return true }
        return 2 * distance <= shorter && roughSound(soundA) == roughSound(soundB)
    }

    /// Whether `word`, in a text, could be `heard`, a word of a taught heard phrase, misheard again a little
    /// differently ("bundu" for "Bundo", "Timox" for "Timok's", "mix" for "Max"). Stricter than `isClose`: a match
    /// lets the taught spelling replace the word. The same letters, homophones, or the plural of a word of four
    /// letters or more ("sessions" and "session"); otherwise the same `sound`, so only the spelling of its vowels or
    /// of one sound differs, and at least half the letters the same. "point" is not "Bundo", "band" not "Bundo",
    /// "tax" not "Max", "bulk" not "bull", "buy" not "bus". Homophones are those of `language`.
    public static func isVariant(_ word: String, of heard: String, language: String? = nil) -> Bool {
        isVariant(Features(word), of: Features(heard), language: language)
    }

    static func isVariant(_ word: Features, of heard: Features, language: String?) -> Bool {
        if word.letters == heard.letters || areHomophones(word.spelling, heard.spelling, language: language) {
            return true
        }
        guard !word.letters.isEmpty, !heard.letters.isEmpty else { return false }
        if isPlural(word.letters, of: heard.letters) || isPlural(heard.letters, of: word.letters) { return true }
        guard word.sound == heard.sound else { return false }
        let longer = max(word.characters.count, heard.characters.count)
        return editDistance(word.characters, heard.characters) <= max(1, longer / 2)
    }

    /// Whether `plural` is `stem` with an "s", `stem` having four letters or more: "bulls" of "bull", not "news" of
    /// "new" nor "bus" of "bu".
    static func isPlural(_ plural: String, of stem: String) -> Bool {
        stem.count >= 4 && plural.count == stem.count + 1 && plural.hasPrefix(stem) && plural.hasSuffix("s")
    }

    /// What `isVariant` compares of a word, worked out once for a word met many times.
    struct Features: Sendable {
        /// `SpokenWords.letters` of the word.
        let letters: String
        let characters: [Character]
        /// `SpokenWords.spelling` of the word, for its homophones.
        let spelling: String
        /// Its `sound`: "bundu" and "Bundo" are "banda", "Timox" and "Timok's" "tamaks", "bulk" "balk" but "bull"
        /// "bal".
        let sound: String

        init(_ word: String) {
            letters = SpokenWords.letters(word)
            characters = Array(letters)
            spelling = SpokenWords.spelling(word)
            sound = SpokenWords.sound(letters)
        }
    }

    /// `letters`, keeping apostrophes (made plain): "I'll" is "i'll", not the "ill" of "I feel ill".
    static func spelling(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return String(folded.filter { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" })
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Homophones whose spellings `sound` does not bring together, as `spelling`, by language: in English a vowel
    /// said with a glide the spelling does not show ("one" and "won", "you" and "ewe") or a silent "h" before a vowel
    /// ("our" and "hour"); in French, words whose silent endings differ ("vert" and "verre", "sans" and "cent"),
    /// which English says apart ("sang" and "sent").
    static let englishHomophones: [Set<String>] = [
        ["one", "won"], ["two", "to", "too"], ["you", "ewe", "yew", "u"], ["eight", "ate"], ["our", "hour"],
        ["air", "heir"], ["wood", "would"], ["i'll", "isle", "aisle"],
    ]

    static let frenchHomophones: [Set<String>] = [
        ["sans", "cent", "sang", "sent", "s'en"], ["vers", "vert", "verre", "ver"], ["foi", "fois", "foie"],
        ["cour", "cours", "court"], ["temps", "tant", "tend", "tends"], ["vin", "vingt", "vain"],
        ["eau", "haut", "au", "aux", "o"], ["sept", "set", "cet", "cette"], ["pain", "pin", "peint"],
        ["point", "poing"], ["cou", "coup", "cout"], ["sot", "seau", "saut", "sceau"], ["mot", "maux"],
        ["pere", "paire", "pair", "perd"],
    ]

    /// Whether `a` and `b` (as `spelling`) are listed homophones of `language`: English, French, or either when the
    /// language is not given or is another one.
    static func areHomophones(_ a: String, _ b: String, language: String?) -> Bool {
        let sets: [Set<String>] = switch language.map(DictationLanguage.languageCode) {
        case "en": englishHomophones
        case "fr": frenchHomophones
        default: englishHomophones + frenchHomophones
        }
        return sets.contains { $0.contains(a) && $0.contains(b) }
    }

    /// Words that start with a silent "ough": "gh" after "ou" is an "f" elsewhere ("tough", "rough", "cough").
    static let silentGh = ["though", "although", "through", "thorough", "borough", "dough", "bough", "plough",
                           "furlough"]

    /// Words that start with a "gh" said "f" even before a "t": "laughter", "draught".
    static let fBeforeT = ["laugh", "draught"]

    /// Whether the first "w" of `letters` is silent: "who", "whose", "whom", "whoever", "whole", "whore"; not
    /// "whoop", "whoosh" or "whopping", nor "which".
    static func hasSilentW(_ letters: String) -> Bool {
        letters == "who" || ["whos", "whom", "whoev", "whol", "whor"].contains { letters.hasPrefix($0) }
    }

    /// A rough pronunciation of `letters` (from `letters(_:)`). Silent letters are dropped: a first "k", "g", "p"
    /// or "m" before "n", "w" before "r", "p" before "s" or "t", the "w" of a first "wh" in `hasSilentW` words
    /// ("who", "whole") and its "h" elsewhere ("which", "whoop"), "gh" after the first letter ("night", "eight") but
    /// for the "f" of "tough" and "laugh", a last "e" after a consonant, a "w" or "h" not before a vowel.
    /// Spellings of one sound become one: "ph" f, "ck" and "q" k, "c" before e, i or y s, "dg" before e, i or y j
    /// (any other "g" is hard: "git", "get"), "th" θ, "sh" X, "ch" and "tch" C ("chr", "chl" and "sch" k), "x" ks,
    /// "z" s, a last "mb" m. Each run of vowels (with a "y", "w" or "h" after them) is one "a", and a sound repeated
    /// is kept once. Consonants keep their identity: "point" is "pant", "Bundo" "banda", "child" "Cald" and "should"
    /// "Xald".
    static func sound(_ letters: String) -> String {
        var s = Array(letters)
        if s.count > 2 {
            switch String(s[0...1]) {
            case "kn", "gn", "pn", "mn", "wr", "ps", "pt": s.removeFirst()
            case "wh": s.remove(at: hasSilentW(letters) ? 0 : 1)
            default: break
            }
        }
        if s.count > 2, s.last == "e", !isVowel(s[s.count - 2]) { s.removeLast() }
        func vowel(at index: Int) -> Bool {
            guard index < s.count else { return false }
            return isVowel(s[index]) || (s[index] == "y" && !(index + 1 < s.count && isVowel(s[index + 1])))
        }
        func at(_ index: Int) -> Character? { index < s.count ? s[index] : nil }
        // "gh" after "ou" or "au" is an "f" ("tough", "laugh", "coughs"), but for "ought" and "aught" ("caught",
        // "thought", "slaughter") and the words where it is silent ("though", "through", "dough"). "laugh" and
        // "draught" keep their "f" before a "t" ("laughter").
        func saidF(ghAt index: Int) -> Bool {
            guard index >= 2, s[index - 1] == "u", "oa".contains(s[index - 2]) else { return false }
            if fBeforeT.contains(where: { letters.hasPrefix($0) }) { return true }
            return at(index + 2) != "t" && !silentGh.contains { letters.hasPrefix($0) }
        }
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
                if next == "h" {
                    // A "k" in "chr", "chl" and "sch" ("chrome", "school"); elsewhere the "ch" of "child", apart
                    // from the "sh" of "should".
                    let hard = afterNext.map { "rl".contains($0) } == true || (i > 0 && s[i - 1] == "s")
                    emit(hard ? "k" : "C")
                    step = 2
                }
                else if let next, "eiy".contains(next) { emit("s") }
                else { emit("k"); if next == "k" { step = 2 } }
            case "s": if next == "h" { emit("X"); step = 2 } else { emit("s") }
            case "t":
                if next == "h" { emit("θ"); step = 2 }
                else if !(next == "c" && afterNext == "h") { emit("t") }
            case "p": if next == "h" { emit("f"); step = 2 } else { emit("p") }
            case "g":
                if next == "h" {
                    if i == 0 { emit("g") }
                    else if saidF(ghAt: i) { emit("f") }
                    step = 2
                }
                // Soft only after "d" ("nudger", "budget"): a soft "g" elsewhere cannot be told from a hard one
                // by spelling ("gin" and "git", "danger" and "anger"), and a hard "g" as "j" made "git" "jet".
                else if i > 0, s[i - 1] == "d", let next, "eiy".contains(next) { emit("j") }
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

    /// `sound` with voiced and voiceless consonants made one (b p, d t, g k, v f, j C) and the vowels dropped, but
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
            case "j": "C"
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
