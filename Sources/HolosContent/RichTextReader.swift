import AppKit
import Foundation
import HolosCore

/// RTF, RTFD, Word, and OpenDocument text through AppKit's document readers. Paragraphs that are
/// marked as headings, or are short, unpunctuated, and set larger or bold, become headings.
/// Numbered list items keep their numbers: the Word readers leave them in the text ("\t1.\tItem"),
/// while the RTF and OpenDocument readers move them into the paragraph's text list, from which
/// they are put back.
public enum RichTextReader {
    static func document(_ url: URL, type: NSAttributedString.DocumentType) throws -> ReadableDocument {
        var attributes: NSDictionary?
        let text: NSAttributedString
        do {
            text = try NSAttributedString(url: url, options: [.documentType: type],
                                          documentAttributes: &attributes)
        } catch {
            throw HolosError.invalidInput("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let values = attributes as? [NSAttributedString.DocumentAttributeKey: Any] ?? [:]
        return document(from: text, title: values[.title] as? String, author: values[.author] as? String)
    }

    public static func document(from text: NSAttributedString, title: String?, author: String?) -> ReadableDocument {
        let string = text.string as NSString
        var paragraphs: [(text: String, size: CGFloat, bold: Bool, level: Int, listed: Bool)] = []
        var sizes: [CGFloat: Int] = [:]
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { substring, range, _, _ in
            guard var substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let list = (text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?
                .textLists.last
            // The Word readers keep the marker between tabs instead of a text list.
            let markedInText = substring.range(of: #"^\t[^\s]{1,8}\t"#, options: .regularExpression) != nil
            if let list {
                substring = numbered(substring, marker: list.marker(forItemNumber: text.itemNumber(in: list, at: range.location)))
            }
            var size: CGFloat = 0
            var bold = true
            var level = 0
            text.enumerateAttributes(in: range) { attributes, run, _ in
                if let font = attributes[.font] as? NSFont {
                    size = max(size, font.pointSize)
                    if !font.fontDescriptor.symbolicTraits.contains(.bold) { bold = false }
                    sizes[font.pointSize, default: 0] += run.length
                } else {
                    bold = false
                }
                if let style = attributes[.paragraphStyle] as? NSParagraphStyle, style.headerLevel > 0 {
                    level = style.headerLevel
                }
            }
            paragraphs.append((substring, size, bold, level, list != nil || markedInText))
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 0
        var builder = ReadableDocument.Builder()
        for paragraph in paragraphs {
            var level = paragraph.level
            // A list item is never taken for a heading, however it is set.
            if level == 0, !paragraph.listed, PlainTextReader.looksLikeTitle(paragraph.text), body > 0 {
                if paragraph.size >= body * 1.5 { level = 1 }
                else if paragraph.size >= body + 2 || (paragraph.bold && paragraph.size >= body) { level = 2 }
            }
            if level > 0 { builder.heading(paragraph.text, level: level) }
            else { builder.paragraph(paragraph.text) }
        }
        let declared = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReadableDocument(title: declared?.isEmpty == false ? declared : builder.leadingTitle,
                                author: author, sections: builder.sections)
    }

    /// A list item's text starting with its number ("3. Serve"). Bullets are not read, and a
    /// number the text already starts with is not added again.
    static func numbered(_ text: String, marker: String) -> String {
        let marker = marker.trimmingCharacters(in: .whitespaces)
        guard marker.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
        let punctuation = CharacterSet(charactersIn: ".)(")
        let body = text.trimmingCharacters(in: .whitespaces)
        let first = body.prefix { !$0.isWhitespace }.trimmingCharacters(in: punctuation)
        if first == marker.trimmingCharacters(in: punctuation) { return text }
        let spoken = marker.last.map { $0.isLetter || $0.isNumber } == true ? marker + "." : marker
        return spoken + " " + body
    }
}
