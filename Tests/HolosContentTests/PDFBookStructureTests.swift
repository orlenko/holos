import AppKit
import Foundation
import HolosTestSupport
import PDFKit
import Testing
@testable import HolosContent

/// Made-up pages for the tests of `PDFBookStructure`.
protocol PDFBookPages {}

extension PDFBookPages {
    /// Text differing on each page by more than a number: a line repeated across pages is furniture.
    static func differentWords(_ count: Int) -> [String] {
        (0..<count).map { String(repeating: "\(Character(Unicode.Scalar(97 + UInt8($0)))) word ", count: 3) + "ends." }
    }

    static var filler: String { "This line of ordinary body text runs on from one margin of the page to the other one." }

    func paragraphs(_ pages: [PDFBookStructure.Page], markers: [String] = [],
                            outline: [PDFBookStructure.OutlineEntry] = [], bodySize: Double = 10,
                            hasTitle: Bool = true) -> [String] {
        do {
            return try PDFBookStructure.paragraphs(pages: pages, markers: markers, outline: outline, bodySize: bodySize,
                                                   hasTitle: hasTitle)
        } catch {
            Issue.record(error)
            return []
        }
    }

    func marker(_ index: Int) throws -> String { String(try #require(PDFBookStructure.markerScalar(index))) }

    func styled(_ runs: [(String, CGFloat)]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, size) in runs {
            result.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)]))
        }
        return result
    }

    func read(_ pages: [NSAttributedString], outline: [PDFBookStructure.OutlineEntry] = []) throws -> [String] {
        let (found, body) = try PDFReader.bookPages(pages)
        return try PDFBookStructure.paragraphs(pages: found, outline: outline, bodySize: body, hasTitle: true)
    }
}

/// Reading a book the way a person would (`PDFBookStructure`), from made-up pages.
@Suite struct PDFBookStructureTests: PDFBookPages {
    // MARK: Parts of the book

    @Test func theOutlineNamesWhatIsNotReadAloud() {
        var content = (0..<8).map { ["Page \($0) words."] }
        content[6] = ["Notes", "1 A note."]
        content[7] = ["Index", "Apples 3"]
        let outline: [PDFBookStructure.OutlineEntry] = [
            .init(label: "Cover", page: 0), .init(label: "Title Page", page: 1), .init(label: "Copyright Page", page: 2),
            .init(label: "Table of Contents", page: 3), .init(label: "Chapter 1 Beginnings", page: 4),
            .init(label: "Notes", page: 6), .init(label: "Index", page: 7),
        ]
        #expect(PDFBookStructure.roles(content: content, outline: outline, hasTitle: true)
            == [.skipped, .skipped, .skipped, .skipped, .body, .body, .notes, .skipped])
    }

    /// A part's chapters are still that part, until the next entry at its depth.
    @Test func chaptersInsideANamedPartInheritItsRole() {
        var content = (0..<7).map { ["Page \($0) words."] }
        content[2] = ["Notes", "1 A note."]
        content[6] = ["Index", "Apples 3"]
        let outline: [PDFBookStructure.OutlineEntry] = [
            .init(label: "Chapter", page: 0), .init(label: "Notes", page: 2),
            .init(label: "Chapter One", page: 3, level: 1), .init(label: "Chapter Two", page: 4, level: 1),
            .init(label: "Afterword", page: 5), .init(label: "Index", page: 6),
        ]
        #expect(PDFBookStructure.roles(content: content, outline: outline, hasTitle: true)
            == [.body, .body, .notes, .notes, .notes, .body, .skipped])
    }

    /// A chapter's own notes, one level down, end with the next chapter.
    @Test func aChildNamingItsOwnPartOverridesTheParent() {
        var content = (0..<4).map { ["Page \($0) words."] }
        content[1] = ["Notes", "1 A note."]
        let outline: [PDFBookStructure.OutlineEntry] = [
            .init(label: "One", page: 0), .init(label: "Notes", page: 1, level: 1), .init(label: "Two", page: 2),
        ]
        #expect(PDFBookStructure.roles(content: content, outline: outline, hasTitle: true) == [.body, .notes, .body, .body])
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

    /// A page about copyright is not a copyright page, and a short document is not silenced by one.
    @Test func proseAboutCopyrightIsRead() {
        var content: [[String]] = (0..<10).map { ["Prose on page \($0) in plain sentences."] }
        content[1] = ["An ISBN does not establish copyright ownership, as this page explains."]
        #expect(PDFBookStructure.roles(content: content, outline: [], hasTitle: true)[1] == .body)
        let short = [["Copyright © 2020 Someone. All rights reserved. ISBN 000-0."]]
        #expect(PDFBookStructure.roles(content: short, outline: [], hasTitle: true) == [.body])
    }

    /// A chapter called Contents in prose is not a table of contents.
    @Test func aPageOpeningWithTheWordContentsIsNotSkippedForThat() {
        var content: [[String]] = (0..<8).map { ["Prose on page \($0)."] }
        content[1] = ["Contents", "A paragraph about what things hold, in ordinary sentences.", "Another one follows it."]
        #expect(PDFBookStructure.roles(content: content, outline: [], hasTitle: true)[1] == .body)
    }

    // MARK: Chapters

    /// A book's chapters are those its outline names, not every line that looks like a heading, and its name stands
    /// for the lines that say it.
    @Test func chaptersComeFromTheOutline() throws {
        let filler = Self.filler
        let pages: [PDFBookStructure.Page] = [
            .init(text: "Foreword\n\(filler) It ends here.\n\nA Subheading\n\n\(filler) It ends too."),
            .init(text: "Chapter 1\nThe Long Name\n\(filler) It goes"),
            .init(text: "on into the next page.\nChapter 2\nThe Other Name\n\(filler) Done."),
        ]
        let outline: [PDFBookStructure.OutlineEntry] = [
            .init(label: "Foreword", page: 0), .init(label: "Chapter 1 The Long Name", page: 1),
            .init(label: "Chapter 2 The Other Name", page: 2),
        ]
        let book = try PDFBookStructure.book(pages: pages, outline: outline, bodySize: 10, hasTitle: true)
        #expect(book.chapters.map(\.label) == outline.map(\.label))
        #expect(!book.paragraphs.joined().unicodeScalars.contains { $0.value >= 0x100000 })
        let document = PDFReader.document(book, declaredTitle: "A Book", author: nil)
        #expect(document.sections.map(\.heading) == outline.map(\.label))
        #expect(document.sections[1].paragraphs.first?.hasPrefix(filler) == true)
        #expect(document.sections[1].paragraphs.joined().contains("It goes on into the next page."))
        #expect(document.sections[0].paragraphs.contains("A Subheading"))
        #expect(!ReadingScript(document: document).text.contains("Chapter 1\n"))
        #expect(document.plainText == ReadingScript(document: document).text)
    }

    /// A chapter's name as long as the lines of text does not run on into them.
    @Test func aLongChapterNameStaysApartFromTheText() throws {
        let name = "Chapter 1 A Name Running To Nearly The Whole Width Of The Page Here Today"
        let body = Self.filler
        let pages: [PDFBookStructure.Page] = [
            .init(text: "Foreword\n\(body) Done."), .init(text: "\(name)\n\(body)\n\(body) Done."),
        ]
        let book = try PDFBookStructure.book(pages: pages, outline: [.init(label: "Foreword", page: 0), .init(label: name, page: 1)],
                                             bodySize: 10, hasTitle: true)
        let document = PDFReader.document(book, declaredTitle: "A Book", author: nil)
        #expect(document.sections[1].heading == name)
        #expect(!ReadingScript(document: document).text.replacingOccurrences(of: name, with: "", options: [.anchored]).contains("\(name) This"))
        #expect(document.sections[1].paragraphs.first?.hasPrefix(body) == true)
    }

    /// With no title in the file, the book's title is told from the one line before its first chapter.
    @Test func aTitleBeforeTheFirstChapterIsStillTheTitle() {
        let book = PDFBookStructure.Book(paragraphs: ["A Book", "Chapter One", "Prose of the chapter."],
                                         chapters: [(1, "Chapter One"), (2, "Chapter Two")])
        #expect(PDFReader.document(book, declaredTitle: nil, author: nil).title == "A Book")
    }

    /// An empty title in the file is no title.
    @Test func anEmptyDeclaredTitleIsNoTitle() {
        let book = PDFBookStructure.Book(paragraphs: ["A Book", "Prose of the first chapter.", "Prose of the second."],
                                         chapters: [(1, "Chapter One"), (2, "Chapter Two")])
        #expect(PDFReader.document(book, declaredTitle: "", author: nil).title == "A Book")
        #expect(PDFReader.document(book, declaredTitle: "  ", author: nil).title == "A Book")
    }

    /// Chapters sharing one page are still chapters, in their order on it.
    @Test func chaptersCanShareAPage() throws {
        let filler = Self.filler
        let page = PDFBookStructure.Page(text: "Chapter 1\n\(filler) Done.\n\nA Subheading\n\n\(filler) Done.\n\nChapter 2\n\(filler) Done.")
        let book = try PDFBookStructure.book(pages: [page], outline: [.init(label: "Chapter 1", page: 0), .init(label: "Chapter 2", page: 0)],
                                             bodySize: 10, hasTitle: true)
        let document = PDFReader.document(book, declaredTitle: "A Book", author: nil)
        #expect(document.sections.map(\.heading) == ["Chapter 1", "Chapter 2"])
        #expect(document.sections[0].paragraphs.contains("A Subheading"))
    }

    /// Headings wrapped over lines are told apart by all of their lines, on one page.
    @Test func wrappedChapterNamesOnOnePageAreToldApart() throws {
        let filler = Self.filler
        let page = PDFBookStructure.Page(text: "Chapter\n1\n\(filler) First.\n\nChapter\n2\n\(filler) Second.")
        let book = try PDFBookStructure.book(pages: [page], outline: [.init(label: "Chapter 1", page: 0), .init(label: "Chapter 2", page: 0)],
                                             bodySize: 10, hasTitle: true)
        let document = PDFReader.document(book, declaredTitle: "A Book", author: nil)
        #expect(document.sections.map(\.heading) == ["Chapter 1", "Chapter 2"])
        #expect(document.sections[0].paragraphs.joined().hasSuffix("First."))
        #expect(document.sections[1].paragraphs.joined().hasSuffix("Second."))
    }

    /// Without chapters named, headings are told by their look, as before.
    @Test func withoutChaptersHeadingsAreToldByTheirLook() throws {
        let filler = Self.filler
        let book = try PDFBookStructure.book(pages: [.init(text: "\(filler) Ends here.\n\nA Heading\n\n\(filler) Done.")], outline: [],
                                             bodySize: 10, hasTitle: true)
        #expect(book.chapters.isEmpty)
        #expect(PDFReader.document(book, declaredTitle: "A Book", author: nil).sections.contains { $0.heading == "A Heading" })
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

    /// Numbered section titles run with their pages but say something different each time: they are headings.
    @Test func numberedSectionTitlesStay() {
        let words = Self.differentWords(4)
        let pages = [["1 Introduction", words[0]], ["2 Methods", words[1]], ["3 Results", words[2]], ["4 Discussion", words[3]]]
        #expect(PDFReader.pageContent(pages) == pages)
    }

    /// A chapter opening on the page it numbers is a heading, however well its number runs with the pages.
    @Test func aChapterHeadingOnItsOwnPageNumberStays() {
        let words = Self.differentWords(8)
        var pages = (0..<8).map { ["Chapter's Name \($0 + 1)", words[$0]] }
        pages[0][0] = "Chapter 1"
        #expect(PDFReader.pageContent(pages)[0] == ["Chapter 1", words[0]])
        #expect(PDFReader.pageContent(pages)[1] == [words[1]])
    }

    /// A page's two edges numbered alike are one page, not two agreeing.
    @Test func twoPagesWithBothEdgesNumberedAreNotFurniture() {
        let pages = [["Exercise 1", "Something to do.", "Answer 1"], ["Exercise 2", "Something else.", "Answer 2"]]
        #expect(PDFReader.pageContent(pages) == pages)
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

    // MARK: From the fonts

    /// Three small numbers in body text, so they are a book's markers; none has a note, so they go silently.
    @Test func smallNumbersAfterTextAreMarkersAndEqualOnesAreNot() throws {
        let page = styled([("In 1913 he said so", 10), ("3", 6), (" and went on, for 20 years.\n", 10),
                           (Self.filler + "\n", 10), ("5", 6), (" wrapped to open this line of text.\n", 10),
                           ("It names The Book,\n", 10), ("14\n", 5.8), ("and goes on to the end of its sentence.\n", 10),
                           (Self.filler + " Done.\n", 10)])
        let text = try read([page]).joined(separator: " ")
        #expect(text.contains("In 1913 he said so and went on, for 20 years."))
        #expect(text.contains("wrapped to open this line of text."))
        #expect(text.contains("It names The Book, and goes on to the end of its sentence."))
        #expect(!text.contains("14") && !text.contains(" 5 ") && !text.contains("said so3"))
    }

    /// A marker wrapped to open a line, or the first line of a page, follows the sentence it cites.
    @Test func aWrappedMarkerFollowsTheSentenceItCitesAcrossAPage() throws {
        let first = styled([(Self.filler + "\n", 10), ("Sentence ends.\n", 10)])
        let second = styled([("1", 6), ("Next sentence.\n", 10), (Self.filler + "\n", 10)])
        let notes = styled([("Notes\n", 10), ("1 The note.\n", 10)])
        let result = try read([first, second, notes], outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 2)])
        let note = try #require(result.firstIndex(of: "Footnote: The note."))
        #expect(note > 0 && result[note - 1].hasSuffix("Sentence ends."))
    }

    /// In a notes section, named or not, a small number opens its note, in type the size of the body or not.
    @Test func aNotesPagesSmallNumbersAreItsNotes() throws {
        var pages = (0..<9).map { index in
            styled([(Self.differentWords(9)[index] + " Prose goes all the way across the page", 10), ("1", 6), (".\n", 10)])
        }
        pages.append(styled([("Notes\n", 14), ("1", 6), (" A note in the size of the body.\n", 10), ("2", 6), (" Another.\n", 10)]))
        let text = try read(pages).joined(separator: " ")
        #expect(text.contains("Footnote: A note in the size of the body."))
    }

    /// A small page number beside a running head is furniture, not a marker.
    @Test func aRunningHeadsSmallPageNumberIsFurniture() throws {
        let pages = (0..<8).map { index in
            styled([("The Chapter's Name ", 10), ("\(index + 1)\n", 6),
                    ("Text of page \(Character(Unicode.Scalar(97 + UInt8(index)))) runs across.\n", 10)])
        }
        #expect(!(try read(pages)).joined(separator: " ").contains("Chapter's Name"))
    }

    /// A small number alone at the page's end is its page number, which `pageContent` judges, not a marker.
    @Test func aSmallPageNumberIsNotTakenForAMarker() throws {
        let text = try read([styled([(Self.filler + "\n", 10), (Self.filler + "\n", 10), ("1\n", 6)])]).joined(separator: " ")
        #expect(!text.contains(" 1"))
    }

    /// A note's small number can stand on its own line above its small text.
    @Test func aFootnotesLabelOnItsOwnLineStaysItsLabel() throws {
        let body = String(repeating: Self.filler + "\n", count: 6)
        let page = styled([(body, 10), ("It is cited", 10), ("1", 6), (" and goes on.\n", 10), ("1\n", 6),
                           ("The footnote is printed here.\n", 8)])
        let (found, size) = try PDFReader.bookPages([page])
        let result = try PDFBookStructure.paragraphs(pages: found, outline: [], bodySize: size, hasTitle: true)
        #expect(result.contains("Footnote: The footnote is printed here."))
    }

    /// A marker moved back to the page before keeps the footnote of the page it was on.
    @Test func aMovedMarkerKeepsItsPagesFootnote() throws {
        let filler = String(repeating: Self.filler + "\n", count: 3)
        let first = styled([(filler, 10), ("A sentence cites one", 10), ("1", 6), (" here. It ends.\n", 10), ("1 The first page's note.\n", 8)])
        let second = styled([("1", 6), ("Then this goes on.\n", 10), (filler, 10), ("1 The second page's note.\n", 8)])
        let third = styled([(filler, 10), ("Last", 10), ("2", 6), (" of all.\n", 10), ("2 The third's.\n", 8)])
        let result = try read([first, second, third])
        #expect(result.contains("Footnote: The second page's note."))
        #expect(result.last != "Footnote: The second page's note.")
    }

    /// A line said twice in other type keeps each time's own small runs.
    @Test func aRepeatedLineKeepsEachTimesRuns() throws {
        let small = styled([("See page ", 10), ("1", 6), ("\n", 10), (Self.filler + "\n", 10), ("See page 1\n", 10),
                            (Self.filler + " Two", 10), ("2", 6), (" and three", 10), ("3", 6), (".\n", 10)])
        let (pages, _) = try PDFReader.bookPages([small])
        #expect(pages[0].smallRuns["See page 1"]?.map(\.count) == [1, 0])
    }

    /// A line wrapped inside a footnote can open with the next number, in lowercase.
    @Test func aWrappedFootnoteLineOpeningWithTheNextNumberStaysInIt() throws {
        let lines = ["1 The sample contains", "2 million entries.", "2 The real second."]
        let page = PDFBookStructure.Page(text: "A.\(try marker(0)) B.\(try marker(1))\n" + lines.joined(separator: "\n"),
                                         lineSizes: Dictionary(uniqueKeysWithValues: lines.map { ($0, 8.0) }))
        let result = paragraphs([page], markers: ["1", "2"], bodySize: 10)
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: The sample contains 2 million entries.", "Footnote: The real second."])
    }

    /// A page using one label twice says both notes.
    @Test func aPageUsingOneLabelTwiceSaysBothNotes() throws {
        let lines = ["1 The first one.", "1 The second one."]
        let page = PDFBookStructure.Page(text: "A.\(try marker(0)) B.\(try marker(1))\n" + lines.joined(separator: "\n"),
                                         lineSizes: Dictionary(uniqueKeysWithValues: lines.map { ($0, 8.0) }))
        let result = paragraphs([page], markers: ["1", "1"], bodySize: 10)
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: The first one.", "Footnote: The second one."])
    }

    /// A footnote whose marker was not found is still said, not merged into the one before.
    @Test func aFootnoteWithoutAFoundMarkerStaysItsOwn() throws {
        let page = PDFBookStructure.Page(text: "A.\(try marker(0))\n1 First note.\n2 Second note.",
                                         lineSizes: ["1 First note.": 8, "2 Second note.": 8])
        let result = paragraphs([page], markers: ["1"], bodySize: 10)
        #expect(result.contains("Footnote: First note."))
        #expect(result.last == "Footnote: Second note.")
    }

    /// Named blocks settle which chapter's notes a citation means, even past a chapter whose citations were not found.
    @Test func aNamedBlockIsFoundPastAChapterWithoutCitations() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "No citations found."), .init(text: "B.\(try marker(1))"),
            .init(text: "Notes\nChapter 1\n1 Of one.\nChapter 2\n1 Of two.\nChapter 3\n1 Of three."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Chapter 1 A Start", page: 0), .init(label: "Chapter 2 A Middle", page: 1),
            .init(label: "Chapter 3 An End", page: 2), .init(label: "Notes", page: 3),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") }.prefix(2) == ["Footnote: Of one.", "Footnote: Of three."])
        #expect(result.last == "Footnote: Of two.")
    }

    /// A chapter's name set larger in the notes still names its block, though it is no part of a note.
    @Test func aLargerChapterNameInTheNotesNamesItsBlock() throws {
        let notes = "Notes\nChapter 1\n1 Of one.\nChapter 2\n1 Of two.\nChapter 3\n1 Of three."
        let sizes = ["Notes": 14.0, "Chapter 1": 12, "Chapter 2": 12, "Chapter 3": 12, "1 Of one.": 9, "1 Of two.": 9, "1 Of three.": 9]
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "No citations found."), .init(text: "B.\(try marker(1))"),
            .init(text: notes, lineSizes: sizes),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Chapter 1 A Start", page: 0), .init(label: "Chapter 2 A Middle", page: 1),
            .init(label: "Chapter 3 An End", page: 2), .init(label: "Notes", page: 3),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") }.prefix(2) == ["Footnote: Of one.", "Footnote: Of three."])
    }

    /// A section inside a chapter belongs to it: the chapter's name finds its block.
    @Test func aSectionInsideAChapterStillFindsTheChaptersBlock() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "No citations found."), .init(text: "Words."), .init(text: "B.\(try marker(1))"),
            .init(text: "Notes\nChapter 1\n1 Of one.\nChapter 2\n1 Of two.\nChapter 3\n1 Of three."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Chapter 1 A Start", page: 0), .init(label: "Chapter 2 A Middle", page: 1),
            .init(label: "Chapter 3 An End", page: 2), .init(label: "A Section", page: 3, level: 1), .init(label: "Notes", page: 4),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") }.prefix(2) == ["Footnote: Of one.", "Footnote: Of three."])
    }

    /// The same file gives the same text: equally frequent sizes tie the same way each time.
    @Test func equallyFrequentSizesTieTheSameWay() throws {
        let page = styled([("Eight points text.\n", 8), ("Ten point text ok.\n", 10)])
        for _ in 0..<20 { #expect(try PDFReader.bookPages([page]).bodySize == 10) }
    }

    /// In a line set small, a small number opening it is that note's own.
    @Test func aSmallNumberOpeningASmallLineIsTheNotesOwn() throws {
        let body = String(repeating: Self.filler + "\n", count: 4)
        let page = styled([(body, 10), ("3", 5), (" The note itself.\n", 8)])
        let (pages, _) = try PDFReader.bookPages([page])
        #expect(pages[0].text.hasSuffix("3 The note itself."))
    }

    /// Small numbers that do not count upward, with no notes anywhere, are text.
    @Test func chemicalSubscriptsStay() throws {
        let page = styled([("Water is H", 10), ("2", 6), ("O and so is more H", 10), ("2", 6), ("O, as H", 10), ("2", 6), ("O says.\n", 10),
                           (Self.filler + "\n", 10)])
        #expect(try read([page]).joined(separator: " ").contains("Water is H2O and so is more H2O"))
    }

    /// A formula beside a book's real notes is still a formula.
    @Test func aFormulaInABookWithNotesStays() throws {
        let body = String(repeating: Self.filler + "\n", count: 3)
        let page = styled([(body, 10), ("It cites one", 10), ("1", 6), (" and goes on.\n", 10), ("Water is H", 10), ("2", 6), ("O and again H", 10), ("2", 6), ("O here.\n", 10),
                           ("1 The note.\n", 8)])
        let text = try read([page]).joined(separator: " ")
        #expect(text.contains("Footnote: The note."))
        #expect(text.contains("again H2O here"))
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

        var separate = ReadableDocument(title: "A Title", sections: [.init(heading: "A Title", level: 1),
                                                                     .init(heading: "Jane Writer", level: 2, paragraphs: ["Words."])])
        separate.insertByline("By Jane Writer")
        #expect(!ReadingScript(document: separate).text.contains("By Jane Writer"))

        var asParagraph = ReadableDocument(title: "Is This A Title?", sections: [.init(paragraphs: ["Is This A Title?", "Words."])])
        asParagraph.insertByline("By Jane Writer")
        #expect(ReadingScript(document: asParagraph).text == "Is This A Title?\n\nBy Jane Writer\n\nWords.")

        var said = ReadableDocument(title: "A Title", sections: [.init(paragraphs: ["Jane Writer", "Words."])])
        said.insertByline("By Jane Writer")
        #expect(said.sections[0].paragraphs == ["Jane Writer", "Words."])
    }

    // MARK: A real file

    /// A made-up book in a real PDF: its outline, fonts and notes, through `DocumentLoader`.
    @MainActor @Test func aWholeBookReadsLikeOne() throws {
        let temporary = try TemporaryDirectory("book")
        defer { temporary.remove() }
        let url = temporary.url.appendingPathComponent("book.pdf")
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
        // The title, then the author once: by the file's details, or from the title page where that stays.
        #expect(text.hasPrefix("A Made-Up Book\n\n"))
        #expect(text.components(separatedBy: "Jane Writer").count == 2)
        #expect(text.prefix(40).contains("Jane Writer"))
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
