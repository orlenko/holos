import Foundation
import Testing
@testable import HolosContent

@Suite struct ReadingSourceTests {
    /// A pretend disk: these paths are files, these are folders, nothing else exists.
    private let files: Set<String> = ["/Users/me/Downloads/Paper.pdf", "/Users/me/notes.md", "/Users/me/photo.png",
                                      "/Users/me/Letter.docx"]
    private let folders: Set<String> = ["/Users/me/Downloads", "/Users/me/Notes.rtfd", "/Users/me/Album.app"]

    private func disk(_ path: String) -> Bool? {
        folders.contains(path) ? true : files.contains(path) ? false : nil
    }

    private func parse(_ text: String) -> Result<ReadingSource, ReadingSourceProblem> {
        ReadingSourceParser.parse(text, isDirectory: disk)
    }

    private func message(_ result: Result<ReadingSource, ReadingSourceProblem>) -> String? {
        if case .failure(let problem) = result { return problem.message }
        return nil
    }

    @Test func linksAreHTTPSOnly() throws {
        #expect(try parse("  https://www.example.com/a/story?x=1 \n").get()
                == .web(URL(string: "https://www.example.com/a/story?x=1")!))
        #expect(message(parse("http://example.com/story"))?.contains("https://") == true)
        #expect(try parse("example.com/story").get() == .web(URL(string: "https://example.com/story")!))
        #expect(try parse("www.lemonde.fr").get() == .web(URL(string: "https://www.lemonde.fr")!))
        #expect(message(parse("https://")) != nil)
        #expect(message(parse("")) != nil)
        #expect(message(parse("just some words")) != nil)
        #expect(message(parse("me@example.com")) != nil)
        // A bare file name is not a site.
        #expect(message(parse("notes.md")) != nil)
    }

    @Test func filesArePathsOrFileURLsOfDocumentsThatExist() throws {
        #expect(try parse("/Users/me/Downloads/Paper.pdf").get() == .file(URL(fileURLWithPath: "/Users/me/Downloads/Paper.pdf")))
        #expect(try parse("file:///Users/me/Letter.docx").get() == .file(URL(fileURLWithPath: "/Users/me/Letter.docx")))
        #expect(message(parse("/Users/me/Downloads"))?.contains("folder") == true)
        // An RTFD document is a package (a folder); other packages are refused like folders.
        #expect(try parse("/Users/me/Notes.rtfd").get() == .file(URL(fileURLWithPath: "/Users/me/Notes.rtfd")))
        #expect(message(parse("/Users/me/Album.app"))?.contains("folder") == true)
        #expect(message(parse("/Users/me/photo.png"))?.contains("cannot be read") == true)
        #expect(message(parse("/Users/me/missing.pdf"))?.contains("No file") == true)
        let home = NSHomeDirectory()
        let expanded = ReadingSourceParser.parse("~/Paper.pdf") { $0 == home + "/Paper.pdf" ? false : nil }
        #expect(try expanded.get() == .file(URL(fileURLWithPath: home + "/Paper.pdf")))
    }

    @Test func dropsPreferFilesThenLinksThenText() {
        let pdf = URL(fileURLWithPath: "/Users/me/Downloads/Paper.pdf")
        let md = URL(fileURLWithPath: "/Users/me/notes.md")
        let png = URL(fileURLWithPath: "/Users/me/photo.png")
        let web = URL(string: "https://example.com/story")!
        // Files: each one, in order, without repeats; the ones that cannot be read are reported.
        let files = ReadingSourceParser.sources(fileURLs: [pdf, png, md, pdf], urls: [pdf, web],
                                                strings: ["https://other.example"], isDirectory: disk)
        #expect(files.sources == [.file(pdf), .file(md)])
        #expect(files.problems.count == 1)
        // A link dragged from a browser (it also offers its title as text).
        let link = ReadingSourceParser.sources(fileURLs: [], urls: [web], strings: ["The Story"], isDirectory: disk)
        #expect(link.sources == [.web(web)])
        #expect(link.problems.isEmpty)
        // Text: each line.
        let text = ReadingSourceParser.sources(fileURLs: [], urls: [],
                                               strings: ["https://a.example/1\n\nhttp://b.example/2\n/Users/me/notes.md"],
                                               isDirectory: disk)
        #expect(text.sources == [.web(URL(string: "https://a.example/1")!), .file(md)])
        #expect(text.problems.count == 1)
        #expect(ReadingSourceParser.sources(fileURLs: [], urls: [], strings: [], isDirectory: disk).sources.isEmpty)
    }

    @Test func labelsNameTheSiteOrTheFile() {
        #expect(ReadingSource.web(URL(string: "https://www.nytimes.com/2026/story.html")!).label == "nytimes.com")
        #expect(ReadingSource.web(URL(string: "https://blog.example.org/")!).fallbackName == "blog.example.org")
        let file = ReadingSource.file(URL(fileURLWithPath: "/Users/me/Downloads/Paper.pdf"))
        #expect(file.label == "Paper.pdf")
        #expect(file.fallbackName == "Paper")
    }

    @Test func sourcesRoundTripThroughJSON() throws {
        for source in [ReadingSource.web(URL(string: "https://example.com/a")!),
                       .file(URL(fileURLWithPath: "/Users/me/Café notes.md"))] {
            let data = try JSONEncoder().encode(source)
            #expect(try JSONDecoder().decode(ReadingSource.self, from: data) == source)
        }
    }
}
