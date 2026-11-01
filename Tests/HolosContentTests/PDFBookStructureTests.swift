import AppKit
import Foundation
import PDFKit
import Testing
@testable import HolosContent

/// Reading a book the way a person would (`PDFBookStructure`), from made-up pages.
@Suite struct PDFBookStructureTests {
    /// Text differing on each page by more than a number: a line repeated across pages is furniture.
    private static func differentWords(_ count: Int) -> [String] {
        (0..<count).map { String(repeating: "\(Character(Unicode.Scalar(97 + UInt8($0)))) word ", count: 3) + "ends." }
    }

    private static let filler = "This line of ordinary body text runs on from one margin of the page to the other one."

    private func paragraphs(_ pages: [PDFBookStructure.Page], markers: [String] = [],
                            outline: [PDFBookStructure.OutlineEntry] = [], bodySize: Double = 10,
                            hasTitle: Bool = true) -> [String] {
        PDFBookStructure.paragraphs(pages: pages, markers: markers, outline: outline, bodySize: bodySize, hasTitle: hasTitle)
    }

    private func marker(_ index: Int) throws -> String { String(try #require(PDFBookStructure.markerScalar(index))) }

    // MARK: Parts of the book

    @Test func theOutlineNamesWhatIsNotReadAloud() {
        let content = (0..<8).map { ["Page \($0) words."] }
        let outline: [PDFBookStructure.OutlineEntry] = [
            .init(label: "Cover", page: 0), .init(label: "Title Page", page: 1), .init(label: "Copyright Page", page: 2),
            .init(label: "Table of Contents", page: 3), .init(label: "Chapter 1 Beginnings", page: 4),
            .init(label: "Notes", page: 6), .init(label: "Index", page: 7),
        ]
        #expect(PDFBookStructure.roles(content: content, outline: outline, hasTitle: true)
            == [.skipped, .skipped, .skipped, .skipped, .body, .body, .notes, .skipped])
    }

    /// With no title in the file's details, the title page is where the title is said.
    @Test func aTitlePageIsReadWhenTheFileNamesNoTitle() {
        let roles = PDFBookStructure.roles(content: [["A"], ["B"], ["C"]], outline: [.init(label: "Title Page", page: 0),
                                                                                    .init(label: "One", page: 1)], hasTitle: false)
        #expect(roles == [.body, .body, .body])
    }

    @Test func anOutlineNamingNearlyEverythingSilencesNothing() {
        let content = (0..<5).map { ["Page \($0) words."] }
        let roles = PDFBookStructure.roles(content: content, outline: [.init(label: "Contents", page: 0)], hasTitle: true)
        #expect(roles == [.body, .body, .body, .body, .body])
    }

    @Test func withoutAnOutlineTheContentsAndIndexAreRecognized() {
        var content: [[String]] = (0..<12).map { ["Body text on page \($0) that is only prose and has no list in it."] }
        content[1] = ["Contents", "Introduction 1", "A First Chapter 5", "A Second Chapter 22", "Afterword 90"]
        content[2] = ["A Third Chapter 40", "A Fourth Chapter 60", "Notes 95"]
        content[3] = ["Copyright © 2020 Someone.", "All rights reserved.", "ISBN 000-0-00-000000-0"]
        content[10] = ["Index", "Apples 3, 7", "Bears 12", "Cats 40"]
        content[11] = ["Dogs 3", "Eels 44", "Foxes 90"]
        let roles = PDFBookStructure.roles(content: content, outline: [], hasTitle: true)
        #expect(roles[1] == .skipped && roles[2] == .skipped && roles[3] == .skipped)
        #expect(roles[10] == .skipped && roles[11] == .skipped)
        #expect(roles[0] == .body && roles[4] == .body && roles[9] == .body)
    }

    /// A chapter called Contents in prose is not a table of contents.
    @Test func aPageOpeningWithTheWordContentsIsNotSkippedForThat() {
        var content: [[String]] = (0..<8).map { ["Prose on page \($0)."] }
        content[1] = ["Contents", "A paragraph about what things hold, in ordinary sentences.", "Another one follows it."]
        #expect(PDFBookStructure.roles(content: content, outline: [], hasTitle: true)[1] == .body)
    }

    // MARK: Page numbers

    @Test func aChaptersOwnRunningHeadWithItsPageNumberIsDropped() {
        let words = Self.differentWords(20)
        let pages = (0..<20).map { index -> [String] in
            let head = index % 2 == 0 ? "\(index + 1) The Chapter's Name" : "The Chapter's Name \(index + 1)"
            return [head, words[index]]
        }
        #expect(PDFReader.pageContent(pages) == words.map { [$0] })
    }

    @Test func romanNumberedRunningHeadsAreDropped() {
        let words = Self.differentWords(6)
        let pages = ["iii", "iv", "v", "vi", "vii", "viii"].enumerated().map { ["Foreword \($1)", words[$0]] }
        #expect(PDFReader.pageContent(pages) == words.map { [$0] })
    }

    /// A line that merely ends in a number, on a few pages out of step with them, is text.
    @Test func edgeLinesEndingInUnrelatedNumbersStay() {
        let words = Self.differentWords(4)
        let pages = [["In the year 1984", words[0]], ["He was 12", words[1]], [words[2], "Room 7"], ["Chapter 40", words[3]]]
        #expect(PDFReader.pageContent(pages) == pages)
    }

    // MARK: Notes at the end of the book

    @Test func markersBecomeTheirNotesAfterTheSentenceAndTheNotesSectionIsNotReadAgain() throws {
        let body = "\(Self.filler) It ended here\(try marker(0)) and went on. The next sentence stays together.\(try marker(1))"
        let pages: [PDFBookStructure.Page] = [
            .init(text: body),
            .init(text: "1 First note\n2 Second note, which wraps\nonto a second line."),
        ]
        let result = paragraphs(pages, markers: ["1", "2"], outline: [.init(label: "Chapter", page: 0), .init(label: "Notes", page: 1)])
        #expect(result == ["\(Self.filler) It ended here and went on.",
                           "Footnote: First note.",
                           "The next sentence stays together.",
                           "Footnote: Second note, which wraps onto a second line."])
    }

    @Test func numberingThatStartsOverPairsChapterByChapter() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "Chapter one says this.\(try marker(0))"),
            .init(text: "Chapter two says that.\(try marker(1))"),
            .init(text: "1 Note of the first\nChapter Two\n1 Note of the second"),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [.init(label: "One", page: 0), .init(label: "Notes", page: 2)])
        #expect(result == ["Chapter one says this.", "Footnote: Note of the first.",
                           "Chapter two says that.", "Footnote: Note of the second."])
    }

    /// Some tools give every fifth note's number apart from its line, at the top of the page.
    @Test func aNotesNumberGivenApartFromItsLineIsPutBack() throws {
        let body = (0..<3).map { "Sentence number \($0).\((try? marker($0)) ?? "")" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "3\n1 One\n2 Two\nThree", lineLevels: ["3": 100, "1 One": 140, "2 Two": 120, "Three": 100])
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2", "3"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: One.", "Footnote: Two.", "Footnote: Three."])
    }

    /// "1 Corinthians" wrapping to a line's start inside a note starts no new block of notes.
    @Test func aLineOpeningWithANumberInsideANoteStaysInIt() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "One.\(try marker(0)) Two.\(try marker(1)) Three.\(try marker(2))"),
            .init(text: "1 As it says in\n1 Corinthians, the verse.\n2 Second\n162 pages later.\n3 Third"),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3"], outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }
            == ["Footnote: As it says in 1 Corinthians, the verse.", "Footnote: Second 162 pages later.", "Footnote: Third."])
    }

    /// Notes that cannot be paired stay readable as text, and the numbers still go.
    @Test func notesThatDoNotPairAreReadWhereTheyStand() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "Words.\(try marker(0)) More.\(try marker(1)) Last.\(try marker(2))"),
            .init(text: "77 Some note numbered otherwise."),
        ]
        let result = paragraphs(pages, markers: ["7", "8", "9"], outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.contains("Words. More. Last."))
        #expect(result.contains { $0.contains("Some note") })
        #expect(!result.contains { $0.hasPrefix("Footnote:") })
    }

    // MARK: Notes at the foot of a page

    @Test func aPagesFootnotesLeaveTheTextAndFollowTheirSentence() throws {
        let first = "1 The note begins"
        let page = PDFBookStructure.Page(text: "\(Self.filler)\nIt is cited here.\(try marker(0)) Then more.\n\(first)\nand wraps to the next line.\n1",
                                         lineSizes: [Self.filler: 10, first: 8, "and wraps to the next line.": 8])
        let result = paragraphs([page], markers: ["1"], bodySize: 10)
        let footnote = "Footnote: The note begins and wraps to the next line."
        #expect(result.contains(footnote))
        #expect(!result.joined().contains("The note begins and wraps to the next line. Then"))
        #expect(result.first { $0.contains("cited here") }?.hasSuffix("It is cited here.") == true)
        #expect(result.last == "Then more.")
    }

    @Test func smallPrintWithNoMarkerOnThePageIsNotAFootnote() {
        let page = PDFBookStructure.Page(text: "A sentence of the book.\n4 A caption in small type.",
                                         lineSizes: ["A sentence of the book.": 10, "4 A caption in small type.": 8])
        #expect(paragraphs([page], bodySize: 10).joined(separator: " ").contains("4 A caption"))
    }

    @Test func aNoteRunningOverToTheNextPageStaysWhole() throws {
        let first = PDFBookStructure.Page(text: "One sentence.\(try marker(0))\n1 This note goes",
                                          lineSizes: ["1 This note goes": 8])
        let second = PDFBookStructure.Page(text: "Next sentence.\nover the page.", lineSizes: ["over the page.": 8])
        let result = paragraphs([first, second], markers: ["1"], bodySize: 10)
        #expect(result.contains("Footnote: This note goes over the page."))
        #expect(!result.contains { $0 == "over the page." })
    }

    /// Too few small numbers to be a book's notes: an exponent is text.
    @Test func aLoneSmallNumberWithoutANoteStays() throws {
        let result = paragraphs([.init(text: "The area is ten\(try marker(0)) metres.")], markers: ["2"])
        #expect(result == ["The area is ten2 metres."])
    }

    @Test func aMarkerWithoutANoteInABookGoesSilently() throws {
        let text = "One\(try marker(0)) two\(try marker(1)) three\(try marker(2)) four."
        #expect(paragraphs([.init(text: text)], markers: ["1", "2", "3"]) == ["One two three four."])
    }

    // MARK: From the fonts

    private func styled(_ runs: [(String, CGFloat)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, size) in runs {
            result.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
        }
        return result
    }

    @Test func aSmallNumberAfterTextIsAMarkerAndAnEqualOneIsNot() throws {
        let page = styled([("In 1913 he said so", 10), ("14", 6), (" and went on, for 20 years.\n", 10),
                           (Self.filler + "\n", 10), ("5", 6), (" wrapped to open this line of text.\n", 10)])
        let (pages, markers, body) = PDFReader.bookPages([page])
        #expect(body == 10)
        #expect(markers == ["14", "5"])
        let lines = pages[0].text.components(separatedBy: "\n")
        #expect(lines[0] == "In 1913 he said so\(try marker(0)) and went on, for 20 years.")
        #expect(lines[2] == "\(try marker(1))wrapped to open this line of text.")
    }

    /// In a line set small, a small number opening it is that note's own.
    @Test func aSmallNumberOpeningASmallLineIsTheNotesOwn() {
        let body = String(repeating: Self.filler + "\n", count: 4)
        let page = styled([(body, 10), ("3", 5), (" The note itself.\n", 8)])
        let (pages, markers, _) = PDFReader.bookPages([page])
        #expect(markers.isEmpty)
        #expect(pages[0].text.hasSuffix("3 The note itself."))
    }

    // MARK: The author

    @Test func theAuthorIsSaidOnlyWhenTheBookPrintsTheName() {
        let pages = ["A Title", "A Title\nJane Q. Writer\nA Publisher"]
        #expect(PDFBookStructure.byline(author: "Jane Q. Writer", pages: pages) == "By Jane Q. Writer")
        #expect(PDFBookStructure.byline(author: "macuser", pages: pages) == nil)
        #expect(PDFBookStructure.byline(author: "OceanofPDF.com", pages: ["OceanofPDF.com"]) == nil)
        #expect(PDFBookStructure.byline(author: "", pages: pages) == nil)
        #expect(PDFBookStructure.byline(author: nil, pages: pages) == nil)
    }

    @Test func theBylineFollowsTheTitleOnceAndTheShownTextIsWhatIsSpoken() {
        var document = ReadableDocument(title: "A Title", sections: [.init(heading: "One", level: 2, paragraphs: ["Words."])])
        document.insertByline("By Jane Writer")
        #expect(ReadingScript(document: document).text.hasPrefix("A Title\n\nBy Jane Writer\n\nOne"))
        #expect(document.plainText == ReadingScript(document: document).text)

        var opening = ReadableDocument(title: "A Title", sections: [.init(heading: "A Title", level: 1, paragraphs: ["Words."])])
        opening.insertByline("By Jane Writer")
        #expect(opening.sections[0].paragraphs == ["By Jane Writer", "Words."])

        var said = ReadableDocument(title: "A Title", sections: [.init(paragraphs: ["Jane Writer", "Words."])])
        said.insertByline("By Jane Writer")
        #expect(said.sections[0].paragraphs == ["Jane Writer", "Words."])
    }

    // MARK: A real file

    /// A made-up book in a real PDF: its outline, fonts and notes, through `DocumentLoader`.
    @MainActor @Test func aWholeBookReadsLikeOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) } }
        let url = folder.appendingPathComponent("book.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let info = [kCGPDFContextTitle as String: "A Made-Up Book", kCGPDFContextAuthor as String: "Jane Writer"] as CFDictionary
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info))
        func page(_ lines: [[(String, CGFloat)]]) {
            context.beginPDFPage(nil)
            for (index, runs) in lines.enumerated() {
                let line = CTLineCreateWithAttributedString(styled(runs))
                context.textPosition = CGPoint(x: 72, y: 720 - CGFloat(index) * 16)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        page([[("A Made-Up Book", 18)], [("Jane Writer", 12)]])
        page([[("Contents", 16)], [("The Only Chapter 3", 10)], [("Notes 9", 10)]])
        let prose = "The chapter runs from one margin of the page right across to the far margin."
        page([[("The Only Chapter 3", 8)], [(prose, 10)], [(prose, 10)], [("It says one thing", 10), ("1", 6), (" and then another.", 10)], [(prose + " End.", 10)]])
        page([[("4 The Only Chapter", 8)], [(prose, 10)], [(prose, 10)], [("It says more", 10), ("2", 6), (".", 10)]])
        page([[("The Only Chapter 5", 8)], [(prose, 10)], [(prose, 10)], [("Near the end", 10), ("3", 6), (".", 10)]])
        page([[("6 The Only Chapter", 8)], [(prose, 10)], [(prose + " Done.", 10)]])
        page([[("Notes", 16)], [("1 The first note.", 9)], [("2 The second note.", 9)], [("3 The third note.", 9)]])
        page([[("Index", 16)], [("Apples 3", 9)], [("Bears 4", 9)]])
        context.closePDF()

        let source = try #require(PDFDocument(url: url))
        let root = PDFOutline()
        for (index, entry) in [("Title Page", 0), ("Contents", 1), ("The Only Chapter", 2), ("Notes", 6), ("Index", 7)].enumerated() {
            let item = PDFOutline()
            item.label = entry.0
            let target = try #require(source.page(at: entry.1))
            item.destination = PDFDestination(page: target, at: CGPoint(x: 0, y: 700))
            root.insertChild(item, at: index)
        }
        source.outlineRoot = root
        #expect(source.write(to: url))

        let document = try DocumentLoader.load(url)
        let text = ReadingScript(document: document).text
        #expect(text.hasPrefix("A Made-Up Book\n\nBy Jane Writer"))
        for gone in ["Contents", "Apples", "Bears", "The Only Chapter 3", "4 The Only", "Notes"] {
            #expect(!text.contains(gone), "\(gone) is read")
        }
        #expect(text.contains("It says one thing and then another."))
        #expect(!text.contains("thing1"))
        for note in ["Footnote: The first note.", "Footnote: The second note.", "Footnote: The third note."] {
            #expect(text.components(separatedBy: note).count == 2, "\(note) is not read once")
        }
        #expect(text.range(of: "another.")!.lowerBound < text.range(of: "Footnote: The first note.")!.lowerBound)
    }
}
