import Foundation
import HolosSynthesis

/// What `voiceislocal read --print-text` prints, for a local file and a web page alike: the title,
/// author, language, voice, file name, and chapters, a blank line, then the text as it is read.
///
/// A file or a page can hold control and format characters (a terminal escape sequence, a
/// bidirectional override), so every line is made safe to print with `WebArticle.sanitized`; the
/// text keeps its line breaks.
public enum ReadingPreview {
    public static func text(script: ReadingScript, metadata: AudioBookMetadata, voice: String,
                            fileName: String) -> String {
        var lines = ["Title: \(printable(metadata.title ?? "-"))"]
        if let author = metadata.author { lines.append("Author: \(printable(author))") }
        lines.append("Language: \(metadata.language.map(printable) ?? "unknown")")
        lines.append("Voice: \(printable(voice))")
        lines.append("File: \(printable(fileName))")
        lines.append("Chapters: " + script.segments.compactMap(\.chapter).map(printable).joined(separator: " | "))
        lines.append("")
        lines += script.text.components(separatedBy: .newlines).map(printable)
        return lines.joined(separator: "\n")
    }

    static func printable(_ text: String) -> String { WebArticle.sanitized(text) }
}
