import Foundation
import HolosSynthesis

/// What `voiceislocal read --print-text` prints, for a local file and a web page alike: the title,
/// author, language, voice, the file the command would write (`ReadingOutput.previewPath`), and
/// the chapters that file would get, a blank line, then the text as it is read.
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
        let chapters = self.chapters(script: script, metadata: metadata)
        lines.append("Chapters: " + (chapters.isEmpty ? "none" : chapters.map(printable).joined(separator: " | ")))
        lines.append("")
        lines += script.text.components(separatedBy: .newlines).map(printable)
        return lines.joined(separator: "\n")
    }

    /// The chapters the finished file gets: the part plan `ReadingPipeline` renders, through the
    /// rules `AudioBookWriter` encodes with (see `AudioBookChapterPlan`).
    static func chapters(script: ReadingScript, metadata: AudioBookMetadata,
                         maxPartUTF16Units: Int = ReadingPipeline.defaultMaxPartUTF16Units) -> [String] {
        AudioBookChapterPlan.titles(script.parts(maxUTF16Units: maxPartUTF16Units).map(\.chapter),
                                    bookTitle: metadata.title)
    }

    static func printable(_ text: String) -> String { WebArticle.sanitized(text) }
}
