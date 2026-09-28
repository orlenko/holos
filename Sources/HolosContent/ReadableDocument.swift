import Foundation

/// Text worth reading aloud, with its structure: what every extractor produces (local files
/// here; web articles from the URL extractor) and what `ReadingPipeline` reads.
public struct ReadableDocument: Sendable, Equatable, Codable {
    public struct Section: Sendable, Equatable, Codable {
        /// Nil for text before the first heading.
        public var heading: String?
        /// 1...6 for a heading, 0 without one.
        public var level: Int
        public var paragraphs: [String]

        public init(heading: String? = nil, level: Int = 0, paragraphs: [String] = []) {
            self.heading = heading
            self.level = heading == nil ? 0 : min(6, max(1, level))
            self.paragraphs = paragraphs
        }
    }

    public var title: String?
    public var author: String?
    /// BCP 47 language the source declares (such as `<html lang>`); nil when unknown.
    public var language: String?
    public var sections: [Section]

    public init(title: String? = nil, author: String? = nil, language: String? = nil,
                sections: [Section]) {
        self.title = Self.clean(title)
        self.author = Self.clean(author)
        self.language = Self.clean(language)
        self.sections = sections.compactMap { section in
            let heading = Self.clean(section.heading)
            let paragraphs = section.paragraphs.compactMap(Self.clean)
            if heading == nil && paragraphs.isEmpty { return nil }
            return Section(heading: heading, level: section.level, paragraphs: paragraphs)
        }
    }

    public var isEmpty: Bool { sections.isEmpty }

    /// Separators between a page title and the site or series name around it:
    /// "Title | Site", "Site — Title", "Title - Blog". A colon is not one: it starts a subtitle.
    static let titleSeparators = [" | ", " || ", " — ", " – ", " - ", " · ", " • ", " :: ", " » ", " « "]

    /// Whether `text` says the same as `title`: equal ignoring case, diacritics, punctuation, and
    /// spacing, or equal to `title` without the site or series names around it ("Title | Site"
    /// says "Title"), or the other way around.
    public static func sameTitle(_ title: String, _ text: String) -> Bool {
        let titleWords = titleKey(title), textWords = titleKey(text)
        guard !titleWords.isEmpty, !textWords.isEmpty else { return false }
        if titleWords == textWords { return true }
        return titleCores(title).contains(textWords) || titleCores(text).contains(titleWords)
    }

    /// Letters and digits only, case- and diacritic-folded, one space between words.
    static func titleKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The keys of `title` with one or more of its leading or trailing separated parts removed.
    static func titleCores(_ title: String) -> Set<String> {
        var parts = [title]
        for separator in titleSeparators {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        guard parts.count > 1 else { return [] }
        var keys = Set<String>()
        for start in 0..<parts.count {
            for end in (start + 1)...parts.count where end - start < parts.count {
                let key = titleKey(parts[start..<end].joined(separator: " "))
                if !key.isEmpty && (start == 0 || end == parts.count) { keys.insert(key) }
            }
        }
        return keys
    }

    /// Collapses runs of spaces and tabs, keeps single line breaks, trims; nil when empty.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let lines = text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Accumulates headings and paragraphs in reading order.
    public struct Builder: Sendable {
        public private(set) var sections: [Section] = []

        public init() {}

        public mutating func heading(_ text: String, level: Int) {
            guard let text = ReadableDocument.clean(text)?.replacingOccurrences(of: "\n", with: " ") else { return }
            sections.append(Section(heading: text, level: level))
        }

        public mutating func paragraph(_ text: String) {
            guard let text = ReadableDocument.clean(text) else { return }
            if sections.isEmpty { sections.append(Section()) }
            sections[sections.count - 1].paragraphs.append(text)
        }

        /// The first heading, when it is a level-1 heading that comes before any text.
        public var leadingTitle: String? {
            guard let first = sections.first, first.level == 1 else { return nil }
            return first.heading
        }
    }
}

/// What is spoken, in order, split into parts that are rendered one at a time.
public struct ReadingScript: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        /// Starts a chapter with this title.
        public let chapter: String?
        public let text: String
    }

    public struct Part: Sendable, Equatable {
        public let index: Int
        /// UTF-16 range of the part in `text`.
        public let offset: Int
        public let length: Int
        public let text: String
        /// Starts a chapter with this title.
        public let chapter: String?
        /// Whether a new segment (a section) starts here.
        public let startsSegment: Bool
    }

    public static let segmentSeparator = "\n\n"

    public let segments: [Segment]
    public let title: String?

    /// The title is read first unless the document opens with it: its first spoken block (the
    /// first section's heading, or its first paragraph when it has none, such as a PDF's first
    /// line under a metadata title) says the title. "Title | Site" and "Title" count as the same
    /// (see `ReadableDocument.sameTitle`). A heading that says the title after other text (an h1
    /// after a byline or an introduction) is an ordinary heading, read where it stands, and the
    /// title is still read first. Each section is its heading followed by its paragraphs.
    ///
    /// The title spoken first has no chapter of its own: it belongs to the opening, which the
    /// chapter plan names after the book unless a later chapter already has that name (see
    /// `AudioBookChapterPlan`), so no two chapters are named alike.
    public init(document: ReadableDocument) {
        var segments: [Segment] = []
        let opening = document.sections.first.flatMap { $0.heading ?? $0.paragraphs.first }
        if let title = document.title, !(opening.map { ReadableDocument.sameTitle(title, $0) } ?? false) {
            segments.append(Segment(chapter: nil, text: title))
        }
        for section in document.sections {
            let text = ([section.heading].compactMap { $0 } + section.paragraphs)
                .joined(separator: Self.segmentSeparator)
            segments.append(Segment(chapter: section.heading, text: text))
        }
        self.segments = segments
        self.title = document.title
    }

    public var text: String { segments.map(\.text).joined(separator: Self.segmentSeparator) }

    /// Parts never cross a section, so every chapter starts at a part.
    public func parts(maxUTF16Units: Int = 3_000) -> [Part] {
        var result: [Part] = []
        var offset = 0
        for (index, segment) in segments.enumerated() {
            if index > 0 { offset += Self.segmentSeparator.utf16.count }
            for (chunkIndex, chunk) in SemanticChunker.chunks(segment.text, maxUTF16Units: maxUTF16Units).enumerated() {
                result.append(Part(index: result.count, offset: offset + chunk.offset, length: chunk.length,
                                   text: chunk.text, chapter: chunkIndex == 0 ? segment.chapter : nil,
                                   startsSegment: chunkIndex == 0))
            }
            offset += segment.text.utf16.count
        }
        return result
    }
}
