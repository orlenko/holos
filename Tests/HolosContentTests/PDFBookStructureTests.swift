import AppKit
import Foundation
import HolosTestSupport
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
        do {
            return try PDFBookStructure.paragraphs(pages: pages, markers: markers, outline: outline, bodySize: bodySize,
                                                   hasTitle: hasTitle)
        } catch {
            Issue.record(error)
            return []
        }
    }

    private func marker(_ index: Int) throws -> String { String(try #require(PDFBookStructure.markerScalar(index))) }

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

    // MARK: Notes at the end of the book

    @Test func markersBecomeTheirNotesAfterTheSentenceAndTheNotesSectionIsNotReadAgain() throws {
        let body = "\(Self.filler) It ended here\(try marker(0)) and went on. The next sentence stays together.\(try marker(1))"
        let pages: [PDFBookStructure.Page] = [
            .init(text: body),
            .init(text: "Notes\n1 First note\n2 Second note, which wraps\nonto a second line."),
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
            .init(text: "Notes\n1 Note of the first\nChapter Two\n1 Note of the second"),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1),
                                                                      .init(label: "Notes", page: 2)])
        #expect(result == ["Chapter one says this.", "Footnote: Note of the first.",
                           "Chapter two says that.", "Footnote: Note of the second."])
    }

    /// Some tools give every fifth note's number apart from its line, at the top of the page. It stands at no height
    /// to trust, so the line after a finished note takes it.
    @Test func aNotesNumberGivenApartFromItsLineIsPutBackByOrder() throws {
        let body = try (0..<4).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "3\nNotes\n1 Ibid.\n2 Ibid., wrapping\nonto a line.\nIbid.\n4 Done.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2", "3", "4"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }
            == ["Footnote: Ibid.", "Footnote: Ibid., wrapping onto a line.", "Footnote: Ibid.", "Footnote: Done."])
    }

    /// A wrapped line opening with the next number, in lowercase, stays in its note.
    @Test func aWrappedLineOpeningWithTheNextNumberStaysInItsNote() throws {
        let body = try (0..<2).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let long = "1 A long note that runs on from one margin all the way across the page to the"
        let notes = PDFBookStructure.Page(text: "Notes\n\(long)\n2 that must be read.\n2 The real second.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }.last == "Footnote: The real second.")
    }

    /// A note can start in lowercase, after a finished one; a line inside an open bracket is not a note.
    @Test func lowercaseOpensANoteOnlyAfterAFinishedOne() throws {
        let body = try (0..<3).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "Notes\n1 One says (see p. 3, n.\n2) that this goes on.\n2 ibid., p. 12.\n3 Third.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2", "3"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }
            == ["Footnote: One says (see p. 3, n. 2) that this goes on.", "Footnote: ibid., p. 12.", "Footnote: Third."])
    }

    /// "1 Corinthians" wrapping to a line's start inside a note starts no new block of notes.
    @Test func aLineOpeningWithANumberInsideANoteStaysInIt() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "One.\(try marker(0)) Two.\(try marker(1)) Three.\(try marker(2))"),
            .init(text: "Notes\n1 As it says in\n1 Corinthians, the verse.\n2 Second\n162 pages later.\n3 Third"),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3"], outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }
            == ["Footnote: As it says in 1 Corinthians, the verse.", "Footnote: Second 162 pages later.", "Footnote: Third."])
    }

    /// "1 Corinthians" opening a line after a finished note has no note 2 after it, so it starts no block either.
    @Test func aLineOpeningWithOneNearTheEndOfANoteStartsNoBlock() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "One.\(try marker(0)) Two.\(try marker(1)) Three.\(try marker(2)) Four.\(try marker(3))"),
            .init(text: "Notes\n1 First.\n2 Second, ending here.\n1 Corinthians is cited too.\n3 Third.\n4 Fourth."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3", "4"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == [
            "Footnote: First.", "Footnote: Second, ending here. 1 Corinthians is cited too.", "Footnote: Third.", "Footnote: Fourth.",
        ])
    }

    /// A last chapter with one note that wraps is still a block of its own.
    @Test func aLastChapterWithOneWrappedNoteIsItsOwnBlock() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1))"),
            .init(text: "Last chapter.\(try marker(2))"),
            .init(text: "Notes\n1 Note one.\n2 Note two.\nChapter Two\n1 The only note\nwraps here."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "1"],
                                outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1), .init(label: "Notes", page: 2)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }.last == "Footnote: The only note wraps here.")
    }

    /// An outline naming only the back matter says nothing of chapters: numbers starting over still pair by block.
    @Test func anOutlineWithoutChaptersStillPairsByBlock() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1))"),
            .init(text: "C.\(try marker(2)) D.\(try marker(3))"),
            .init(text: "Notes\n1 Note one.\n2 Note two.\n1 Other one.\n2 Other two."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "1", "2"], outline: [.init(label: "Notes", page: 2)])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: Note one.", "Footnote: Note two.",
                                                                "Footnote: Other one.", "Footnote: Other two."])
    }

    /// A new chapter's first citation need not be its first note.
    @Test func aChapterThatFirstCitesItsSecondNoteStillMovesOn() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1)) C.\(try marker(2))"),
            .init(text: "D.\(try marker(3)) E.\(try marker(4))"),
            .init(text: "Notes\n1 One.\n2 Two.\n3 Three.\nChapter Two\n1 Other one.\n2 Other two.\n3 Other three."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3", "2", "3"],
                                outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1), .init(label: "Notes", page: 2)])
        #expect(Array(result.filter { $0.hasPrefix("Footnote:") }.prefix(5)) == [
            "Footnote: One.", "Footnote: Two.", "Footnote: Three.", "Footnote: Other two.", "Footnote: Other three.",
        ])
        #expect(result.last == "Footnote: Other one.")
    }

    /// A symbol's note in a notes section has no number to pair by, and is still said.
    @Test func aSymbolicNoteInANotesSectionIsNotLost() throws {
        let body = try (0..<3).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "Notes\n* An opening note.\n1 First.\n2 Second.\n3 Third.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2", "3"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.contains("Footnote: An opening note."))
        #expect(result.filter { $0.hasPrefix("Footnote:") }.count == 4)
    }

    /// A symbol's note can wrap, before the numbered notes or after them.
    @Test func aSymbolicNoteKeepsItsWrappedLines() throws {
        let body = try (0..<3).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "Notes\n* An opening note that wraps\nonto another line.\n1 First.\n2 Second.\n3 Third.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2", "3"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.contains("Footnote: An opening note that wraps onto another line."))
        #expect(result.contains("Footnote: First."))
    }

    /// A section inside a chapter is not a new chapter: citing an earlier note there stays in the chapter's notes.
    @Test func aNestedSectionIsNoNewChapter() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1))"),
            .init(text: "Again.\(try marker(2))"),
            .init(text: "Next.\(try marker(3))"),
            .init(text: "Notes\n1 Note one.\n2 Note two.\nChapter Two\n1 Other one.\n2 Other two."),
        ]
        let outline: [PDFBookStructure.OutlineEntry] = [
            .init(label: "One", page: 0), .init(label: "A Section", page: 1, level: 1), .init(label: "Two", page: 2),
            .init(label: "Notes", page: 3),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "1", "1"], outline: outline)
        #expect(Array(result.filter { $0.hasPrefix("Footnote:") }.prefix(4)) == [
            "Footnote: Note one.", "Footnote: Note two.", "Footnote: Note one.", "Footnote: Other one.",
        ])
    }

    /// A note's last line can be short and unpunctuated, right before the numbers start over.
    @Test func aNotesShortLastLineIsNotTakenForAChapterName() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "One.\(try marker(0))"),
            .init(text: "Two.\(try marker(1))"),
            .init(text: "Notes\n1 The first note refers to\npages 25–26\n1 Second note."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1),
                                                                      .init(label: "Notes", page: 2)])
        #expect(result.contains("Footnote: The first note refers to pages 25–26."))
        #expect(result.contains("Footnote: Second note."))
    }

    /// Nor is a capitalized last line, while the note had not ended and nothing names it a part of the book.
    @Test func aNotesCapitalizedLastLineIsKept() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "One.\(try marker(0))"),
            .init(text: "Two.\(try marker(1))"),
            .init(text: "Notes\n1 First note cites\nOxford University Press, 1999\n1 Second chapter note."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1),
                                                                      .init(label: "Notes", page: 2)])
        #expect(result.contains("Footnote: First note cites Oxford University Press, 1999."))
    }

    /// A number missing from the notes does not swallow the note after it.
    @Test func aGapInTheNumberingKeepsTheNoteAfterIt() throws {
        let body = try ["1", "2", "3", "5"].enumerated().map { "Sentence \($1).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "Notes\n1 First.\n2 Second.\n3 Third.\n5 Fifth.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2", "3", "5"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }
            == ["Footnote: First.", "Footnote: Second.", "Footnote: Third.", "Footnote: Fifth."])
    }

    /// A printed page number equal to the next note's is not that note's stray number.
    @Test func aPageNumberIsNotAStrayNoteNumber() throws {
        let body = try (0..<3).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let filler = PDFBookStructure.Page(text: "Words of the page between.")
        let notes = PDFBookStructure.Page(text: "Notes\n1 First.\n2 Second.\nMore about the second.\n3 Third.\n3")
        let result = paragraphs([.init(text: body), filler, notes], markers: ["1", "2", "3"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 2)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }
            == ["Footnote: First.", "Footnote: Second. More about the second.", "Footnote: Third."])
    }

    /// A chapter's first citation can rise past the last one's and still be its own.
    @Test func aChapterFirstCitingTheNextNumberStillMovesOn() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"),
            .init(text: "B.\(try marker(1))"),
            .init(text: "Notes\n1 One.\n2 Two.\nChapter Two\n1 Other one.\n2 Other two."),
        ]
        let result = paragraphs(pages, markers: ["1", "2"], outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1),
                                                                      .init(label: "Notes", page: 2)])
        #expect(result.filter { $0.hasPrefix("Footnote:") }.prefix(2) == ["Footnote: One.", "Footnote: Other two."])
    }

    /// The first chapter with notes uses the first block, however many chapters came before without any.
    @Test func theFirstCitationUsesTheFirstBlock() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "No notes here."), .init(text: "A.\(try marker(0))"), .init(text: "B.\(try marker(1))"),
            .init(text: "Notes\n1 One.\nChapter Two\n1 Other one."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"],
                                outline: [.init(label: "Zero", page: 0), .init(label: "One", page: 1), .init(label: "Two", page: 2),
                                          .init(label: "Notes", page: 3)])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: One.", "Footnote: Other one."])
    }

    /// In a section the outline names as notes, a small number opens its note, in type the size of the body or not.
    @Test func aNotesPagesSmallNumbersAreItsNotes() throws {
        let body = styled([(String(repeating: Self.filler + "\n", count: 4), 10)])
        let notes = styled([("3", 6), (" A note set in the size of the body.\n", 10)])
        let (pages, markers, _) = try PDFReader.bookPages([body, notes], notesPages: [1])
        #expect(markers.isEmpty)
        #expect(pages[1].text == "3 A note set in the size of the body.")
        #expect(PDFBookStructure.namedNotesPages([.init(label: "Body", page: 0), .init(label: "Notes", page: 1), .init(label: "Index", page: 2)],
                                                 pageCount: 3) == [1])
    }

    /// A chapter citing an earlier note again stays in its chapter's notes.
    @Test func citingANoteAgainDoesNotMoveToTheNextChapter() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1)) C again.\(try marker(2))"),
            .init(text: "Next chapter.\(try marker(3))"),
            .init(text: "Notes\n1 Note one.\n2 Note two.\nChapter Two\n1 Other one.\n2 Other two."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "1", "1"],
                                outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1), .init(label: "Notes", page: 2)])
        #expect(Array(result.filter { $0.hasPrefix("Footnote:") }.prefix(4)) == [
            "Footnote: Note one.", "Footnote: Note two.", "Footnote: Note one.", "Footnote: Other one.",
        ])
    }

    /// An outline gives only a page: back matter starting partway down keeps the text above it.
    @Test func aPageSharedWithTheStartOfBackMatterKeepsItsText() {
        let content = [["The chapter's last words.", "Index", "Apples 3"], ["Bears 4", "Cats 5"]]
        let roles = PDFBookStructure.roles(content: content, outline: [.init(label: "Index", page: 0)], hasTitle: true)
        #expect(roles == [.body, .skipped])
    }

    /// Note numbers kept apart from their lines do not hide the heading that opens the page.
    @Test func strayNumbersAboveTheHeadingDoNotHideIt() {
        let content = [["Body."], ["5", "10", "Notes", "1 A note."], ["2 Another."]]
        let roles = PDFBookStructure.roles(content: content, outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)], hasTitle: true)
        #expect(roles == [.body, .notes, .notes])
    }

    /// A stopped reading ends the analysis too.
    @Test func cancellingStopsTheAnalysis() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PDFBookStructure.paragraphs(pages: [.init(text: "Words.")], markers: [], outline: [], bodySize: 10, hasTitle: true)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// A note no marker was found for still gets said.
    @Test func aNoteNoMarkerCitedIsSaidAtTheEnd() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "One.\(try marker(0)) Two.\(try marker(1)) Three.\(try marker(2))"),
            .init(text: "Notes\n1 First.\n2 Second.\n3 Third.\n4 Never cited."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3"], outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.last == "Footnote: Never cited.")
        #expect(result.filter { $0.hasPrefix("Footnote:") }.count == 4)
    }

    /// Notes that cannot be paired stay readable as text, and the numbers still go.
    @Test func notesThatDoNotPairAreReadWhereTheyStand() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "Words.\(try marker(0)) More.\(try marker(1)) Last.\(try marker(2))"),
            .init(text: "Notes\n77 Some note numbered otherwise."),
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

    /// A running footer in the same small type is not the end of the note above it.
    @Test func aSmallRunningFooterStaysOutOfTheNote() throws {
        let pages = try (0..<6).map { index -> PDFBookStructure.Page in
            let note = "1 The note of page \(Character(Unicode.Scalar(97 + UInt8(index))))."
            let footer = "A Book's Running Title"
            return .init(text: "\(Self.filler)\nBody of page \(Character(Unicode.Scalar(97 + UInt8(index)))).\(try marker(index))\n\(note)\n\(footer)",
                         lineSizes: [Self.filler: 10, note: 8, footer: 8])
        }
        let result = paragraphs(pages, markers: Array(repeating: "1", count: 6), bodySize: 10)
        #expect(result.contains("Footnote: The note of page a."))
        #expect(!result.joined().contains("Running Title"))
    }

    /// Small print on the page after a finished note is that page's own, not the note's.
    @Test func smallPrintAfterAFinishedNoteStaysWhereItIs() throws {
        let first = PDFBookStructure.Page(text: "One sentence.\(try marker(0))\n1 A finished note.",
                                          lineSizes: ["1 A finished note.": 8])
        let second = PDFBookStructure.Page(text: "Next sentence.\nA small caption", lineSizes: ["A small caption": 8])
        let result = paragraphs([first, second], markers: ["1"], bodySize: 10)
        #expect(result.contains("Footnote: A finished note."))
        #expect(result.joined(separator: " ").contains("A small caption"))
        #expect(!result.contains { $0.hasPrefix("Footnote:") && $0.contains("caption") })
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

    /// A note can run over a whole page and on to the next.
    @Test func aNoteRunningOverThreePagesStaysWhole() throws {
        let first = PDFBookStructure.Page(text: "One sentence.\(try marker(0))\n1 This note goes",
                                          lineSizes: ["1 This note goes": 8])
        let second = PDFBookStructure.Page(text: "Next sentence.\nright over", lineSizes: ["right over": 8])
        let third = PDFBookStructure.Page(text: "Last sentence.\nthe page and on.", lineSizes: ["the page and on.": 8])
        let result = paragraphs([first, second, third], markers: ["1"], bodySize: 10)
        #expect(result.contains("Footnote: This note goes right over the page and on."))
    }

    /// A page holding nothing but a note's next lines keeps them in the note, and passes it on.
    @Test func aPageAllSmallPrintRunsANoteOn() throws {
        let first = PDFBookStructure.Page(text: "One sentence.\(try marker(0))\n1 This note goes",
                                          lineSizes: ["1 This note goes": 8])
        let second = PDFBookStructure.Page(text: "over this whole page", lineSizes: ["over this whole page": 8])
        let third = PDFBookStructure.Page(text: "Body text.\nand ends here.", lineSizes: ["and ends here.": 8])
        let result = paragraphs([first, second, third], markers: ["1"], bodySize: 10)
        #expect(result.contains("Footnote: This note goes over this whole page and ends here."))
    }

    /// Blank lines between a page's notes do not end them.
    @Test func blankLinesBetweenFootnotesKeepThemAll() throws {
        let page = PDFBookStructure.Page(text: "A.\(try marker(0)) B.\(try marker(1))\n\n1 First note.\n\n2 Second note.",
                                         lineSizes: ["1 First note.": 8, "2 Second note.": 8])
        let result = paragraphs([page], markers: ["1", "2"], bodySize: 10)
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: First note.", "Footnote: Second note."])
    }

    /// A finished footnote on the page before is not the note of the same number here.
    @Test func aFootnoteOfThePageBeforeIsNotReusedForTheSameNumber() throws {
        let first = PDFBookStructure.Page(text: "A.\(try marker(0))\n1 A foot note.", lineSizes: ["1 A foot note.": 8])
        let second = PDFBookStructure.Page(text: "B.\(try marker(1)) C.\(try marker(2))")
        let notes = PDFBookStructure.Page(text: "Notes\n1 An end note.\n2 Another.")
        let result = paragraphs([first, second, notes], markers: ["1", "1", "2"], outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 2)],
                                bodySize: 10)
        #expect(result.filter { $0.hasPrefix("Footnote:") }.prefix(3)
            == ["Footnote: A foot note.", "Footnote: An end note.", "Footnote: Another."])
    }

    /// The last note running over onto the final page stays in the notes.
    @Test func theLastNoteRunningOverStaysInTheNotes() {
        var content: [[String]] = (0..<10).map { ["Prose on page \($0) in plain sentences."] }
        content[8] = ["Notes", "1 One.", "2 Two runs on"]
        content[9] = ["onto the last page."]
        #expect(PDFBookStructure.roles(content: content, outline: [], hasTitle: true)[9] == .notes)
    }

    /// Without an outline, a page all one long note does not end the notes section.
    @Test func aNotesPageWithoutANumberDoesNotEndTheSection() {
        var content: [[String]] = (0..<10).map { ["Prose on page \($0) in plain sentences."] }
        content[6] = ["Notes", "1 One.", "2 Two.", "3 Three runs on"]
        content[7] = ["and on across this page", "with no number at all", "to the end of it"]
        content[8] = ["4 Four.", "5 Five."]
        let roles = PDFBookStructure.roles(content: content, outline: [], hasTitle: true)
        #expect(roles[6] == .notes && roles[7] == .notes && roles[8] == .notes)
        #expect(roles[5] == .body)
    }

    /// A new chapter whose first citation is past the last chapter's moves on as well.
    @Test func aChapterFirstCitingAHigherNumberMovesOn() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1))"),
            .init(text: "C.\(try marker(2))"),
            .init(text: "Notes\n1 One.\n2 Two.\nChapter Two\n1 Other one.\n2 Other two.\n3 Other three."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3"], outline: [.init(label: "One", page: 0), .init(label: "Two", page: 1),
                                                                           .init(label: "Notes", page: 2)])
        #expect(result.contains("Footnote: Other three."))
        #expect(result.firstIndex(of: "Footnote: Other three.")! < result.firstIndex(of: "Footnote: Other one.")!)
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
        let (pages, markers, body) = try PDFReader.bookPages([page])
        #expect(body == 10)
        #expect(markers == ["14", "5"])
        let lines = pages[0].text.components(separatedBy: "\n")
        #expect(lines[0] == "In 1913 he said so\(try marker(0)) and went on, for 20 years.")
        #expect(lines[1] == Self.filler + (try marker(1)))
        #expect(lines[2] == "wrapped to open this line of text.")
    }

    /// A marker wrapped to open a line stays with the sentence before it, even when that one ended a paragraph.
    @Test func aWrappedMarkerFollowsTheSentenceItCites() throws {
        let page = styled([(Self.filler + "\n", 10), ("Sentence ends.\n", 10), ("1", 6), ("Next sentence.\n", 10)])
        let (pages, markers, _) = try PDFReader.bookPages([page])
        #expect(pages[0].text.contains("Sentence ends.\(try marker(0))\nNext sentence."))
        #expect(markers == ["1"])
    }

    /// A marker the file gives as its own line stays with its sentence, which goes on unbroken.
    @Test func aMarkerOnALineOfItsOwnJoinsTheLineBefore() throws {
        let page = styled([(Self.filler + "\n", 10), ("It names The Book,\n", 10), ("3\n", 5.8), ("and then goes on to the end of its sentence.\n", 10)])
        let (pages, markers, _) = try PDFReader.bookPages([page])
        #expect(markers == ["3"])
        let lines = pages[0].text.components(separatedBy: "\n")
        #expect(lines == [Self.filler, "It names The Book,\(try marker(0))", "and then goes on to the end of its sentence."])
    }

    /// A small number alone at the page's end is its page number, which `pageContent` judges, not a marker.
    @Test func aSmallPageNumberIsNotTakenForAMarker() throws {
        let page = styled([(Self.filler + "\n", 10), (Self.filler + "\n", 10), ("1\n", 6)])
        let (pages, markers, _) = try PDFReader.bookPages([page])
        #expect(markers.isEmpty)
        #expect(pages[0].text.hasSuffix("\n1"))
        #expect(!paragraphs(pages, markers: markers).joined(separator: " ").contains(" 1"))
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
        let (pages, markers, _) = try PDFReader.bookPages([page])
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
