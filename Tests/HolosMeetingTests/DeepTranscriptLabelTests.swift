import Foundation
import HolosCore
@testable import HolosMeeting
import HolosTestSupport
import Testing

// Speaker labels the deep transcription model invents (docs/meeting/deep-transcription.md §4.16). Every name and sentence
// is invented.

/// A passage as Whisper writes it: each word with its leading space, `wordSeconds` each from `start`; a word given as
/// "+text" follows the one before without a space ("Ph" "+.D.:").
private func passage(_ text: String, at start: Double, track: String = "system", wordSeconds: Double = 0.3)
    -> DeepHeardSegment {
    let words = text.split(separator: " ").enumerated().map { index, word in
        let joined = word.hasPrefix("+")
        return DeepTranscribedWord(text: joined ? String(word.dropFirst()) : " " + word,
                                   start: start + Double(index) * wordSeconds,
                                   end: start + Double(index + 1) * wordSeconds, probability: 0.2)
    }
    return DeepHeardSegment(track: track, start: start, end: words.last?.end ?? start,
                            text: words.map(\.text).joined(), words: words, levelDB: -20)
}

private func recorded(_ text: String, at start: Double, track: String = "system") -> TranscriptSegment {
    SessionFixtures.segment(text.split(separator: " ").map(String.init), track: track, start: start, wordSeconds: 0.3)
}

@Test func anInventedLabelIsRemovedFromThePassageStart() throws {
    let reference = [recorded("still pending from the contractor", at: 10)]
    let result = DeepTranscriptGuards.apply([
        passage("Jane Ostrowski: Still pending from the contractor.", at: 10),
        passage("Omar Feld, Ph +.D.: Yes.", at: 20),
        passage("Dr. Lena Vos: That is.", at: 30),
        passage("QXRTL: Next item.", at: 40),
        passage("Ana de la Cruz: Agreed.", at: 50),
        passage("2031 -04 -0109: The screen shows it.", at: 60),
    ], reference: reference)
    #expect(result.droppedLabels == 6)
    #expect(result.kept.map(\.text) == [" Still pending from the contractor.", " Yes.", " That is.", " Next item.",
                                        " Agreed.", " The screen shows it."])
    // The passage starts at its first word left.
    #expect(abs(result.kept[0].start - 10.6) < 1e-9 && result.kept[0].words.count == 5)
    let built = try #require(DeepAudio.transcriptSegment(result.kept[0]))
    #expect(built.text == "Still pending from the contractor." && abs(built.start - 10.6) < 1e-9)
}

@Test func aLabelAfterASentenceIsRemovedAndAPassageOfOnlyALabelIsDropped() {
    let result = DeepTranscriptGuards.apply([
        passage("Back to the parking question. Mira Sandoval: Yeah.", at: 0),
        passage("Mira Sandoval:", at: 10),
        passage("Mira Sandoval: Kai Brandt: Both.", at: 20),
    ], reference: nil)
    #expect(result.droppedLabels == 4)
    #expect(result.kept.map(\.text) == [" Back to the parking question. Yeah.", " Both."])
}

@Test func speechThatLooksLikeALabelStays() {
    let reference = [
        recorded("question how long will it take", at: 0),
        recorded("Bruno says yes", at: 30, track: "mic"),
    ]
    let segments = [
        // Lowercase words: a sentence.
        passage("So the answers are as follows: one, two.", at: 10),
        passage("Here is the list: first the roof.", at: 20),
        // Said aloud: the recorded transcript has it there.
        passage("Question: how long will it take?", at: 0),
        passage("Bruno: says yes.", at: 30, track: "mic"),
        // A colon too far in, a time, and a colon word in mid-sentence.
        passage("Alpha Beta Gamma Delta Epsilon Zeta: done.", at: 40),
        passage("At 10:30 we start.", at: 50),
        passage("The rule is simple: Ask first.", at: 60),
    ]
    let result = DeepTranscriptGuards.apply(segments, reference: reference)
    #expect(result.droppedLabels == 0)
    #expect(result.kept.map(\.text) == segments.map(\.text))
}

@Test func aLabelIsKeptOnlyWhenAllOfItsNamesWereSaidOnItsTrackNearIt() {
    // "Pia?" was said before the answer; the label's surname was not, so the label goes.
    let partly = DeepTranscriptGuards.apply([passage("Pia Lindqvist: No motion needed.", at: 10)],
                                            reference: [recorded("Pia no motion needed", at: 9.4)])
    #expect(partly.droppedLabels == 1)
    // Said on the other track, or too far from it: not this label.
    let other = DeepTranscriptGuards.apply([passage("Question: is it done?", at: 10)],
                                           reference: [recorded("question is it done", at: 10, track: "mic")])
    #expect(other.droppedLabels == 1)
    let far = DeepTranscriptGuards.apply([passage("Question: is it done?", at: 10)],
                                         reference: [recorded("question", at: 4)])
    #expect(far.droppedLabels == 1)
    // A title is not looked for; the name is.
    let titled = DeepTranscriptGuards.apply([passage("Dr. Okafor: Thanks.", at: 10)],
                                            reference: [recorded("doctor Okafor thanks", at: 10)])
    #expect(titled.droppedLabels == 0)
    // A recorded segment without a track counts for every track.
    var untracked = recorded("question is it done", at: 10)
    untracked.track = nil
    #expect(DeepTranscriptGuards.apply([passage("Question: is it done?", at: 10)], reference: [untracked])
        .droppedLabels == 0)
}

@Test func anUntimedPassageLosesItsLabelFromItsText() {
    let untimed = DeepHeardSegment(track: "mic", start: 5, end: 8, text: " Tomas Rehn:  We agree. ", levelDB: -20)
    let result = DeepTranscriptGuards.apply([untimed], reference: nil)
    #expect(result.droppedLabels == 1)
    #expect(result.kept.map(\.text) == ["We agree."] && result.kept[0].start == 5 && result.kept[0].words.isEmpty)
}

@Test func labelsAreRemovedBeforeRepeatsAreCompared() {
    let result = DeepTranscriptGuards.apply([
        passage("Rhea Moss: Okay.", at: 0), passage("Okay.", at: 1), passage("Rhea Moss: Okay.", at: 2),
    ], reference: nil)
    #expect(result.droppedLabels == 2 && result.droppedRepeats == 2 && result.kept.map(\.text) == [" Okay."])
}

@Test func theStageSummarySaysHowManyLabelsWereRemoved() {
    #expect(DeepTranscriptionStage.summary(segments: 12, droppedSilent: 1, droppedRepeats: 0, droppedLabels: 3,
                                           promptTerms: 0)
        == "Transcribed again with Whisper large-v3 turbo: 12 passages; left out 1 passage over silence; removed 3 "
        + "speaker labels nobody said.")
    #expect(DeepTranscriptionStage.summary(segments: 2, droppedSilent: 0, droppedRepeats: 0, droppedLabels: 1,
                                           promptTerms: 0)
        == "Transcribed again with Whisper large-v3 turbo: 2 passages; removed 1 speaker label nobody said.")
}
