import Foundation

extension HTMLReader {
    // MARK: Elements the parser does not know

    /// A new name for the attribute that carries an element's own name after `prepared` renamed
    /// it: `data-holos-<32 random hex digits>-tag`, made for each page read. A page cannot name it
    /// in advance, so an attribute the page itself has (`<p data-holos-tag="script">`) is never
    /// taken for one `prepared` added.
    static func originalNameAttribute() -> String {
        "data-holos-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() + "-tag"
    }

    /// Elements the tidying parser keeps (HTML 4 and its legacy extensions). It drops the tags of
    /// any other element, HTML5's included, and keeps their contents as if the tags were not there.
    static let knownToParser: Set<String> = [
        "a", "abbr", "acronym", "address", "applet", "area", "b", "base", "basefont", "bdo", "big",
        "blockquote", "body", "br", "button", "caption", "center", "cite", "code", "col", "colgroup",
        "dd", "del", "dfn", "dir", "div", "dl", "dt", "em", "fieldset", "font", "form", "frame",
        "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "html", "i", "iframe", "img",
        "input", "ins", "isindex", "kbd", "label", "legend", "li", "link", "map", "menu", "meta",
        "noframes", "noscript", "object", "ol", "optgroup", "option", "p", "param", "pre", "q", "s",
        "samp", "script", "select", "small", "span", "strike", "strong", "style", "sub", "sup",
        "table", "tbody", "td", "textarea", "tfoot", "th", "thead", "title", "tr", "tt", "u", "ul",
        "var", "embed", "nobr", "wbr", "marquee", "blink", "xmp", "listing", "plaintext", "layer",
        "ilayer", "spacer", "bgsound", "keygen", "rb", "rbc", "rp", "rt", "rtc", "ruby", "multicol",
        "nolayer",
    ]
    /// Unknown elements that stand as blocks become `div`s; every other one becomes a `span`.
    static let blockReplaced: Set<String> = [
        "article", "aside", "details", "dialog", "figcaption", "figure", "footer", "header", "hgroup",
        "main", "nav", "search", "section", "summary", "template",
    ]
    /// Elements none of whose contents is read. Every element inside one becomes a `span` (raw
    /// text elements aside), so the parser keeps the contents in place: it moves a template's
    /// table cells into the table around the template otherwise.
    static let opaque: Set<String> = ["template", "svg", "math"]
    /// Elements that are foreign content (SVG, MathML), where `/>` ends an element.
    static let foreign: Set<String> = ["svg", "math"]
    /// HTML's void elements: never any contents, and the only HTML elements `/>` ends.
    static let void: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr",
    ]
    /// Elements whose contents is text, never tags.
    static let rawText: Set<String> = ["script", "style", "textarea", "title", "xmp", "iframe", "noembed", "noframes"]

    /// `html` with every element the tidying parser does not know renamed to one it does, its own
    /// name kept in `nameAttribute` (see `originalNameAttribute`): `<nav class="x">` becomes
    /// `<div data-holos-…-tag="nav" class="x">`. The parser then keeps it as an element with all its
    /// contents, nested ones included, for `Walker` to read or skip. Only tag names change, a
    /// self-closing slash HTML ignores is dropped (see `void`), and `<` in raw text elements other
    /// than scripts and styles (which the parser reads as text) is escaped; comments are copied
    /// as they are, an abruptly closed one written out in full (see `commentEnd`).
    static func prepared(_ html: String, nameAttribute: String) -> String {
        let bytes = Array(html.utf8)
        let count = bytes.count
        var output: [UInt8] = []
        output.reserveCapacity(count + count / 16)
        // Open opaque elements, innermost last.
        var opaqueOpen: [String] = []
        var index = 0

        func starts(_ text: String, at position: Int) -> Bool {
            let pattern = Array(text.utf8)
            guard position + pattern.count <= count else { return false }
            return zip(bytes[position...], pattern).allSatisfy { lowercased($0) == $1 }
        }
        func replacement(_ name: String) -> String { blockReplaced.contains(name) ? "div" : "span" }

        while index < count {
            guard bytes[index] == UInt8(ascii: "<") else {
                output.append(bytes[index])
                index += 1
                continue
            }
            if starts("<!--", at: index) {
                guard let end = commentEnd(in: bytes, from: index) else {
                    // An unfinished comment: the rest is copied for the parser to make of it what it can.
                    output += bytes[index...]
                    break
                }
                // Written out in full, so the parser reads the comment where the prescan does: an
                // abruptly closed `<!-->` or `<!--->` becomes `<!---->`, and one closed with
                // `--!>` ends with `-->`.
                let text = commentText(in: bytes, from: index, to: end)
                output += Array("<!--".utf8) + text + Array("-->".utf8)
                index = end
                continue
            }
            var scanner = TagScanner(bytes: bytes, position: index)
            guard let (name, closing) = scanner.tagName() else {
                output.append(bytes[index])
                index += 1
                continue
            }
            let tagStart = index
            let cursor = scanner.position
            // The tag ends at the first `>` outside a quoted attribute value (see `TagScanner`).
            var last: TagScanner.Attribute?
            while let attribute = scanner.attribute() { last = attribute }
            let end = scanner.position
            guard end < count else {
                // An unfinished tag: the rest is copied for the parser to make of it what it can.
                output += bytes[tagStart...]
                break
            }
            // `/>` outside an unquoted value (in `href=a/>` the slash is the value's).
            let slashInValue = last.map { $0.unquoted && $0.value.upperBound == end } ?? false
            let slash = !closing && !slashInValue && bytes[end - 1] == UInt8(ascii: "/")
            // As HTML reads it, the slash makes an empty element only of a void element or in
            // foreign content (SVG, MathML, `<svg/>` itself); `<template/>` and `<nav/>` stay open
            // up to their end tags. The parser would take every `/>` as empty, so an ignored slash
            // is dropped. A void element is empty with or without it.
            let insideForeign = opaqueOpen.contains { foreign.contains($0) }
            let selfClosing = slash && (void.contains(name) || foreign.contains(name) || insideForeign)
            let empty = selfClosing || (void.contains(name) && !insideForeign)
            let attributes = slash && !selfClosing ? bytes[cursor..<(end - 1)] : bytes[cursor..<end]
            index = end + 1

            if closing {
                let renamed: String?
                if let innermost = opaqueOpen.last {
                    if name == innermost {
                        opaqueOpen.removeLast()
                        renamed = opaqueOpen.isEmpty ? replacement(name) : "span"
                    } else {
                        renamed = rawText.contains(name) && name != "title" ? nil : "span"
                    }
                } else {
                    renamed = knownToParser.contains(name) ? nil : replacement(name)
                }
                if let renamed { output += Array("</\(renamed)>".utf8) } else { output += bytes[tagStart..<index] }
                continue
            }

            let insideOpaque = !opaqueOpen.isEmpty
            if name == "plaintext", !insideForeign {
                // `<plaintext>` has no end tag: all after it is its text, `</plaintext>` included,
                // so the rest is escaped into it (and it is not read, see `skipped`). In an opaque
                // element it is a `span` like every other element there, all of it unread.
                let element = insideOpaque ? "span" : "plaintext"
                output += Array("<\(element)>".utf8)
                for byte in bytes[index...] {
                    if byte == UInt8(ascii: "<") { output += Array("&lt;".utf8) } else { output.append(byte) }
                }
                output += Array("</\(element)>".utf8)
                break
            }
            // In an opaque element a raw text element keeps its name, so the parser still reads
            // its contents as text; `<title>` there is an SVG title, which is markup.
            let isRawText = rawText.contains(name) && !(insideOpaque && name == "title") && !selfClosing
            let renamed: String?
            if insideOpaque {
                renamed = isRawText ? nil : "span"
            } else {
                renamed = knownToParser.contains(name) ? nil : replacement(name)
            }
            if opaque.contains(name), !selfClosing { opaqueOpen.append(name) }
            if let renamed {
                var tag = "<" + renamed
                if !insideOpaque, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_:.".contains($0)) }) {
                    tag += " \(nameAttribute)=\"\(name)\""
                }
                output += Array(tag.utf8)
                output += selfClosing ? attributes.dropLast() : attributes
                // `<path/>` and `<source>` become explicitly empty elements: `<span/>` could be
                // taken for an open one, hiding the text after it.
                output += Array((empty ? "></\(renamed)>" : ">").utf8)
            } else {
                // As written, less an ignored slash.
                output += bytes[tagStart..<cursor]
                output += attributes
                output.append(UInt8(ascii: ">"))
            }
            if isRawText {
                // Copied as it is up to its end tag, which the loop then reads.
                var close = index
                while close < count, !scanner.endTag(name, at: close) { close += 1 }
                if name == "script" || name == "style" {
                    output += bytes[index..<close]
                } else {
                    // The parser reads tags in the others (`<textarea><nav>…`), so their `<` is
                    // escaped: all it can do there is start a tag.
                    for byte in bytes[index..<close] {
                        if byte == UInt8(ascii: "<") { output += Array("&lt;".utf8) } else { output.append(byte) }
                    }
                }
                index = close
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// Where the comment whose `<!--` is at `start` ends: just past its `-->` or `--!>`, or nil
    /// when it never ends. As HTML reads it, the dashes of `<!--` may close it too: `<!-->` and
    /// `<!--->` are whole, empty comments; `--!>` ends one only after `<!--` (`<!--!>` does not).
    /// The charset prescan (`CharsetPrescan`) and `prepared` both read comments by this rule, so
    /// neither takes text the other reads as a comment.
    static func commentEnd(in bytes: [UInt8], from start: Int) -> Int? {
        let dash = UInt8(ascii: "-"), bang = UInt8(ascii: "!"), greaterThan = UInt8(ascii: ">")
        var index = start + 2
        while index + 2 < bytes.count {
            if bytes[index] == dash, bytes[index + 1] == dash {
                if bytes[index + 2] == greaterThan { return index + 3 }
                if index >= start + 4, index + 3 < bytes.count, bytes[index + 2] == bang,
                   bytes[index + 3] == greaterThan { return index + 4 }
            }
            index += 1
        }
        return nil
    }

    /// The text of the comment from `start` (its `<!--`) to `end` (see `commentEnd`), without
    /// its `-->` or `--!>`; empty for `<!-->` and `<!--->`.
    static func commentText(in bytes: [UInt8], from start: Int, to end: Int) -> ArraySlice<UInt8> {
        let closing = end - start >= 8 && bytes[end - 2] == UInt8(ascii: "!") ? 4 : 3
        return start + 4 <= end - closing ? bytes[(start + 4)..<(end - closing)] : []
    }

    static func lowercased(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lowercased(byte))
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D
    }
}
