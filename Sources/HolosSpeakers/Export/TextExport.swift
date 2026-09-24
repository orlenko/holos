import Foundation

/// `exports/transcript.txt` (docs/meeting-design.md §4.11), in Otter's layout: per `ExportBlock`, the header
/// `"<label>  <time>"` (two spaces; `mm:ss` below one hour, `h:mm:ss` from one hour), the text on one line, and a
/// blank line. No gap or marker lines and no footer, so `OtterTranscriptParser` and the evaluator's header regex
/// `^\s*\S.*\s{2,}\d{1,2}:\d{2}(?::\d{2})?\s*$` read it.
///
/// Labels and texts are kept on one line with single spaces, so a text line never matches the header regex and a
/// label reads back unchanged.
enum TextExport {
    static func render(_ content: ExportContent) -> Data {
        var text = ""
        for block in content.blocks {
            text += "\(ExportText.headerLabel(block.speakerLabel))  \(TimeFormat.compact(block.start))\n"
            text += "\(ExportText.singleLine(block.text))\n\n"
        }
        return Data(text.utf8)
    }
}
