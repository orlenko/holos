import Foundation

/// What a reading reads: an `https` web page, or a local document `DocumentLoader` reads.
public enum ReadingSource: Codable, Sendable, Equatable {
    case web(URL)
    case file(URL)

    /// The list's second line: the site ("nytimes.com", without "www.") or the file's name.
    public var label: String {
        switch self {
        case .web(let url):
            let host = url.host() ?? url.absoluteString
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        case .file(let url):
            return url.lastPathComponent
        }
    }

    /// The name the file gets when the document has no title: the site, or the file's name without its extension.
    public var fallbackName: String {
        switch self {
        case .web: label
        case .file(let url): url.deletingPathExtension().lastPathComponent
        }
    }

    /// As the New Reading field shows it: the address, or the file's path with "~" for the home folder.
    public var fieldText: String {
        switch self {
        case .web(let url): url.absoluteString
        case .file(let url): (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Why something typed, pasted, or dropped cannot be read, in a sentence for the New Reading card.
public struct ReadingSourceProblem: Error, Sendable, Equatable {
    public let message: String

    public init(_ message: String) { self.message = message }
}

/// Turns what the user typed, pasted, dropped, or chose into sources to read (docs/design.md "Reading section").
public enum ReadingSourceParser {
    public static let kinds = "a PDF, Word, HTML, Markdown, RTF, OpenDocument, or text file"
    /// Document formats `DocumentLoader` reads that are saved as packages (folders).
    static let packageExtensions: Set<String> = ["rtfd"]

    /// One source from the New Reading field: an `https://` address (a bare "example.com/page" gets `https://`), a
    /// `file://` URL, or a file path (absolute, or starting with "~"). `http://` is refused with a hint, as in
    /// `voiceislocal read`.
    public static func parse(_ text: String, isDirectory: (String) -> Bool? = Self.directoryCheck)
        -> Result<ReadingSource, ReadingSourceProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ReadingSourceProblem("Paste a link, or choose a file to read.")) }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("http://") {
            return .failure(ReadingSourceProblem("Only https:// links can be read. Try the https:// form of the link."))
        }
        if lowered.hasPrefix("https://") { return web(trimmed) }
        if lowered.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else {
                return .failure(ReadingSourceProblem("Not a file address: \(trimmed)"))
            }
            return file(url, isDirectory: isDirectory)
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let path = (trimmed as NSString).expandingTildeInPath
            return file(URL(fileURLWithPath: path), isDirectory: isDirectory)
        }
        if looksLikeAddress(trimmed) { return web("https://" + trimmed) }
        return .failure(ReadingSourceProblem("Not a link or a file: “\(trimmed)”. Paste an https:// link, or choose \(kinds)."))
    }

    /// The sources in a drop or a paste, from what the pasteboard offered: file URLs (each one a source), else web
    /// URLs, else text (each non-empty line parsed as the field would). Items that cannot be read are listed in
    /// `problems`, so a drop of three files with one folder among them still reads the other two.
    public static func sources(fileURLs: [URL], urls: [URL], strings: [String],
                               isDirectory: (String) -> Bool? = Self.directoryCheck)
        -> (sources: [ReadingSource], problems: [ReadingSourceProblem]) {
        var sources: [ReadingSource] = [], problems: [ReadingSourceProblem] = []
        func add(_ result: Result<ReadingSource, ReadingSourceProblem>) {
            switch result {
            case .success(let source): if !sources.contains(source) { sources.append(source) }
            case .failure(let problem): problems.append(problem)
            }
        }
        let files = fileURLs.filter(\.isFileURL)
        if !files.isEmpty {
            files.forEach { add(file($0, isDirectory: isDirectory)) }
        } else if !urls.filter({ !$0.isFileURL }).isEmpty {
            urls.filter { !$0.isFileURL }.forEach { add(parse($0.absoluteString, isDirectory: isDirectory)) }
        } else {
            for line in strings.flatMap({ $0.components(separatedBy: .newlines) })
            where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                add(parse(line, isDirectory: isDirectory))
            }
        }
        return (sources, problems)
    }

    /// Whether `path` is a folder; nil when nothing is there.
    public static func directoryCheck(_ path: String) -> Bool? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue
    }

    private static func web(_ text: String) -> Result<ReadingSource, ReadingSourceProblem> {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty,
              host.contains(".") || host == "localhost" else {
            return .failure(ReadingSourceProblem("Not a valid web address: \(text)"))
        }
        return .success(.web(url))
    }

    private static func file(_ url: URL, isDirectory: (String) -> Bool?) -> Result<ReadingSource, ReadingSourceProblem> {
        let url = url.standardizedFileURL
        switch isDirectory(url.path) {
        case nil:
            return .failure(ReadingSourceProblem("No file at \((url.path as NSString).abbreviatingWithTildeInPath)."))
        case true? where packageExtensions.contains(url.pathExtension.lowercased()):
            // An RTFD document is a package: a folder that Finder shows as one file.
            return .success(.file(url))
        case true?:
            return .failure(ReadingSourceProblem("\(url.lastPathComponent) is a folder. Choose \(kinds)."))
        case false?:
            guard DocumentLoader.supportedExtensions.contains(url.pathExtension.lowercased()) else {
                return .failure(ReadingSourceProblem("\(url.lastPathComponent) cannot be read. Choose \(kinds)."))
            }
            return .success(.file(url))
        }
    }

    /// "example.com/page", "www.site.org": a host with a dot and letters in its last label, no spaces.
    static func looksLikeAddress(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), !text.contains("@") else { return false }
        let host = text.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              labels.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }),
              let last = labels.last, last.count >= 2, last.allSatisfy(\.isLetter) else { return false }
        // "notes.md" is a file name typed without its folder, not a site.
        return host.count != text.count || !DocumentLoader.supportedExtensions.contains(last.lowercased())
    }
}
