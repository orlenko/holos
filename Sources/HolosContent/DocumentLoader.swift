import AppKit
import Foundation
import HolosCore

/// Reads local files into a `ReadableDocument` with built-in macOS APIs only.
public enum DocumentLoader {
    public static let supportedExtensions = [
        "txt", "text", "md", "markdown", "html", "htm", "pdf", "rtf", "rtfd", "docx", "doc", "odt",
    ]

    /// Unknown extensions are read as UTF-8 plain text. Callable from any thread: none of the readers is AppKit's
    /// HTML importer (the one that must run on the main thread), so the app loads files off the main actor. In a
    /// cancelled task a PDF stops between pages with `CancellationError`.
    public static func load(_ url: URL) throws -> ReadableDocument {
        // A FIFO or a device would block the read until a writer comes (a Stop could not end it): refused. A package
        // (an RTFD document) is a folder.
        var metadata = stat()
        if stat(RawFilePath.system(url), &metadata) == 0 {
            let type = metadata.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else {
                throw HolosError.invalidInput("\(url.lastPathComponent) is not a document file.")
            }
        }
        let document: ReadableDocument
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            document = MarkdownReader.document(from: try utf8(url))
        case "html", "htm":
            document = HTMLReader.document(from: try contents(url))
        case "pdf":
            document = try PDFReader.document(url)
        case "rtf": document = try RichTextReader.document(url, type: .rtf)
        case "rtfd": document = try RichTextReader.document(url, type: .rtfd)
        case "docx": document = try RichTextReader.document(url, type: .officeOpenXML)
        case "doc": document = try RichTextReader.document(url, type: .docFormat)
        case "odt": document = try RichTextReader.document(url, type: .openDocument)
        default:
            document = PlainTextReader.document(from: try utf8(url))
        }
        guard !document.isEmpty else {
            throw HolosError.invalidInput("No readable text found in \(url.lastPathComponent).")
        }
        return document
    }

    /// The bytes of the file at `url`, opened without waiting and checked on the descriptor (see `openRegularFile`):
    /// a FIFO put in its place after the check above is refused rather than waited on.
    private static func contents(_ url: URL) throws -> Data {
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    private static func utf8(_ url: URL) throws -> String {
        guard let text = DocumentText.decode(try contents(url)) else {
            throw HolosError.invalidInput("\(url.lastPathComponent) is not UTF-8 text.")
        }
        return text
    }
}
