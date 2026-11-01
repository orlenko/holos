import Foundation
import Testing
@testable import HolosContent

/// How notes in a notes section pair with their citations (`PDFBookStructure`).
@Suite struct PDFBookNotesTests: PDFBookPages {
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

    /// A chapter name set larger starts a block, however long that block's first note runs.
    @Test func aLargerChapterNameNeedsNoNoteTwoNearby() throws {
        let wrapped = (0..<45).map { "line number \($0) of a very long note" }
        var sizes: [String: Double] = ["Notes": 14, "Chapter 2": 12, "1 Of one.": 9, "1 Of two begins": 9]
        for line in wrapped { sizes[line] = 9 }
        let text = (["Notes", "1 Of one.", "Chapter 2", "1 Of two begins"] + wrapped).joined(separator: "\n")
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "B.\(try marker(1))"), .init(text: text, lineSizes: sizes),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Chapter 1", page: 0), .init(label: "Chapter 2", page: 1), .init(label: "Notes", page: 2),
        ])
        #expect(result.contains("Footnote: Of one."))
        #expect(result.contains { $0.hasPrefix("Footnote: Of two begins") })
    }

    /// Chapters named inside Notes are not the book's chapters.
    @Test func chaptersInsideNotesAreNotTheBooksChapters() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "B.\(try marker(1))"),
            .init(text: "Notes\nChapter 1\n1 Of one."), .init(text: "Chapter 2\n1 Of two."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "A Start", page: 0), .init(label: "A Middle", page: 1), .init(label: "Notes", page: 2),
            .init(label: "Chapter 1", page: 2, level: 1), .init(label: "Chapter 2", page: 3, level: 1),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: Of one.", "Footnote: Of two."])
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

    /// Without chapters to go by, citing an earlier note again stays in this block while it has notes left.
    @Test func withoutChaptersARepeatedCitationStaysWhileNotesAreLeft() throws {
        let body = try ["1", "2", "1", "3"].enumerated().map { "Sentence \($1).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "Notes\n1 One.\n2 Two.\n3 Three.\n1 Other one.\n2 Other two.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "2", "1", "3"], outline: [.init(label: "Notes", page: 1)])
        #expect(Array(result.filter { $0.hasPrefix("Footnote:") }.prefix(4))
            == ["Footnote: One.", "Footnote: Two.", "Footnote: One.", "Footnote: Three."])
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

    /// A part starting on the same page as the back matter before it is not swallowed by it.
    @Test func aPartOnTheSamePageEndsTheOneBefore() {
        let content = (0..<4).map { ["Page \($0) words."] }
        let outline: [PDFBookStructure.OutlineEntry] = [
            .init(label: "One", page: 0), .init(label: "References", page: 1), .init(label: "Appendix", page: 1), .init(label: "Index", page: 3),
        ]
        #expect(PDFBookStructure.roles(content: content, outline: outline, hasTitle: true).prefix(3) == [.body, .body, .body])
    }

    /// Back matter between the text and a next part, all on one page, goes alone.
    @Test func backMatterOnASharedPageStopsAtTheNextPart() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "Words before."),
            .init(text: "The last words.\nReferences\nSomebody, A Book, 1999.\nAppendix\nThe appendix says this."),
            .init(text: "More of the appendix."),
        ]
        let text = paragraphs(pages, outline: [.init(label: "One", page: 0), .init(label: "References", page: 1),
                                               .init(label: "Appendix", page: 1)]).joined(separator: " ")
        #expect(text.contains("The last words.") && text.contains("The appendix says this.") && text.contains("More of the appendix."))
        #expect(!text.contains("Somebody"))
    }

    /// Readable pages after a recognized index are read.
    @Test func proseAfterAnIndexIsRead() {
        var content: [[String]] = (0..<12).map { ["Prose on page \($0) in plain sentences."] }
        content[9] = ["Index", "Apples 3, 7", "Bears 12"]
        content[10] = ["Cats 40", "Dogs 3"]
        let roles = PDFBookStructure.roles(content: content, outline: [], hasTitle: true)
        #expect(roles[9] == .skipped && roles[10] == .skipped && roles[11] == .body)
    }

    /// Notes that open a page they share with another part are still notes.
    @Test func notesOpeningASharedPageAreKept() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1)) C.\(try marker(2))"),
            .init(text: "Notes\n1 One.\n2 Two.\n3 Three.\nAppendix\nThe appendix says this."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3"], outline: [
            .init(label: "One", page: 0), .init(label: "Notes", page: 1), .init(label: "Appendix", page: 1),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: One.", "Footnote: Two.", "Footnote: Three."])
        #expect(result.joined(separator: " ").contains("The appendix says this."))
    }

    /// Notes that do not pair go back where they stood, heading and all.
    @Test func unpairedNotesFromASharedPageGoBackInPlace() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1)) C.\(try marker(2))"),
            .init(text: "Last words.\nNotes\n77 Numbered otherwise.\nAppendix\nThe appendix says this."),
        ]
        let text = paragraphs(pages, markers: ["7", "8", "9"], outline: [
            .init(label: "One", page: 0), .init(label: "Notes", page: 1), .init(label: "Appendix", page: 1),
        ]).joined(separator: " ")
        let order = ["Last words.", "Notes", "77 Numbered", "Appendix", "The appendix"].map { text.range(of: $0)?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(order.compactMap { $0 } == order.compactMap { $0 }.sorted())
    }

    /// A larger chapter name starts a block, however the note before it ended.
    @Test func aLargerChapterNameStartsABlockAfterAnUnfinishedNote() throws {
        let notes = "Notes\n1 One without an end\nChapter 2\n1 Of two."
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "B.\(try marker(1))"),
            .init(text: notes, lineSizes: ["Notes": 14, "Chapter 2": 12, "1 One without an end": 9, "1 Of two.": 9]),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Chapter 1", page: 0), .init(label: "Chapter 2", page: 1), .init(label: "Notes", page: 2),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: One without an end.", "Footnote: Of two."])
    }

    /// A sole References bookmark that would silence the book takes nothing off its page either.
    @Test func anIgnoredOutlineTakesNothingOffAPage() {
        let pages = ["Words first.\nReferences\nA paragraph that stays."] + (1..<6).map { "Page number \($0) reads on." }
        let text = paragraphs(pages.map { .init(text: $0) }, outline: [.init(label: "References", page: 0)]).joined(separator: " ")
        #expect(text.contains("A paragraph that stays."))
    }

    /// A chapter nested in Notes on its opening page is part of the notes, not the end of them.
    @Test func aNestedChapterOnTheOpeningPageStaysInTheNotes() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "B.\(try marker(1))"),
            .init(text: "Notes\nChapter 1\n1 Of one.\nChapter 2\n1 Of two."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Chapter 1", page: 0), .init(label: "Chapter 2", page: 1), .init(label: "Notes", page: 2),
            .init(label: "Chapter 1", page: 2, level: 1),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: Of one.", "Footnote: Of two."])
    }

    /// Notes before the first that can be numbered in order are still said.
    @Test func notesBeforeTheFirstBlockAreNotLost() throws {
        let body = try ["5", "1", "2"].enumerated().map { "Sentence \($1).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "Notes\n5 The excerpt's first note.\n1 One.\n2 Two.")
        let result = paragraphs([.init(text: body), notes], markers: ["5", "1", "2"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.joined(separator: " ").contains("The excerpt's first note."))
    }

    /// Two notes sections on one page are both kept.
    @Test func twoNotesSectionsOnOnePageAreBothKept() throws {
        let body = try (0..<2).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let notes = PDFBookStructure.Page(text: "Last words.\nNotes\n1 One.\nFootnotes\n1 Other one.")
        let result = paragraphs([.init(text: body), notes], markers: ["1", "1"], outline: [
            .init(label: "Body", page: 0), .init(label: "Notes", page: 1), .init(label: "Footnotes", page: 1),
        ])
        #expect(result.joined(separator: " ").contains("One.") && result.joined(separator: " ").contains("Other one."))
    }

    /// Unpaired notes on a page they share with other back matter are still read.
    @Test func unpairedNotesBesideOtherBackMatterAreRead() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1)) C.\(try marker(2))"),
            .init(text: "Notes\n77 Numbered otherwise.\nReferences\nA reference."),
        ]
        let text = paragraphs(pages, markers: ["7", "8", "9"], outline: [
            .init(label: "Body", page: 0), .init(label: "Notes", page: 1), .init(label: "References", page: 1),
        ]).joined(separator: " ")
        #expect(text.contains("77 Numbered otherwise."))
        #expect(!text.contains("A reference."))
    }

    /// Notes starting under the last of the text are still notes, and the text above them is still read.
    @Test func notesStartingPartwayDownAPageAreKept() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1))"),
            .init(text: "C.\(try marker(2))"),
            .init(text: "The last words.\nNotes\n1 One.\n2 Two.\nChapter Two"),
            .init(text: "1 Other one."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "1"], outline: [
            .init(label: "One", page: 0), .init(label: "Two", page: 1), .init(label: "Notes", page: 2),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: One.", "Footnote: Two.", "Footnote: Other one."])
        #expect(result.contains("The last words."))
        #expect(!result.contains { $0.contains("Chapter Two") })
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

    /// A chapter starting partway down a page: a citation above its heading is still the last chapter's.
    @Test func aCitationAboveAChaptersHeadingIsTheLastChapters() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"),
            .init(text: "B.\(try marker(1))\nChapter 2\nC.\(try marker(2))"),
            .init(text: "Notes\nChapter 1\n1 One.\n2 Two.\nChapter 2\n1 Other one.\n2 Other two."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "1"], outline: [
            .init(label: "Chapter 1", page: 0), .init(label: "Chapter 2", page: 1), .init(label: "Notes", page: 2),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") }.prefix(3) == ["Footnote: One.", "Footnote: Two.", "Footnote: Other one."])
    }

    /// With an outline to go by, a capitalized last line after a note ending in a colon stays in the note.
    @Test func aCapitalizedLineAfterAColonStaysInTheNote() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "One.\(try marker(0))"), .init(text: "Two.\(try marker(1))"),
            .init(text: "Notes\n1 For publication details, see:\nOxford University Press, 1999\n1 Second note."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "One", page: 0), .init(label: "Two", page: 1), .init(label: "Notes", page: 2),
        ])
        #expect(result.contains("Footnote: For publication details, see: Oxford University Press, 1999."))
    }
}
