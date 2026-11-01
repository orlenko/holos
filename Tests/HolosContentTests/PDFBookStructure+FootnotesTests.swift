import Foundation
import Testing
@testable import HolosContent

/// Notes at a page's foot, and markers without notes (`PDFBookStructure`).
@Suite struct PDFBookFootnotesTests: PDFBookPages {
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

    /// Labels given apart from their notes, all first or each on its own line, pair with the right notes.
    @Test(arguments: ["1\n2\n3\nFirst.\nSecond.\nThird.", "1\nFirst.\n2\nSecond.\n3\nThird."])
    func detachedLabelsPairWithTheirNotes(notes: String) throws {
        let body = try (0..<3).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let result = paragraphs([.init(text: body), .init(text: "Notes\n" + notes)], markers: ["1", "2", "3"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: First.", "Footnote: Second.", "Footnote: Third."])
    }

    /// A capitalized opening after a label given apart is the note's, not a chapter's name.
    @Test func aDetachedLabelsCapitalizedOpeningIsTheNote() throws {
        let body = try (0..<3).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let notes = "Notes\n1\nA citation that wraps\nonto a second line.\n2 Second.\n3 Third."
        let result = paragraphs([.init(text: body), .init(text: notes)], markers: ["1", "2", "3"],
                                outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.contains("Footnote: A citation that wraps onto a second line."))
    }

    /// Notes ending partway down a page, above the next part's heading, are all notes.
    @Test func notesEndingPartwayDownAPageStayNotes() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1)) C.\(try marker(2))"),
            .init(text: "Notes\n1 One.\n2 Two begins"),
            .init(text: "and ends here.\n3 Three.\nAppendix\nThe appendix says this."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3"], outline: [
            .init(label: "Body", page: 0), .init(label: "Notes", page: 1), .init(label: "Appendix", page: 2),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: One.", "Footnote: Two begins and ends here.", "Footnote: Three."])
        #expect(result.joined(separator: " ").contains("The appendix says this."))
    }

    /// A chapter's notes starting over with their labels given apart start a block.
    @Test func detachedLabelsStartingOverStartABlock() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0))"), .init(text: "B.\(try marker(1))"),
            .init(text: "Notes\n1 One."),
            .init(text: "Chapter 2\n1\nOf two.", lineSizes: ["Chapter 2": 12, "1": 9, "Of two.": 9, "x": 9, "y": 9]),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Chapter 1", page: 0), .init(label: "Chapter 2", page: 1), .init(label: "Notes", page: 2),
        ])
        #expect(result.filter { $0.hasPrefix("Footnote:") } == ["Footnote: One.", "Footnote: Of two."])
    }

    /// Back matter ends at the next part, whichever page that is on.
    @Test func backMatterEndsAtTheNextPartEvenOnItsOwnPage() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "Words first."),
            .init(text: "References\nSomebody, A Book.\nAppendix\nThe appendix begins."),
            .init(text: "The appendix goes on.\nEpilogue\nThe epilogue."),
        ]
        let text = paragraphs(pages, outline: [
            .init(label: "One", page: 0), .init(label: "References", page: 1), .init(label: "Appendix", page: 1),
            .init(label: "Epilogue", page: 2),
        ]).joined(separator: " ")
        #expect(text.contains("The appendix goes on.") && !text.contains("Somebody"))
    }

    /// A page holding the end of one notes section and the start of another keeps both in reading order.
    @Test func twoSectionsMeetingOnAPageStayInOrder() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1))"),
            .init(text: "Notes\n1 One begins"),
            .init(text: "and ends here.\nFootnotes\n1 Other one."),
        ]
        let result = paragraphs(pages, markers: ["1", "1"], outline: [
            .init(label: "Body", page: 0), .init(label: "Notes", page: 1), .init(label: "Footnotes", page: 2),
        ])
        #expect(result.contains("Footnote: One begins and ends here."))
    }

    /// Notes going on to a page where other back matter begins partway down are all notes.
    @Test func notesEndingAboveReferencesAreAllNotes() throws {
        let pages: [PDFBookStructure.Page] = [
            .init(text: "A.\(try marker(0)) B.\(try marker(1)) C.\(try marker(2))"),
            .init(text: "Notes\n1 One.\n2 Two.\n3 Three begins"),
            .init(text: "and ends here.\nReferences\nSomebody, A Book."),
        ]
        let result = paragraphs(pages, markers: ["1", "2", "3"], outline: [
            .init(label: "Body", page: 0), .init(label: "Notes", page: 1), .init(label: "References", page: 2),
        ])
        #expect(result.contains("Footnote: Three begins and ends here."))
        #expect(!result.joined(separator: " ").contains("Somebody"))
    }

    /// With no outline to name it, a capitalized last line before the numbers start over stays in the note.
    @Test func withoutAnOutlineACapitalizedLastLineStaysInTheNote() throws {
        var pages = (0..<8).map { PDFBookStructure.Page(text: Self.differentWords(8)[$0]) }
        pages[0] = .init(text: "One.\(try marker(0)) More.\(try marker(1))")
        pages[1] = .init(text: "Two.\(try marker(2))")
        pages[6] = .init(text: "Notes\n1 See the book.\nOxford University Press, 1999\n1 Second note.\n2 Third note.")
        let result = paragraphs(pages, markers: ["1", "1", "2"])
        #expect(result.joined(separator: " ").contains("See the book. Oxford University Press, 1999."))
    }

    /// A page reference wrapped onto its own line stays in its note.
    @Test func aNotesNumericLineStaysInIt() throws {
        let body = try (0..<3).map { "Sentence \($0).\(try marker($0))" }.joined(separator: " ")
        let result = paragraphs([.init(text: body), .init(text: "Notes\n1 Writer, Title, p.\n123\n2 Two.\n3 Three.")],
                                markers: ["1", "2", "3"], outline: [.init(label: "Body", page: 0), .init(label: "Notes", page: 1)])
        #expect(result.contains("Footnote: Writer, Title, p. 123."))
    }

    /// A number in small print closing a page is the end of a note, once the furniture has gone.
    @Test func aFootnotesNumericLastLineStaysInIt() throws {
        let page = PDFBookStructure.Page(text: "A.\(try marker(0)) B.\(try marker(1))\n1 Writer, Title, p.\n123\n2 Another.\nends at 124",
                                         lineSizes: ["1 Writer, Title, p.": 8, "123": 8, "2 Another.": 8, "ends at 124": 8])
        let result = paragraphs([page], markers: ["1", "2"], bodySize: 10)
        #expect(result.contains("Footnote: Writer, Title, p. 123."))
    }
}
