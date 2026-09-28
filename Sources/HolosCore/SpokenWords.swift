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
        "couldnt", "wouldnt", "shouldnt", "mustnt", "neednt", "aint", "shant", "mightnt",
    ]
    static let frenchNegations: Set<String> = ["pas", "jamais", "rien", "personne", "aucun", "aucune", "ni", "sans",
                                               "non", "nul", "nulle", "guère"]
    /// Words of quantity, frequency and degree of completion: how many, how often, how nearly ("few" is not "new",
    /// "rarely" not "barely").
    static let englishQuantities: Set<String> = [
        "only", "just", "all", "every", "each", "any", "some", "both", "either", "more", "less", "most", "least",
        "few", "fewer", "fewest", "many", "much", "several", "enough", "lots", "plenty", "half", "whole", "entire",
        "everyone", "everybody", "everything", "anyone", "anybody", "anything", "someone", "somebody", "something",
        "always", "often", "usually", "sometimes", "occasionally", "frequently", "rarely", "seldom", "once", "twice",
        "again", "ever", "almost", "nearly", "barely", "hardly", "scarcely", "mostly", "partly", "fully", "completely",
        "entirely", "totally", "too", "also", "even", "still", "already", "yet",
    ]
    static let frenchQuantities: Set<String> = [
        "tout", "tous", "toute", "toutes", "seulement", "chaque", "quelques", "quelque", "plusieurs", "plus",
        "moins", "peu", "beaucoup", "trop", "assez", "certains", "certaines", "davantage", "moitié", "entier",
        "entière", "toujours", "souvent", "parfois", "rarement", "quelquefois", "presque", "encore", "déjà",
        "aussi", "même", "tellement", "autant",
    ]
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
    /// `language` (both English and French when nil or another one), by `meaningKinds`.
    static func meaningWords(in words: [String], language: String?) -> [String: Int] {
        var counts: [String: Int] = [:]
        for word in words {
            for kind in meaningKinds(of: word, language: language) { counts[kind, default: 0] += 1 }
        }
        return counts
    }

    /// English auxiliaries, each its own kind: their tense and person are what they say ("I do agree" is not "I did
    /// agree", "were" not "are").
    static let englishAuxiliaries: Set<String> = ["do", "does", "did", "is", "am", "are", "was", "were", "be", "been",
                                                  "has", "have", "had"]

    /// Abbreviated units, each its own kind: "5 km" is not "5 cm", "10 ms" not "10 mm".
    static let units: Set<String> = [
        "mm", "cm", "km", "kg", "mg", "ml", "lb", "lbs", "oz", "ft", "mi", "mph", "kph", "kmh", "kb", "mb", "gb", "tb",
        "kbps", "mbps", "gbps", "ms", "ns", "sec", "secs", "min", "mins", "hr", "hrs", "hz", "khz", "mhz", "ghz", "kw",
        "kwh", "mw", "mah", "px", "pm",
    ]

    /// The negation, modal, auxiliary and word of quantity `word` says (see `englishNegations`): negations all are
    /// "not", "I'll" is "will" and "I'd" "would", French modals are their verb. A negative contraction is both:
    /// "couldn't" is "not" and "could", so it is not "wouldn't", and "don't" is "not" and "do", so not "didn't".
    static func meaningKinds(of word: String, language: String?) -> [String] {
        let code = language.map(DictationLanguage.languageCode)
        let english = code != "fr", french = code != "en"
        if english, let auxiliary = negativeAuxiliary(word) { return ["not", auxiliary] }
        if (english && englishNegations.contains(word)) || (french && frenchNegations.contains(word)) {
            return ["not"]
        }
        if english && word.hasSuffix("'ll") { return ["will"] }
        if english && word.hasSuffix("'d") { return ["would"] }
        if (english && (englishQuantities.contains(word) || englishModals.contains(word)
                        || englishAuxiliaries.contains(word)))
            || (french && frenchQuantities.contains(word)) || units.contains(word) { return [word] }
        if french, let verb = frenchModals[word] { return [verb] }
        return []
    }

    /// The person each pronoun, possessive and pronoun contraction names, by language: "he", "him", "his" and "he's"
    /// are one person, "she" another. French words are looked up by the parts between their apostrophes ("j'ai" is
    /// "j"); "on", "se" and the pronouns that are also articles ("le", "la", "les") are left out.
    static let englishPersons: [String: String] = persons([
        "I": ["i", "me", "my", "mine", "myself", "i'm", "i'll", "i'd", "i've"],
        "we": ["we", "us", "our", "ours", "ourselves", "we're", "we'll", "we'd", "we've"],
        "you": ["you", "your", "yours", "yourself", "yourselves", "you're", "you'll", "you'd", "you've"],
        "he": ["he", "him", "his", "himself", "he's", "he'll", "he'd"],
        "she": ["she", "her", "hers", "herself", "she's", "she'll", "she'd"],
        "it": ["it", "its", "itself", "it's", "it'll", "it'd"],
        "they": ["they", "them", "their", "theirs", "themselves", "they're", "they'll", "they'd", "they've"],
    ])
    static let frenchPersons: [String: String] = persons([
        "je": ["je", "j", "me", "m", "moi", "mon", "ma", "mes", "mien", "mienne", "miens", "miennes"],
        "tu": ["tu", "t", "te", "toi", "ton", "ta", "tes", "tien", "tienne", "tiens", "tiennes"],
        "il": ["il"], "ils": ["ils"], "elle": ["elle"], "elles": ["elles"],
        "lui": ["lui", "son", "sa", "ses", "sien", "sienne", "siens", "siennes"],
        "nous": ["nous", "notre", "nos", "nôtre", "nôtres"], "vous": ["vous", "votre", "vos", "vôtre", "vôtres"],
        "eux": ["eux", "leur", "leurs"],
    ])

    /// The person a French word names (`frenchPersons`): the word itself, an elided pronoun before its apostrophe
    /// ("j'ai", "m'envoyer", "t'as"), or a whole pronoun after it ("qu'il", "lorsqu'elle"). The single letter after
    /// an English contraction's apostrophe is not a pronoun: "don't" is not "t".
    static func frenchPerson(_ word: String) -> String? {
        if let person = frenchPersons[word] { return person }
        let parts = word.split(separator: "'", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if ["j", "m", "t"].contains(parts[0]), let person = frenchPersons[String(parts[0])] { return person }
        return parts[1].count > 1 ? frenchPersons[String(parts[1])] : nil
    }

    private static func persons(_ byPerson: [String: [String]]) -> [String: String] {
        var result: [String: String] = [:]
        for (person, words) in byPerson { for word in words { result[word] = person } }
        return result
    }

    /// Number words by language, as `letters`, with their value in digits. "un" and "une" are left out: they are
    /// articles far more often.
    static let englishNumbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7",
        "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14",
        "fifteen": "15", "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
        "thirty": "30", "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "million": "1000000", "billion": "1000000000",
    ]
    static let frenchNumbers: [String: String] = [
        "zero": "0", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5", "six": "6", "sept": "7", "huit": "8",
        "neuf": "9", "dix": "10", "onze": "11", "douze": "12", "treize": "13", "quatorze": "14", "quinze": "15",
        "seize": "16", "vingt": "20", "vingts": "20", "trente": "30", "quarante": "40", "cinquante": "50",
        "soixante": "60", "cent": "100", "cents": "100", "mille": "1000", "million": "1000000",
        "milliard": "1000000000",
        // Belgian and Swiss French.
        "septante": "70", "huitante": "80", "octante": "80", "nonante": "90",
    ]

    /// What a word says that a fix must keep where it is (`AIFixGuard.plausible`). `strict`: its negation, modal
    /// and word of quantity (`meaningKinds`). `person`: the person a pronoun names (`englishPersons`). `number`: the
    /// value of a number, the word itself when it has a digit ("10", "3pm"), in digits for a number word ("ten").
    struct Meaning: Equatable {
        var strict: [String] = []
        var person: String?
        var number: String?

        var isEmpty: Bool { strict.isEmpty && person == nil && number == nil }
        /// Everything it says, sorted: what the words a split or join replaces must say together.
        var all: [String] {
            (strict + [person.map { "person " + $0 }, number.map { "number " + $0 }].compactMap(\.self)).sorted()
        }
    }

    static func meaning(of word: String, language: String?) -> Meaning {
        let code = language.map(DictationLanguage.languageCode)
        let english = code != "fr", french = code != "en"
        var meaning = Meaning(strict: meaningKinds(of: word, language: language))
        if english { meaning.person = englishPersons[word] }
        if french, meaning.person == nil { meaning.person = frenchPerson(word) }
        if word.contains(where: \.isNumber) {
            meaning.number = word
        } else {
            let letters = letters(word)
            meaning.number = (english ? englishNumbers[letters] : nil) ?? (french ? frenchNumbers[letters] : nil)
        }
        return meaning
    }

    /// Whether a fix may put `new` where `word` was, one word for one (`AIFixGuard.plausible`). `isWord`: `word` is
    /// a real word of the dictation language (`Lexicon`). The same letters with an apostrophe put back or taken out,
    /// or another case, pass when they keep any negation, modal and quantity: "Jai" and "J'ai", "were" and "we're";
    /// not "well" and "we'll". A negation, modal or word of quantity may only be spelled another way (`isClose`) as
    /// the same one ("can't" and "cannot", "peut" and "peux"), never another ("not" and "never", "could" and
    /// "would"). A number may be written with the same value ("ten" and "10"). Otherwise a real word may only become
    /// a listed homophone (`areHomophones`: "their" and "there", "won" and "one", "right" and "write"): "bat" is not
    /// "bit", "want" not "wanted", "tooth" not "teeth", "left" not "lift", "form" not "from", however alike they
    /// sound. A word the language does not know ("bundu") may become a close one (`isClose`) that keeps what it
    /// says: a pronoun or number keeps its person or value ("he" is not "she", "10" not "100").
    static func mayReplace(_ word: String, with new: String, language: String?, isWord: Bool) -> Bool {
        let was = meaning(of: word, language: language), now = meaning(of: new, language: language)
        if was.strict == now.strict && letters(word) == letters(new) { return true }
        if !was.strict.isEmpty || !now.strict.isEmpty { return was == now && isClose(word, new, language: language) }
        if was.number != nil && was == now { return true }
        if areHomophones(spelling(word), spelling(new), language: language) { return true }
        return !isWord && was == now && isClose(word, new, language: language)
    }

    /// Whether `word` may be part of a number said in several words (`numberValue`): digits, a number word, or the
    /// "and", "et", "un" and "une" said inside one ("one hundred and five", "vingt et un").
    static func mayBeInNumber(_ word: String, language: String?) -> Bool {
        if word.allSatisfy(\.isNumber) { return true }
        return numberWord(word, language: language) != nil || ["and", "et", "un", "une"].contains(word)
    }

    /// The value of a number word of `language` ("twenty", "vingt"), nil for any other word.
    static func numberWord(_ word: String, language: String?) -> Int? {
        let code = language.map(DictationLanguage.languageCode)
        let letters = letters(word)
        let value = (code != "fr" ? englishNumbers[letters] : nil) ?? (code != "en" ? frenchNumbers[letters] : nil)
        return value.flatMap { Int($0) }
    }

    /// The value of a number said in `words`: one word of digits ("21"), or number words said as one number
    /// ("twenty one", "one hundred and five", "two thousand twenty six", "quatre vingt dix", "vingt et un"). Nil for
    /// anything else, including numbers said one after another ("one two", "ten twenty"), which are not one, and
    /// digits with a leading zero ("021", a code whose zero counts).
    static func numberValue(_ words: [String], language: String?) -> Int? {
        if words.count == 1, words[0].allSatisfy(\.isNumber) {
            return words[0].count > 1 && words[0].hasPrefix("0") ? nil : Int(words[0])
        }
        enum Last { case none, unit, teen, tens, hundred }
        var total = 0, group = 0, last = Last.none, counted = 0
        for (index, word) in words.enumerated() {
            let isLast = index == words.count - 1
            // "one hundred and five", "vingt et un": a joining word only inside the number.
            if word == "and", last == .hundred, !isLast { continue }
            if word == "et", last == .tens, !isLast { continue }
            var found = numberWord(word, language: language)
            if found == nil, word == "un" || word == "une", index > 0 { found = 1 }
            guard let value = found else { return nil }
            counted += 1
            switch value {
            case 0:
                guard words.count == 1 else { return nil }
            case 1...9:
                // French "dix-sept" to "dix-neuf", "soixante-dix-huit", "quatre-vingt-dix-huit": 17 to 19 said as
                // ten and a unit.
                let frenchTeen = last == .teen && group % 100 % 20 == 10 && value >= 7 && words[index - 1] == "dix"
                guard last == .none || last == .tens || last == .hundred || frenchTeen else { return nil }
                group += value
                last = .unit
            case 10...19:
                // French "soixante dix", "quatre vingt dix": 70 and 90.
                let frenchTens = last == .tens && [60, 80].contains(group % 100)
                guard last == .none || last == .hundred || frenchTens else { return nil }
                group += value
                last = .teen
            case 20...90:
                if value == 20, last == .unit, group % 100 == 4 {
                    group += 76  // "quatre vingt": 80
                } else {
                    guard last == .none || last == .hundred else { return nil }
                    group += value
                }
                last = .tens
            case 100:
                guard group < 10 else { return nil }
                group = max(group, 1) * 100
                last = .hundred
            default:
                total += max(group, 1) * value
                group = 0
                last = .none
            }
        }
        return counted > 0 ? total + group : nil
    }

    /// `words` with each number said in several words (`numberValue`, the longest from each place) written as one
    /// word in digits: "one hundred and five" is "105".
    static func numbersAsDigits(_ words: [String], language: String?) -> [String] {
        var result: [String] = []
        var index = 0
        while index < words.count {
            let run = words[index...].prefix(8).prefix { mayBeInNumber($0, language: language) }.count
            if let length = stride(from: run, to: 1, by: -1).first(where: {
                numberValue(Array(words[index..<(index + $0)]), language: language) != nil
            }) {
                result.append(String(numberValue(Array(words[index..<(index + length)]), language: language)!))
                index += length
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }

    /// Whether `word` repeated may not be dropped as a stutter: a negation, modal, word of quantity or number said
    /// twice may be meant ("no no", "10 10").
    static func keepsRepeats(_ word: String, language: String?) -> Bool {
        let meaning = meaning(of: word, language: language)
        return !meaning.strict.isEmpty || meaning.number != nil
    }

    /// The modal or auxiliary of a negative contraction, with or without its apostrophe: "can" for "can't", "cant"
    /// and "cannot", "will" for "won't", "could" for "couldn't", "do" for "don't", "did" for "didn't", "was" for
    /// "wasn't". Nil for a word that is not one.
    static func negativeAuxiliary(_ word: String) -> String? {
        if word == "cannot" { return "can" }
        let stem: Substring =
            if word.hasSuffix("n't") { word.dropLast(3) }
            else if word.hasSuffix("nt"), englishNegations.contains(word) { word.dropLast(2) }
            else { "" }
        guard !stem.isEmpty else { return nil }
        return ["ca": "can", "wo": "will", "sha": "shall"][String(stem)] ?? String(stem)
    }

    /// Whether `words`, two words, spell out the English `contraction` with the auxiliary it stands for: "I've" and
    /// "I have", "we're" and "we are", "I'm" and "I am", "it's" and "it is" or "it has", "I'd" and "I would" or "I
    /// had", "don't" and "do not", "won't" and "will not"; never another auxiliary ("I've" is not "I had").
    static func expands(_ contraction: String, to words: [String], language: String?) -> Bool {
        guard words.count == 2, language.map(DictationLanguage.languageCode) != "fr",
              contraction.contains("'") else { return false }
        if let auxiliary = negativeAuxiliary(contraction) { return words == [auxiliary, "not"] }
        let parts = contraction.split(separator: "'", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]) == words[0] else { return false }
        let spelledOut: [String: Set<String>] = ["ve": ["have"], "re": ["are"], "m": ["am"], "s": ["is", "has"],
                                                 "d": ["would", "had"], "ll": ["will", "shall"]]
        return spelledOut[String(parts[1])]?.contains(words[1]) == true
    }

    /// Words a fix may add or drop, by language: articles and the prepositions and conjunctions that tie words
    /// together ("to the store", "je ne sais pas"). Any other word, a pronoun, an auxiliary, a modal or a negation,
    /// says something: "You should go" is not "You go". Words that are also pronouns are left out: "that" ("I know
    /// that"), and the French "le", "la", "les" and "en" ("Je le prends", "J'en veux").
    static let englishGlue: Set<String> = ["a", "an", "the", "to", "of", "in", "on", "at", "for", "with", "from",
                                          "by", "as", "and"]
    static let frenchGlue: Set<String> = ["un", "une", "des", "du", "de", "à", "au", "aux", "et", "que", "ne"]

    static func isGlue(_ word: String, language: String?) -> Bool {
        switch language.map(DictationLanguage.languageCode) {
        case "en": englishGlue.contains(word)
        case "fr": frenchGlue.contains(word)
        default: englishGlue.contains(word) || frenchGlue.contains(word)
        }
    }

    /// Whether `heard` could be a mishearing of `meant` (or the reverse), judged by sound alone. Compared as
    /// `letters`: the same letters; homophones of `language` (`homophones`: "one" and "won", "you" and "ewe"); the
    /// same `sound` ("Najer" and "nudger"); or the same `roughSound` with at least half the letters the same ("a
    /// bundo" and "ubuntu"). "windows" and "Ubuntu" are none of these, nor "opened" and "Ubuntu", nor "point" and
    /// "Bundo". The guard asks it only for a word the dictation language does not know (`mayReplace`): two real
    /// words that sound alike ("bat" and "bit") are two words, not one misheard.
    public static func isClose(_ heard: String, _ meant: String, language: String? = nil) -> Bool {
        let a = letters(heard), b = letters(meant)
        if a == b || areHomophones(spelling(heard), spelling(meant), language: language) { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let soundA = sound(a), soundB = sound(b)
        if soundA == soundB { return true }
        // Spelling alone is no evidence: "increase" and "decrease", "include" and "exclude" are a few letters apart
        // but sound apart.
        let distance = editDistance(Array(a), Array(b))
        return 2 * distance <= max(a.count, b.count) && roughSound(soundA) == roughSound(soundB)
    }

    /// `isClose` for a word split in two or two joined into one ("Onobunto" and "on Ubuntu", "semi colon" and
    /// "semicolon"), each side given as its words run together. The letters may differ only as much as the shorter
    /// side allows, so a long word close to its fix does not carry an extra word: "internationalizaton" is not
    /// "internationalization Ubuntu".
    static func isCloseSplit(_ heard: String, _ meant: String) -> Bool {
        let a = letters(heard), b = letters(meant)
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty else { return false }
        let soundA = sound(a), soundB = sound(b)
        if soundA == soundB { return true }
        let distance = editDistance(Array(a), Array(b))
        return 2 * distance <= min(a.count, b.count) && roughSound(soundA) == roughSound(soundB)
    }

    /// Whether `word`, in a text, could be `heard`, a word of a taught heard phrase, misheard again a little
    /// differently ("bundu" for "Bundo", "Timox" for "Timok's", "Ubundo" for "Ubundu"). Stricter than `isClose`: a
    /// match lets the taught spelling replace the word. The same letters or homophones; otherwise the same `sound`,
    /// so only the spelling of its vowels or of one sound differs, and at least half the letters the same. A plural
    /// is not its singular: a pair taught for "delete file" does not replace "delete files". "point" is not "Bundo",
    /// "band" not "Bundo", "tax" not "Max", "bulk" not "bull", "buy" not "bus". Homophones are those of `language`.
    /// The taught-phrase matcher asks it only for a word the dictation language does not know (`AIFixReference`).
    public static func isVariant(_ word: String, of heard: String, language: String? = nil) -> Bool {
        isVariant(Features(word), of: Features(heard), language: language)
    }

    static func isVariant(_ word: Features, of heard: Features, language: String?) -> Bool {
        if word.letters == heard.letters || areHomophones(word.spelling, heard.spelling, language: language) {
            return true
        }
        guard !word.letters.isEmpty, !heard.letters.isEmpty, word.sound == heard.sound else { return false }
        let longer = max(word.characters.count, heard.characters.count)
        return editDistance(word.characters, heard.characters) <= max(1, longer / 2)
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

    /// Words said alike, as `spelling`, by language: the only real words a fix may swap for one another
    /// (`mayReplace`), since a real word replaced by another that merely sounds close to it ("bat" and "bit", "want"
    /// and "wanted") says something else. English: "their", "there" and "they're", "right" and "write", "one" and
    /// "won", "by" and "buy"; an unstressed "I" is heard as "a". French words whose silent endings differ ("vert" and
    /// "verre", "peut" and "peux"), which English says apart ("sang" and "sent").
    static let englishHomophones: [Set<String>] = [
        // Pronouns, numbers and function words.
        ["one", "won"], ["two", "to", "too"], ["you", "ewe", "yew", "u"], ["eight", "ate"], ["our", "hour"],
        ["wood", "would"], ["i'll", "isle", "aisle"], ["their", "there", "they're"], ["your", "you're", "yore"],
        ["its", "it's"], ["a", "i"], ["i", "eye", "aye"], ["four", "for", "fore"], ["we", "wee"], ["him", "hymn"],
        ["then", "than"], ["whose", "who's"], ["by", "buy", "bye"], ["know", "no"], ["knew", "new", "gnu"],
        ["hear", "here"], ["which", "witch"], ["whether", "weather", "wether"], ["where", "wear", "ware"],
        ["so", "sew", "sow"], ["be", "bee"], ["see", "sea"], ["in", "inn"], ["or", "oar", "ore"], ["oh", "owe"],
        ["hi", "high"], ["way", "weigh", "whey"], ["we've", "weave"], ["theirs", "there's"], ["you'll", "yule"],
        ["what", "watt"], ["threw", "through"], ["whole", "hole"], ["one's", "ones"],
        // Other words.
        ["right", "write", "rite", "wright"], ["knight", "night"], ["meet", "meat", "mete"], ["pair", "pear", "pare"],
        ["air", "heir", "ere"], ["wait", "weight"], ["flour", "flower"], ["aloud", "allowed"], ["scene", "seen"],
        ["rain", "reign", "rein"], ["pseudo", "sudo"], ["sun", "son"], ["break", "brake"], ["peace", "piece"],
        ["plain", "plane"], ["mail", "male"], ["tail", "tale"], ["sail", "sale"], ["road", "rode", "rowed"],
        ["blue", "blew"], ["red", "read"], ["read", "reed"], ["made", "maid"], ["dear", "deer"], ["week", "weak"],
        ["cell", "sell"], ["cent", "scent", "sent"], ["site", "sight", "cite"], ["principal", "principle"],
        ["stationary", "stationery"], ["complement", "compliment"], ["higher", "hire"], ["idle", "idol"],
        ["mind", "mined"], ["missed", "mist"], ["passed", "past"], ["guessed", "guest"], ["rows", "rose"],
        ["steal", "steel"], ["stair", "stare"], ["tide", "tied"], ["toe", "tow"], ["waist", "waste"],
        ["hair", "hare"], ["bare", "bear"], ["fair", "fare"], ["flew", "flu", "flue"], ["grate", "great"],
        ["groan", "grown"], ["heal", "heel"], ["key", "quay"], ["knead", "need"], ["lead", "led"], ["loan", "lone"],
        ["morning", "mourning"], ["pail", "pale"], ["pain", "pane"], ["pause", "paws"], ["pole", "poll"],
        ["pray", "prey"], ["profit", "prophet"], ["role", "roll"], ["root", "route"], ["sole", "soul"],
        ["stake", "steak"], ["suite", "sweet"], ["tea", "tee"], ["throne", "thrown"], ["vain", "vane", "vein"],
        ["wail", "whale"], ["warn", "worn"], ["wine", "whine"], ["yoke", "yolk"], ["base", "bass"], ["beat", "beet"],
        ["berry", "bury"], ["berth", "birth"], ["board", "bored"], ["bread", "bred"], ["ceiling", "sealing"],
        ["cereal", "serial"], ["chews", "choose"], ["coarse", "course"], ["council", "counsel"], ["die", "dye"],
        ["doe", "dough"], ["feat", "feet"], ["find", "fined"], ["fir", "fur"], ["flea", "flee"], ["forth", "fourth"],
        ["foul", "fowl"], ["gait", "gate"], ["hall", "haul"], ["heard", "herd"], ["hoarse", "horse"],
        ["knows", "nose"], ["lessen", "lesson"], ["links", "lynx"], ["maize", "maze"], ["manner", "manor"],
        ["medal", "meddle"], ["naval", "navel"], ["overdo", "overdue"], ["patience", "patients"],
        ["peak", "peek", "pique"], ["pedal", "peddle"], ["presence", "presents"], ["rap", "wrap"], ["real", "reel"],
        ["residence", "residents"], ["ring", "wring"], ["rote", "wrote"], ["seam", "seem"], ["seas", "sees", "seize"],
        ["side", "sighed"], ["soar", "sore"], ["staid", "stayed"], ["tacks", "tax"], ["team", "teem"],
        ["tear", "tier"], ["time", "thyme"], ["vary", "very"], ["waive", "wave"], ["aid", "aide"],
        ["altar", "alter"], ["arc", "ark"], ["bail", "bale"], ["band", "banned"], ["billed", "build"],
        ["bite", "byte", "bight"], ["cache", "cash"], ["sink", "sync"], ["cue", "queue"], ["chord", "cord"],
        ["capital", "capitol"], ["creak", "creek"], ["crews", "cruise"], ["days", "daze"],
        ["discreet", "discrete"], ["dual", "duel"], ["faze", "phase"], ["flair", "flare"], ["hay", "hey"],
        ["hoard", "horde"], ["incite", "insight"], ["main", "mane"], ["mode", "mowed"],
        ["muscle", "mussel"], ["peal", "peel"], ["please", "pleas"], ["pour", "pore"], ["raise", "rays", "raze"],
        ["roe", "row"], ["rung", "wrung"], ["sign", "sine"], ["slow", "sloe"], ["stile", "style"],
        ["storey", "story"], ["straight", "strait"], ["symbol", "cymbal"], ["tire", "tyre"], ["troop", "troupe"],
        ["wet", "whet"], ["while", "wile"], ["wade", "weighed"],
    ]

    static let frenchHomophones: [Set<String>] = [
        ["sans", "cent", "sang", "sent", "s'en"], ["vers", "vert", "verre", "ver"], ["foi", "fois", "foie"],
        ["cour", "cours", "court"], ["temps", "tant", "tend", "tends"], ["vin", "vingt", "vain"],
        ["eau", "haut", "au", "aux", "o"], ["sept", "set", "cet", "cette"], ["pain", "pin", "peint"],
        ["point", "poing"], ["cou", "coup", "cout"], ["sot", "seau", "saut", "sceau"], ["mot", "maux"],
        ["pere", "paire", "pair", "perd"], ["sa", "ca"], ["ces", "ses", "c'est", "s'est", "sais", "sait"],
        ["son", "sont"], ["ma", "m'a"], ["ta", "t'a"], ["mes", "mais", "met", "mets"], ["tes", "t'es"],
        ["leur", "leurs"], ["il", "ils"], ["elle", "elles"], ["mon", "m'ont"], ["ton", "t'ont", "thon"],
        ["dix", "dis", "dit"], ["et", "est"], ["a", "as"], ["on", "ont"], ["ce", "se"], ["ni", "n'y"],
        ["si", "s'y", "ci", "scie"], ["quand", "quant", "qu'en", "camp"], ["la", "l'a"], ["faim", "fin"],
        ["mer", "mere", "maire"], ["voie", "voix", "vois", "voit"], ["peux", "peut"], ["dois", "doit"],
        ["veux", "veut"], ["fais", "fait"], ["crois", "croit"], ["prends", "prend"],
        ["sors", "sort"], ["dors", "dort"], ["pars", "part"], ["vis", "vit"], ["lis", "lit"],
        ["ecris", "ecrit"], ["finis", "finit"], ["conte", "compte", "comte"],
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
