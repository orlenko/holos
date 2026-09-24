import Foundation
import HolosCore

/// `exports/transcript.md` (docs/meeting-design.md §4.11): a header, then speaker blocks, gap lines, and marker lines
/// in time order.
///
/// ```
/// # Council meeting
///
/// - Date: 2026-09-23
/// - Started: 14:00
/// - Duration: 2:58:12
/// - Participants: Jim (41:12), Speaker 2 (22:03), Me (15:40)
///
/// **Jim** · 00:12:03
///
/// We should move the vote to next week.
///
/// **Speaker 2** · 00:12:40 · overlapping with Jim
///
/// Agreed, but …
///
/// _[Recording paused 00:45:10–00:47:02]_
///
/// _[Marker 01:02:03: Budget vote]_
/// ```
///
/// Date and start time are `metadata.createdAt` in `metadata.timeZone`. Participants are the projection's speakers
/// with turns, by talk time descending (ties in speaker order); the line is left out without a projection. A gap or
/// marker line at the same time as a block comes before it; repeated identical lines print once, adjacent or not.
/// Names, labels, the title, and a block's text are kept on one line with every character that can start inline
/// Markdown escaped (`\` `` ` `` `*` `_` `[` `]` `!` `<` `>` `&` `~` `|`), so no emphasis, code span, link, image,
/// HTML, entity, strikethrough, or table changes them; a block's text is one paragraph with its leading block syntax
/// ("# ", "- ", "1. ", "[x]: ", …) escaped too, so it renders literally as a visible paragraph.
enum MarkdownExport {
    static func render(_ content: ExportContent) -> Data {
        let metadata = content.document.metadata
        let (date, time) = localDateAndTime(metadata.createdAt, in: metadata.timeZone)
        var text = "# \(title(metadata.name))\n\n"
        text += "- Date: \(date)\n"
        text += "- Started: \(time)\n"
        text += "- Duration: \(TimeFormat.duration(metadata.durationSeconds))\n"
        if let participants = participants(content.projection) {
            text += "- Participants: \(participants)\n"
        }
        for paragraph in paragraphs(content) {
            text += "\n\(paragraph)\n"
        }
        return Data(text.utf8)
    }

    // MARK: Body

    private static func paragraphs(_ content: ExportContent) -> [String] {
        var events: [(time: Double, rank: Int, text: String)] = []
        for gap in content.gaps {
            events.append((gap.start, 0, "_[\(gapText(gap.reason)) \(TimeFormat.clock(gap.start))–\(TimeFormat.clock(gap.end))]_"))
        }
        for marker in content.markers {
            let label = ExportText.singleLine(marker.label ?? "")
            let text = label.isEmpty
                ? "_[Marker \(TimeFormat.clock(marker.at))]_"
                : "_[Marker \(TimeFormat.clock(marker.at)): \(escapeInline(label))]_"
            events.append((marker.at, 1, text))
        }
        for block in content.blocks {
            var header = "**\(escapeInline(ExportText.headerLabel(block.speakerLabel)))** · \(TimeFormat.clock(block.start))"
            if !block.overlapWith.isEmpty {
                header += " · overlapping with "
                    + block.overlapWith.map { escapeInline(ExportText.headerLabel($0)) }.joined(separator: ", ")
            }
            events.append((TurnOrder.sortKey(block.start), 2, header + "\n\n" + paragraph(block.text)))
        }
        let ordered = events.enumerated().sorted {
            ($0.element.time, $0.element.rank, $0.offset) < ($1.element.time, $1.element.rank, $1.offset)
        }
        var result: [String] = []
        var printedLines: Set<String> = []
        for event in ordered.map(\.element) {
            // The same gap reported for several tracks, or a doubled marker, prints once, wherever the copies are.
            if event.rank < 2, !printedLines.insert(event.text).inserted { continue }
            result.append(event.text)
        }
        return result
    }

    /// Gap lines by reason; reasons from a newer Holos read "Audio gap".
    static func gapText(_ reason: GapReason) -> String {
        switch reason {
        case .paused: "Recording paused"
        case .sleep: "No audio: computer was asleep"
        case .deviceChanged, .captureRestarted: "Audio restarted"
        case .audioUnavailable: "No audio: microphone unavailable"
        default: "Audio gap"
        }
    }

    // MARK: Header

    private static func title(_ name: String) -> String {
        var title = escapeInline(ExportText.singleLine(name))
        if title.isEmpty { title = "Meeting" }
        // A trailing "#" would close the ATX heading.
        if title.hasSuffix("#") { title = String(title.dropLast()) + "\\#" }
        return title
    }

    /// "Jim (41:12), Speaker 2 (22:03)": speakers with turns by talk time, descending; nil when there are none.
    private static func participants(_ projection: SpeakerProjection?) -> String? {
        guard let projection else { return nil }
        let speakers = projection.speakers.enumerated()
            .filter { $0.element.turnCount > 0 }
            .sorted { lhs, rhs in
                let left = lhs.element.talkSeconds.isNaN ? 0 : lhs.element.talkSeconds
                let right = rhs.element.talkSeconds.isNaN ? 0 : rhs.element.talkSeconds
                if left != right { return left > right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        guard !speakers.isEmpty else { return nil }
        return speakers.map {
            "\(escapeInline(ExportText.headerLabel($0.label))) (\(TimeFormat.duration($0.talkSeconds)))"
        }.joined(separator: ", ")
    }

    /// ("2026-09-23", "14:00") in the Gregorian calendar.
    static func localDateAndTime(_ date: Date, in timeZone: TimeZone) -> (date: String, time: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = "\(pad(parts.year ?? 0, 4))-\(pad(parts.month ?? 0, 2))-\(pad(parts.day ?? 0, 2))"
        return (day, "\(pad(parts.hour ?? 0, 2)):\(pad(parts.minute ?? 0, 2))")
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value.magnitude)
        let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
        return value < 0 ? "-" + padded : padded
    }

    // MARK: Escaping

    /// Backslash-escapes every character that can start inline Markdown, for titles, names, and labels.
    static func escapeInline(_ text: String) -> String {
        escape(text, inlineEscapedCharacters)
    }

    /// A block's text as one paragraph that renders literally: on one line, with every character that can start
    /// inline Markdown escaped, then leading block syntax escaped.
    static func paragraph(_ text: String) -> String {
        escapeParagraphStart(escape(ExportText.singleLine(text), inlineEscapedCharacters))
    }

    private static func escape(_ text: String, _ characters: Set<Character>) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            if characters.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// The ASCII punctuation that CommonMark or GFM can read as inline syntax anywhere in a line: escapes (`\`), code
    /// spans, emphasis, links and images (`[`, `]`, `!`), inline HTML and autolinks (`<`, `>`), entity references
    /// (`&`), strikethrough (`~`), and table cells (`|`). CommonMark lets a backslash escape any ASCII punctuation, so
    /// each escaped character renders as itself. Other punctuation only matters at the start of a line, which
    /// `escapeParagraphStart` handles.
    static let inlineEscapedCharacters: Set<Character> =
        ["\\", "`", "*", "_", "[", "]", "!", "<", ">", "&", "~", "|"]

    /// Escapes block syntax at the start of a one-line paragraph so it renders as text: an ATX heading, block quote,
    /// list item, thematic break, code fence, HTML block, or link reference definition (`[label]: url`, which
    /// renders as nothing).
    static func escapeParagraphStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        let second = line.dropFirst().first
        switch first {
        case "#":
            let hashes = line.prefix { $0 == "#" }.count
            let next = line.dropFirst(hashes).first
            if hashes <= 6, next == nil || next == " " { return "\\" + line }
        case ">", "<":
            return "\\" + line
        case "[":
            if line.contains("]:") { return "\\" + line }
        case "-", "+", "*":
            if second == nil || second == " " || isThematicBreak(line) { return "\\" + line }
        case "_":
            if isThematicBreak(line) { return "\\" + line }
        case "`", "~":
            if line.hasPrefix(String(repeating: first, count: 3)) { return "\\" + line }
        default:
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard (1...9).contains(digits.count) else { break }
            let rest = line.dropFirst(digits.count)
            let after = rest.dropFirst().first
            if let mark = rest.first, mark == "." || mark == ")", after == nil || after == " " {
                return String(digits) + "\\" + String(rest)
            }
        }
        return line
    }

    /// Three or more of one of "-", "*", "_", optionally separated by spaces.
    private static func isThematicBreak(_ line: String) -> Bool {
        let marks = line.filter { $0 != " " }
        guard let mark = marks.first, "-*_".contains(mark), marks.count >= 3 else { return false }
        return marks.allSatisfy { $0 == mark }
    }
}
