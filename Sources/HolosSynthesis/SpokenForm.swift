import Foundation

/// Rewrites written technical text into what a natural voice should say, before the voice and its check see it
/// (docs/design.md "Spoken form"). Two stages: this type's own rules for what a general normalizer reads badly (paths,
/// web addresses, ranges, arrows, ports, versions, units it does not know, identifiers, some symbols and
/// abbreviations), then `SpokenFormNormalizer` (NVIDIA NeMo's rule-based normalizer, through FluidAudio, in the tool)
/// for numbers, dates, times, money, and common units.
///
/// Contract: only English and French are rewritten (the natural voices' languages); other text is returned as is.
/// Words are kept as written; only the patterns below change. The rules run in the order listed, each over the
/// previous one's output.
public enum SpokenForm {
    /// The words the rules put in, per language.
    struct Words {
        let to, then, toAndFrom, from, port, section, slash, point, about, and, plusOrMinus, by, number: String
        let abbreviations: [(written: String, spoken: String)]
        /// Units after a number: the written forms (case-sensitive), longest first, and what is said.
        let units: [(written: String, spoken: String)]
    }

    static let english = Words(
        to: "to", then: "then", toAndFrom: "to and from", from: "from", port: "port", section: "section",
        slash: "slash", point: "point", about: "about", and: "and", plusOrMinus: "plus or minus", by: "by",
        number: "number",
        abbreviations: [("e.g.", "for example"), ("i.e.", "that is"), ("etc.", "et cetera"), ("vs.", "versus"),
                        ("TL;DR", "T L D R"), ("and/or", "and or"), ("24/7", "twenty-four seven"),
                        ("H.264", "H two sixty-four"), ("H.265", "H two sixty-five"), ("H.266", "H two sixty-six"),
                        ("480p", "four eighty p"), ("720p", "seven twenty p"), ("1080p", "ten eighty p"),
                        ("1440p", "fourteen forty p"), ("2160p", "twenty-one sixty p")],
        units: [("Mbit/s", "megabits per second"), ("Mb/s", "megabits per second"), ("Mbps", "megabits per second"),
                ("kbit/s", "kilobits per second"), ("kbps", "kilobits per second"),
                ("Gbit/s", "gigabits per second"), ("Gbps", "gigabits per second"),
                ("MB/s", "megabytes per second"), ("GB/s", "gigabytes per second"),
                ("MP", "megapixel"), ("GB", "gigabytes"), ("MB", "megabytes"), ("KB", "kilobytes"),
                ("kB", "kilobytes"), ("fps", "frames per second"), ("ms", "milliseconds"), ("µs", "microseconds"),
                ("ns", "nanoseconds"), ("km/h", "kilometres per hour"), ("m/s", "metres per second")])

    static let french = Words(
        to: "à", then: "puis", toAndFrom: "dans les deux sens avec", from: "depuis", port: "port",
        section: "section", slash: "slash", point: "point", about: "environ", and: "et",
        plusOrMinus: "plus ou moins", by: "par", number: "numéro",
        abbreviations: [("p. ex.", "par exemple"), ("c.-à-d.", "c'est-à-dire"), ("etc.", "et cetera")],
        units: [("Mbit/s", "mégabits par seconde"), ("Mb/s", "mégabits par seconde"), ("Mbps", "mégabits par seconde"),
                ("kbit/s", "kilobits par seconde"), ("Gbit/s", "gigabits par seconde"),
                ("Mo/s", "mégaoctets par seconde"), ("MB/s", "mégaoctets par seconde"),
                ("MP", "mégapixels"), ("Go", "gigaoctets"), ("GB", "gigaoctets"), ("Mo", "mégaoctets"),
                ("MB", "mégaoctets"), ("Ko", "kilooctets"), ("To", "téraoctets"), ("TB", "téraoctets"),
                ("fps", "images par seconde"), ("ms", "millisecondes"), ("µs", "microsecondes"),
                ("km/h", "kilomètres à l'heure"), ("m/s", "mètres par seconde")])

    static func words(language: String) -> Words? {
        switch language.lowercased().prefix(2) {
        case "en": english
        case "fr": french
        default: nil
        }
    }

    /// `text` as the voice should say it: this type's rules, then `normalizer` (nil: the rules only).
    public static func text(_ text: String, language: String, normalizer: (any SpokenFormNormalizer)?) -> String {
        guard let words = words(language: language) else { return text }
        let rewritten = rules(text, words: words)
        return normalizer?.normalize(rewritten, language: language) ?? rewritten
    }

    /// This type's own rules, in order.
    static func rules(_ text: String, words: Words) -> String {
        var text = text
        for (written, spoken) in words.abbreviations {
            let abbreviation = try! NSRegularExpression(
                pattern: #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: written)
                    + (written.last.map { $0.isLetter || $0.isNumber } == true ? #"(?![\p{L}\p{N}])"# : ""))
            text = replace(abbreviation, in: text) { _ in spoken }
        }
        text = replace(webAddress, in: text) { $0[1].isEmpty ? $0[2] : $0[1] }
        text = replace(path, in: text) { pathName($0[1]) }
        text = replace(identifier, in: text) { $0[0].replacingOccurrences(of: "_", with: " ") }
        for (written, spoken) in words.units {
            let unit = try! NSRegularExpression(
                pattern: #"(?<=\p{Nd})\s?"# + NSRegularExpression.escapedPattern(for: written) + #"(?![\p{L}\p{N}])"#)
            text = replace(unit, in: text) { _ in " " + spoken }
        }
        text = replace(range, in: text) { "\($0[1]) \(words.to) \($0[2])" }
        text = arrows(text, words: words)
        text = replace(namedPort, in: text) { "\($0[1]) \(words.port) \($0[2])" }
        text = replace(barePort, in: text) { "\($0[1])\(words.port) \($0[2])" }
        text = replace(version, in: text) { $0[1...].filter { !$0.isEmpty }.joined(separator: " \(words.point) ") }
        // Numbers on both sides (`1/2`, `24/7`) are left for the normalizer.
        text = replace(slashed, in: text) { groups in
            groups[1].allSatisfy(\.isNumber) && groups[2].allSatisfy(\.isNumber) ? groups[0]
                : "\(groups[1]) \(words.slash) \(groups[2])"
        }
        text = replace(sectionSign, in: text) { _ in words.section + " " }
        text = replace(approximately, in: text) { _ in words.about + " " }
        text = replace(numberSign, in: text) { _ in words.number + " " }
        text = replace(ampersand, in: text) { _ in " \(words.and) " }
        text = replace(plusMinus, in: text) { _ in " \(words.plusOrMinus) " }
        text = replace(times, in: text) { "\($0[1]) \(words.by) \($0[2])" }
        return text
    }

    // MARK: - Patterns

    /// A web address with a scheme, or a host of three or more labels followed by a path: said as its host. Neither
    /// this nor `path` ends on sentence punctuation, which stays after the words said.
    private static let webAddress = try! NSRegularExpression(
        pattern: #"(?:[a-z][a-z0-9+.-]*://)((?:[\p{L}\p{N}-]+\.)+[\p{L}]{2,})(?::\d+)?(?:/[^\s)\]]*)?(?<![.,;:!?])|(?<![\p{L}\p{N}/.])((?:[\p{L}\p{N}-]+\.){2,}[\p{L}]{2,})/[^\s)\]]*(?<![.,;:!?])"#,
        options: [.caseInsensitive])
    /// A file path: one starting with `~/`, `./`, `../` or `/`, or with two or more slashes. Said as its last part.
    private static let path = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])((?:~|\.{1,2})?/[^\s/]+(?:/[^\s/]+)*/?|[^\s/()]+(?:/[^\s/()]+){2,}/?)(?<![.,;:!?])"#)
    /// A word joined by underscores (`snake_case`, `RELEASE_NOTES`): read as separate words.
    private static let identifier = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])[\p{L}\p{N}]+(?:_[\p{L}\p{N}]+)+"#)
    /// Two numbers joined by an en or em dash: a range.
    private static let range = try! NSRegularExpression(pattern: #"(\p{Nd}[\p{Nd}.,]*)\s?[–—]\s?(\p{Nd})"#)
    /// A port after a host name (`localhost:8090`).
    private static let namedPort = try! NSRegularExpression(pattern: #"(\p{L}):(\p{Nd}{2,5})(?!\p{N})"#)
    /// A port on its own (`:8090`, after a space, a bracket, or at the start).
    private static let barePort = try! NSRegularExpression(pattern: #"(^|[\s(\[])[:](\p{Nd}{2,5})(?!\p{N})"#)
    /// A version of three or four numbers (`1.2.3`, `v2.0.1`); parts after the first have at most three digits, so a
    /// date (`27.10.2026`) is left for the normalizer.
    private static let version = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}.])v?(\p{Nd}+)\.(\p{Nd}{1,3})\.(\p{Nd}{1,3})(?:\.(\p{Nd}{1,3}))?(?![\p{N}.]\p{N})(?!\p{N})"#)
    /// Two words joined by a slash (`dev/ops`, `A/B`); units were taken before.
    private static let slashed = try! NSRegularExpression(pattern: #"([\p{L}\p{N}][\p{L}\p{N}-]*)/([\p{L}\p{N}])"#)
    private static let sectionSign = try! NSRegularExpression(pattern: #"§\s?"#)
    /// A tilde or ≈ before a number: about.
    private static let approximately = try! NSRegularExpression(pattern: #"(?:~|≈)\s?(?=\p{Nd})"#)
    /// `#` before a number.
    private static let numberSign = try! NSRegularExpression(pattern: #"#(?=\p{Nd})"#)
    private static let ampersand = try! NSRegularExpression(pattern: #"\s*&\s*"#)
    private static let plusMinus = try! NSRegularExpression(pattern: #"\s*±\s*"#)
    /// A multiplication sign between numbers (`1920×1080`).
    private static let times = try! NSRegularExpression(pattern: #"(\p{Nd})\s?×\s?(\p{Nd})"#)
    /// One arrow, with the spaces around it.
    private static let arrow = try! NSRegularExpression(pattern: #"\s*(→|⇒|⟶|⇄|↔|⟷|←)\s*"#)

    /// Arrows: `⇄`/`↔` "to and from", `←` "from"; `→` "to", or "then" in a block with two or more of them
    /// (a sequence of steps, `SEARCH → SLEW → LOCK`).
    private static func arrows(_ text: String, words: Words) -> String {
        let forward = text.filter { "→⇒⟶".contains($0) }.count
        return replace(arrow, in: text) { groups in
            switch groups[1] {
            case "⇄", "↔", "⟷": " \(words.toAndFrom) "
            case "←": " \(words.from) "
            default: " \(forward >= 2 ? words.then : words.to) "
            }
        }
    }

    /// A path's last part, its extension and a trailing slash dropped, separators as spaces.
    private static func pathName(_ path: String) -> String {
        let last = path.split(separator: "/").last.map(String.init) ?? path
        let stem = last.range(of: #"\.[A-Za-z][A-Za-z0-9]{0,4}$"#, options: .regularExpression)
            .map { String(last[..<$0.lowerBound]) } ?? last
        return stem.replacingOccurrences(of: "_", with: " ")
    }

    /// `text` with every match of `pattern` replaced by `spoken(groups)` (group 0 the whole match; a group that did not
    /// take part is empty).
    private static func replace(_ pattern: NSRegularExpression, in text: String,
                                with spoken: ([String]) -> String) -> String {
        var result = ""
        var rest = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            result += text[rest..<whole.lowerBound] + spoken(groups)
            rest = whole.upperBound
        }
        return result + text[rest...]
    }
}

/// The second stage of `SpokenForm`: numbers, dates, times, money and common units written out (NeMo's normalizer in
/// the tool, `NemoSpokenForm` in HolosPocket). Returns its input for a language it does not handle.
public protocol SpokenFormNormalizer: Sendable {
    func normalize(_ text: String, language: String) -> String
}
