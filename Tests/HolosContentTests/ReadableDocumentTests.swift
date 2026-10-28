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
