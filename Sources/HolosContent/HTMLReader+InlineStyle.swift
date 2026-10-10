import Foundation

extension HTMLReader {
    /// The declarations of an HTML `style` attribute, read the way a browser cascades them within
    /// the one attribute: per property (names in any case), an `!important` declaration beats a
    /// normal one, and among equals the last wins. Declarations with an empty or invalid value are
    /// dropped, as a browser drops them, so they never override an earlier valid one.
    struct InlineStyle {
        struct Declaration: Equatable {
            var property: String
            var value: String
            var important: Bool
        }

        let declarations: [Declaration]

        init(_ style: String) {
            declarations = Self.split(Self.strippingComments(style)).compactMap(Self.declaration)
        }

        /// The effective value of `property`, as written, among declarations whose value
        /// `isValid` accepts; nil when none sets it.
        func value(of property: String, isValid: (String) -> Bool = { _ in true }) -> String? {
            let property = Self.propertyName(property)
            var winner: Declaration?
            for declaration in declarations where declaration.property == property && isValid(declaration.value) {
                if let current = winner, current.important, !declaration.important { continue }
                winner = declaration
            }
            return winner?.value
        }

        /// A property name as CSS matches it: a custom property's (`--name`) by case, any
        /// other's in any ASCII case.
        static func propertyName(_ name: String) -> String {
            name.hasPrefix("--") ? name : name.lowercased()
        }

        /// Whether `value` uses a custom property (`var(`, in any case). A browser accepts such
        /// a declaration whatever the rest of it says, and gives the property its value once the
        /// variables are substituted (see `substitutingVariables`).
        static func usesVariables(_ value: String) -> Bool {
            value.range(of: "var(", options: .caseInsensitive) != nil
        }

        /// What substituting a value's `var()` references gives.
        enum Substitution: Equatable {
            /// The value with every reference replaced.
            case value(String)
            /// Invalid at computed-value time, as CSS makes it: a reference to a variable in a
            /// cycle, to one set to `initial`, or to one that is itself invalid, with no fallback.
            case invalid
            /// Cannot be told here: a reference to a variable this attribute does not set (an
            /// ancestor or a style sheet may set it), or references nested too deep.
            case unknown
        }

        /// `value` with each `var(--name[, fallback])` replaced by the value this attribute's own
        /// `--name` declaration gives, itself substituted, as CSS substitutes it: a variable that
        /// is invalid (set to `initial`, in a reference cycle, or with an invalid reference of its
        /// own) gives the reference's fallback, and without one makes the whole value invalid.
        /// Every variable in a cycle is invalid, whatever fallbacks its own references have.
        func substitutingVariables(in value: String) -> Substitution {
            substitute(value, resolving: []).outcome
        }

        /// `substitutingVariables` for a value inside the variables of `stack` (outermost first),
        /// with the variables of `stack` that references in it close a cycle through.
        private func substitute(_ value: String, resolving stack: [String]) -> (outcome: Substitution, cycles: Set<String>) {
            guard stack.count < 32 else { return (.unknown, []) }
            let characters = Array(value)
            var result = ""
            var cycles = Set<String>()
            var invalid = false
            var unknown = false
            var index = 0
            while index < characters.count {
                guard index + 4 <= characters.count,
                      String(characters[index..<(index + 4)]).lowercased() == "var(" else {
                    result.append(characters[index])
                    index += 1
                    continue
                }
                // The reference's arguments, to its matching ")", and the first top-level comma.
                // An unclosed reference ends with the value, as CSS closes it.
                var nesting = 1
                var close = index + 4
                var comma: Int?
                while close < characters.count {
                    let character = characters[close]
                    if character == "(" { nesting += 1 }
                    if character == ")" { nesting -= 1; if nesting == 0 { break } }
                    if character == ",", nesting == 1, comma == nil { comma = close }
                    close += 1
                }
                let name = String(characters[(index + 4)..<(comma ?? close)]).trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = comma.map { String(characters[($0 + 1)..<close]) }
                index = close + 1
                guard name.hasPrefix("--") else {
                    invalid = true
                    continue
                }
                // The variable's own value. Every reference is resolved, even once the value is
                // invalid, so each cycle through it is found.
                var variable: Substitution
                if stack.contains(name) {
                    // A reference back to a variable being resolved: every variable from it to
                    // here is in a cycle, and invalid, the one holding this reference included.
                    cycles.insert(name)
                    invalid = true
                    continue
                } else if let own = self.value(of: name) {
                    if own.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "initial" {
                        variable = .invalid
                    } else {
                        let (outcome, inner) = substitute(own, resolving: stack + [name])
                        let through = inner.subtracting([name])
                        if !through.isEmpty {
                            // A cycle through a variable further out holds this one and the value.
                            cycles.formUnion(through)
                            invalid = true
                            continue
                        }
                        variable = inner.contains(name) ? .invalid : outcome
                    }
                } else {
                    variable = .unknown
                }
                if variable == .invalid, let fallback {
                    let (outcome, inner) = substitute(fallback, resolving: stack)
                    cycles.formUnion(inner)
                    variable = inner.isEmpty ? outcome : .invalid
                }
                switch variable {
                case .value(let text): result += " " + text + " "
                case .invalid: invalid = true
                case .unknown: unknown = true
                }
            }
            return (invalid ? .invalid : unknown ? .unknown : .value(result), cycles)
        }

        /// A `display` value a browser accepts, by the property's grammar (CSS Display 3, with
        /// MathML Core's `math`):
        /// `[<display-outside> || <display-inside>] | <display-listitem> | <display-internal> |
        /// <display-box> | <display-legacy>`, or a CSS-wide keyword alone. Keywords of a
        /// multi-keyword value come in any order, each at most once; `none`, `contents`, the
        /// internal and legacy values, and the CSS-wide keywords stand alone. So "block flow"
        /// and "list-item block" are valid, and "none block" and "inline inline" are not.
        static func isDisplayValue(_ value: String) -> Bool {
            let words = value.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard (1...3).contains(words.count), Set(words).count == words.count else { return false }
            if words.count == 1, displaySingles.contains(words[0]) { return true }
            let outside = words.filter(displayOutside.contains)
            let inside = words.filter(displayInside.contains)
            let listItem = words.filter { $0 == "list-item" }
            guard outside.count + inside.count + listItem.count == words.count, outside.count <= 1 else { return false }
            if listItem.isEmpty {
                // <display-outside> || <display-inside>: one of each at most (one alone is a single).
                return inside.count <= 1
            }
            // <display-listitem>: list-item with at most one outside and at most flow or flow-root.
            return inside.count <= 1 && inside.allSatisfy { $0 == "flow" || $0 == "flow-root" }
        }

        static let cssWide: Set<String> = ["inherit", "initial", "unset", "revert", "revert-layer"]

        static let displayOutside: Set<String> = ["block", "inline", "run-in"]

        static let displayInside: Set<String> = ["flow", "flow-root", "table", "flex", "grid", "ruby", "math"]

        /// Values valid only as the whole declaration: <display-box>, <display-internal>,
        /// <display-legacy> (with the prefixed forms every engine still accepts), and the
        /// CSS-wide keywords. The outside and inside keywords and `list-item` are valid alone too.
        static let displaySingles: Set<String> = cssWide.union(displayOutside).union(displayInside).union([
            "none", "contents", "list-item",
            "table-row-group", "table-header-group", "table-footer-group", "table-row", "table-cell",
            "table-column-group", "table-column", "table-caption", "ruby-base", "ruby-text",
            "ruby-base-container", "ruby-text-container",
            "inline-block", "inline-table", "inline-flex", "inline-grid",
            "-webkit-box", "-webkit-inline-box", "-webkit-flex", "-webkit-inline-flex",
        ])

        /// One `name: value [!important]` declaration, or nil when it has no name or no value.
        /// Names are lowercased, except a custom property's (`--name`), which CSS matches by
        /// case; values are kept as written (a `var()` in one names a custom property).
        static func declaration(_ text: String) -> Declaration? {
            guard let colon = text.firstIndex(of: ":") else { return nil }
            let property = propertyName(unescaped(text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)))
            var value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            var important = false
            // `!important` as written: an escaped `!` is part of a name, not the flag.
            if let bang = value.lastIndex(of: "!"), bang == value.startIndex || value[value.index(before: bang)] != "\\",
               unescaped(value[value.index(after: bang)...].trimmingCharacters(in: .whitespacesAndNewlines))
                   .lowercased() == "important" {
                important = true
                value = value[..<bang].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            value = unescaped(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !property.isEmpty, !property.contains(where: \.isWhitespace), !value.isEmpty else { return nil }
            return Declaration(property: property, value: value, important: important)
        }

        /// `text` with its CSS escapes decoded, as the tokenizer reads them: a backslash and one
        /// to six hex digits is that code point (zero, a surrogate, or one past U+10FFFF is
        /// U+FFFD), one whitespace after the digits belongs to the escape, and a backslash before
        /// any other character is that character. A backslash before a line break, or at the end,
        /// is kept. So `\6e one` and `n\6f ne` are `none`.
        static func unescaped(_ text: String) -> String {
            guard text.contains("\\") else { return text }
            let scalars = Array(text.unicodeScalars)
            var result = String.UnicodeScalarView()
            var index = 0
            func isHex(_ scalar: Unicode.Scalar) -> Bool { scalar.isASCII && scalar.properties.isASCIIHexDigit }
            while index < scalars.count {
                let scalar = scalars[index]
                guard scalar == "\\", index + 1 < scalars.count, !["\n", "\r", "\u{0C}"].contains(scalars[index + 1]) else {
                    result.append(scalar)
                    index += 1
                    continue
                }
                index += 1
                guard isHex(scalars[index]) else {
                    result.append(scalars[index])
                    index += 1
                    continue
                }
                var value: UInt32 = 0
                var digits = 0
                while index < scalars.count, digits < 6, isHex(scalars[index]) {
                    value = value * 16 + (UInt32(String(scalars[index]), radix: 16) ?? 0)
                    digits += 1
                    index += 1
                }
                result.append(value == 0 ? "\u{FFFD}" : Unicode.Scalar(value) ?? "\u{FFFD}")
                // One whitespace after the digits ends the escape; "\r\n" counts as one.
                if index < scalars.count, [" ", "\t", "\n", "\r", "\u{0C}"].contains(scalars[index]) {
                    index += scalars[index] == "\r" && index + 1 < scalars.count && scalars[index + 1] == "\n" ? 2 : 1
                }
            }
            return String(result)
        }

        /// The text split at semicolons outside quotes and brackets, so a `;` inside
        /// `url("a;b")` does not end a declaration.
        static func split(_ text: String) -> [String] {
            var parts: [String] = []
            var current = ""
            var quote: Character?
            var depth = 0
            var escaped = false
            for character in text {
                if escaped { escaped = false; current.append(character); continue }
                if character == "\\" { escaped = true; current.append(character); continue }
                if let open = quote {
                    // A line break ends a string too (CSS makes it a bad string).
                    if character == open || character.isNewline { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "(" || character == "[" {
                    depth += 1
                } else if character == ")" || character == "]" {
                    depth = max(0, depth - 1)
                } else if character == ";", depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
                current.append(character)
            }
            parts.append(current)
            return parts
        }

        /// The text without `/* … */` comments (an unclosed one runs to the end). As CSS reads
        /// it, `/*` in a quoted string (`url("/*")`) or after a backslash (`\/*`) starts no
        /// comment: strings and escapes are read as `split` reads them, and a string also ends
        /// at a line break.
        static func strippingComments(_ text: String) -> String {
            let characters = Array(text)
            var result = ""
            var quote: Character?
            var index = 0
            while index < characters.count {
                let character = characters[index]
                if character == "\\" {
                    // An escape: the backslash and the character after it, whatever that is.
                    result.append(character)
                    if index + 1 < characters.count { result.append(characters[index + 1]) }
                    index += 2
                    continue
                }
                if let open = quote {
                    if character == open || character.isNewline { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    var close = index + 2
                    while close + 1 < characters.count, !(characters[close] == "*" && characters[close + 1] == "/") {
                        close += 1
                    }
                    guard close + 1 < characters.count else { return result }
                    result += " "
                    index = close + 2
                    continue
                }
                result.append(character)
                index += 1
            }
            return result
        }
    }
}
