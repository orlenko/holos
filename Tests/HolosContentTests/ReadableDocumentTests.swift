import Testing
@testable import HolosContent

@Suite struct ReadableDocumentTests {
    @Test func plainTextHasTheTitleThenEachHeadingAndParagraph() {
        let document = ReadableDocument(title: "A Guide", sections: [
            .init(paragraphs: ["First words."]),
            .init(heading: "Part one", level: 2, paragraphs: ["One.", "Two."]),
        ])
        #expect(document.plainText == "A Guide\n\nFirst words.\n\nPart one\n\nOne.\n\nTwo.")
    }

    @Test func plainTextLeavesOutATitleTheTextOpensWith() {
        let document = ReadableDocument(title: "A Guide | Example Site", sections: [
            .init(heading: "A Guide", level: 1, paragraphs: ["Body."]),
        ])
        #expect(document.plainText == "A Guide\n\nBody.")
        #expect(ReadableDocument(sections: [.init(paragraphs: ["Only this."])]).plainText == "Only this.")
    }
}

@Suite struct ReadableDocumentSelectionTests {
    @Test func aSelectionIsTitledByItsFirstWords() throws {
        let document = try #require(ReadableDocument.selection(
            "  The quick brown fox jumps over the lazy dog again and again.\n\nA second paragraph.\n"))
        #expect(document.title == "The quick brown fox jumps over the lazy…")
        #expect(document.sections.flatMap(\.paragraphs) == [
            "The quick brown fox jumps over the lazy dog again and again.", "A second paragraph.",
        ])
        #expect(ReadableDocument.selection("Short words.")?.title == "Short words.")
    }

    @Test func aSelectionWhoseFirstLineLooksLikeATitleKeepsItAsTheTitle() throws {
        let document = try #require(ReadableDocument.selection("Getting Started\n\nInstall the app first."))
        #expect(document.title == "Getting Started")
        #expect(document.plainText == "Getting Started\n\nInstall the app first.")
    }

    @Test func aBlankSelectionHasNoDocument() {
        #expect(ReadableDocument.selection(" \n\t ") == nil)
    }
}
