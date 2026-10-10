import Foundation
import HolosCore
import Testing

// `MeetingVocabulary.cleaned`: the one vocabulary rule of the app's hand-off file, the recorder and import
// (docs/meeting/recorder.md §4.12).

@Test func meetingVocabularyTrimsAndDropsEmptyAndOverlongEntries() {
    let longest = String(repeating: "x", count: MeetingVocabulary.maximumLength)
    let tooLong = longest + "x"
    #expect(MeetingVocabulary.cleaned(["  Maria Chen ", "", "   ", "\nStrata\t", tooLong, longest])
        == ["Maria Chen", "Strata", longest])
    // An entry is measured after trimming.
    #expect(MeetingVocabulary.cleaned([" " + longest + " "]) == [longest])
}

@Test func meetingVocabularyKeepsTheFirstThousandInOrderWithDuplicates() {
    #expect(MeetingVocabulary.maximumEntries == 1_000)
    #expect(MeetingVocabulary.maximumLength == 100)
    let terms = (0..<1_200).map { "term \($0)" }
    #expect(MeetingVocabulary.cleaned(terms) == Array(terms.prefix(1_000)))
    // Dropped entries do not count toward the limit; duplicates are kept as given.
    let mixed = [""] + Array(repeating: "Strata", count: 2) + terms
    #expect(MeetingVocabulary.cleaned(mixed) == ["Strata", "Strata"] + Array(terms.prefix(998)))
}
