import Foundation

extension HTMLReader {
    struct Walker {
        /// An `<ol>` being read: the next item's number and how items are numbered.
        struct OrderedList {
            var next: Int
            var step: Int
            var type: String
        }

        /// The attribute `prepared` put an element's own name in, this page's own.
        let nameAttribute: String
        var builder = ReadableDocument.Builder()
        var inline = ""
        var row: [String]?
        /// Open lists, innermost last; nil for an unordered one.
        var lists: [OrderedList?] = []
        /// "3. " before the first text of an ordered list item.
        var marker: String?
        /// The paragraphs of the table cell being read, which make up its text; nil outside cells.
        var cell: [String]?

        mutating func flush() {
            emit(collapse(inline))
            inline = ""
        }

        /// Writes a block of text, the pending list marker ("3. ") before it: a paragraph, the
        /// next of a table cell's paragraphs, or, with `heading`, a section heading outside cells
        /// (so "<ol><li><h2>Install</h2></li></ol>" gives the section, and its chapter, "1. Install").
        /// Every block the walker writes goes through here, so no block drops an item's number.
        mutating func emit(_ text: String, heading level: Int? = nil) {
            guard !text.isEmpty else { return }
            if cell != nil {
                cell?.append((marker ?? "") + text)
            } else if let level {
                builder.heading((marker ?? "") + text, level: level)
            } else {
                builder.paragraph((marker ?? "") + text)
            }
            marker = nil
        }

        mutating func walk(_ node: XMLNode) {
            if node.kind == .text {
                inline += node.stringValue ?? ""
                return
            }
            guard node.kind == .element else { return }
            if isSkipped(node) { return }
            let name = self.name(of: node)
            // A heading in a table cell is part of the cell's text, read as a block. Elsewhere it
            // starts a section, an ordered item's number before it.
            let heading = name.count == 2 && name.first == "h" ? Int(String(name.last!)).flatMap { (1...6).contains($0) ? $0 : nil } : nil
            if let level = heading, cell == nil {
                flush()
                emit(collapse(text(of: node)), heading: level)
                return
            }
            // A cell is read like the rest of the page (lists keep their numbers, blocks stay
            // apart, a nested table's rows are read), its paragraphs joined into one line. The
            // cell stands on its own: a list around its table does not number its items, and an
            // item's number stays for the row.
            if name == "td" || name == "th" {
                flush()
                let outer = (cell, lists, marker)
                cell = []
                lists = []
                marker = nil
                for child in node.children ?? [] { walk(child) }
                flush()
                let text = cell?.joined(separator: " ") ?? ""
                (cell, lists, marker) = outer
                if !text.isEmpty {
                    if row != nil { row?.append(text) } else { emit(text) }
                }
                return
            }
            if name == "tr" {
                flush()
                let outer = row
                row = []
                for child in node.children ?? [] { walk(child) }
                flush()
                let cells = row ?? []
                row = outer
                if !cells.isEmpty { emit(cells.joined(separator: "; ")) }
                return
            }
            // Ordered list items keep their numbers, as the page shows them: `start`, `reversed`,
            // `type` (1, a, A, i, I), and an item's `value` are honored. Bullets are not read.
            // A list nested in an ordered item before the item's own text leaves the item's number
            // for that text: "<li><ul><li>substep</li></ul>main step</li>" reads "1. main step".
            if name == "ol" || name == "ul" || name == "menu" {
                flush()
                let pending = marker
                marker = nil
                lists.append(name == "ol" ? Self.orderedList(node) : nil)
                for child in node.children ?? [] { walk(child) }
                flush()
                lists.removeLast()
                marker = pending
                return
            }
            if name == "li", let open = lists.last {
                flush()
                if var list = open {
                    if let value = Self.counter(Self.attribute("value", of: node)) { list.next = value }
                    marker = Self.marker(list.next, type: list.type) + " "
                    // Never traps: a counter at the integer bounds stays there.
                    let (advanced, overflow) = list.next.addingReportingOverflow(list.step)
                    if !overflow { list.next = advanced }
                    lists[lists.count - 1] = list
                }
                for child in node.children ?? [] { walk(child) }
                flush()
                marker = nil
                return
            }
            // A closed disclosure (`details` without `open`) shows only its summary, its first
            // `summary` child; the rest is read only when it is open.
            if name == "details", Self.attribute("open", of: node) == nil {
                flush()
                if let summary = (node.children ?? []).first(where: { $0.kind == .element && self.name(of: $0) == "summary" }) {
                    walk(summary)
                }
                flush()
                return
            }
            let isBlock = HTMLReader.blocks.contains(name) || heading != nil
            if isBlock { flush() }
            for child in node.children ?? [] { walk(child) }
            if isBlock { flush() }
        }

        /// An element's HTML name, lowercased: the one it had before `prepared` renamed it, else
        /// its own.
        func name(of node: XMLNode) -> String {
            Self.attribute(nameAttribute, of: node)?.lowercased()
                ?? (node.localName ?? node.name ?? "").lowercased()
        }

        /// A skipped element (a script, a navigation bar), or one the page hides: with a `hidden`
        /// attribute, `aria-hidden="true"`, an inline `display: none`, or a `<dialog>` that is not
        /// open. Nothing inside it is read.
        func isSkipped(_ node: XMLNode) -> Bool {
            let name = self.name(of: node)
            if HTMLReader.skipped.contains(name) { return true }
            if name == "dialog", Self.attribute("open", of: node) == nil { return true }
            if Self.attribute("hidden", of: node) != nil { return true }
            if Self.attribute("aria-hidden", of: node)?.lowercased() == "true" { return true }
            return Self.attribute("style", of: node).map(Self.hidesElement) ?? false
        }

        /// Whether an inline style's effective `display` is `none`: the declaration that wins the
        /// cascade within the attribute, so `display:none; display:block` shows the element and
        /// `display:none !important; display:block` hides it. A value with `var()` is accepted,
        /// as a browser accepts it, and counts once its variables are substituted from the
        /// attribute's own custom properties (`--mode:none; display:var(--mode)` hides). One that
        /// is invalid once substituted makes `display` its initial `inline`, which shows the
        /// element, and so does one this attribute cannot resolve: the text is read rather than
        /// possibly visible text dropped.
        static func hidesElement(_ style: String) -> Bool {
            let style = InlineStyle(style)
            guard var display = style.value(of: "display", isValid: {
                InlineStyle.isDisplayValue($0) || InlineStyle.usesVariables($0)
            }) else { return false }
            if InlineStyle.usesVariables(display) {
                guard case .value(let substituted) = style.substitutingVariables(in: display) else { return false }
                display = substituted
            }
            return HTMLReader.collapse(display).lowercased() == "none"
        }

        /// The attribute whose local name is `name` in any ASCII case (HTML attribute names are
        /// case-insensitive); with `qualified`, only one whose whole name is that, so `lang` is
        /// told apart from `xml:lang`.
        static func attribute(_ name: String, of node: XMLNode, qualified: String? = nil) -> String? {
            (node as? XMLElement)?.attributes?.first {
                if let qualified { return $0.name?.lowercased() == qualified }
                return ($0.localName ?? $0.name)?.lowercased() == name
            }?.stringValue?.trimmingCharacters(in: .whitespaces)
        }

        static func orderedList(_ node: XMLNode) -> OrderedList {
            let reversed = attribute("reversed", of: node) != nil
            let items = (node.children ?? []).filter { ($0.localName ?? $0.name)?.lowercased() == "li" }.count
            let start = counter(attribute("start", of: node)) ?? (reversed ? items : 1)
            let type = attribute("type", of: node) ?? "1"
            return OrderedList(next: start, step: reversed ? -1 : 1, type: type)
        }

        /// The largest list number `start` or `value` may set, either sign.
        static let counterLimit = 1_000_000_000

        /// A `start` or `value` attribute as a list number; nil (so the default numbering
        /// applies) when it is not an integer or is beyond `counterLimit`.
        static func counter(_ text: String?) -> Int? {
            guard let text, let value = Int(text), (-counterLimit...counterLimit).contains(value) else { return nil }
            return value
        }

        /// "3.", "c.", "iii.", "C.", "III."; decimal for numbers a letter or numeral cannot show.
        static func marker(_ number: Int, type: String) -> String {
            switch type {
            case "a" where number > 0, "A" where number > 0:
                var letters = ""
                var rest = number
                while rest > 0 {
                    rest -= 1
                    letters = String(UnicodeScalar(UInt8(97 + rest % 26))) + letters
                    rest /= 26
                }
                return (type == "A" ? letters.uppercased() : letters) + "."
            case "i" where (1..<4_000).contains(number), "I" where (1..<4_000).contains(number):
                let numerals = [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
                                (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")]
                var roman = ""
                var rest = number
                for (value, symbol) in numerals {
                    while rest >= value { roman += symbol; rest -= value }
                }
                return (type == "I" ? roman.uppercased() : roman) + "."
            default:
                return "\(number)."
            }
        }

        /// Visible text of an element, without skipped descendants.
        func text(of node: XMLNode) -> String {
            if node.kind == .text { return node.stringValue ?? "" }
            guard node.kind == .element, !isSkipped(node) else { return "" }
            let separator = HTMLReader.blocks.contains(name(of: node)) ? " " : ""
            return separator + (node.children ?? []).map(text(of:)).joined() + separator
        }
    }
}
