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

/// A vocabulary prompt as the deep transcription pass builds it: the meeting's name, then terms and people's names.
private let prompt = "Weekly sync. Ostrowski, Jane Ostrowski-Lind, Jane Doe-Smith, Omar, Lena, Анна Иванова."

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
        passage("Agreed. Mira Sandoval: Yeah.", at: 5),
        passage("Mira Sandoval:", at: 10),
        passage("Mira Sandoval: Kai Brandt: Both.", at: 20),
    ], reference: nil)
    #expect(result.droppedLabels == 5)
    #expect(result.kept.map(\.text) == [" Back to the parking question. Yeah.", " Agreed. Yeah.", " Both."])
}

@Test func hyphenatedLabelsAndPromptRollCallListsAreRemoved() throws {
    let reference = [
        recorded("still pending from the contractor", at: 10),
        recorded("making the schedule work", at: 30),
        recorded("checklist and flow", at: 40),
        recorded("that works for the team", at: 50),
        recorded("but the default works", at: 70),
    ]
    let result = DeepTranscriptGuards.apply([
        // Speaker turn with a trailing hyphen or a spaced dash.
        passage("Jane Ostrowski- Still pending from the contractor.", at: 10),
        passage("Jane Ostrowski - Yes.", at: 20),
        // Speaker turn whose hyphen was glued to the first word of the sentence.
        passage("Jane Ostrowski +-Making the schedule work.", at: 30),
        passage("Jane Ostrowski +-Vis, Checklist and flow.", at: 40),
        // Comma-separated prompt roll-call lists, with and without a colon.
        passage("Jane Ostrowski +-Lind, Omar, Lena, M +.D.: That works for the team.", at: 50),
        passage("Jane Ostrowski +-Lind, Omar, Lena, Flight path.", at: 60),
        passage("Jane Ostrowski +-Lind, Omar. But the default works.", at: 70),
        passage("Jane Ostrowski +-Lind, Omar.", at: 80),
        // Mid-passage hyphenated labels after sentence ends (as when several sub-segments sit in one passage).
        passage("Jane Ostrowski- First point. Jane Ostrowski- Second point.", at: 90),
    ], reference: reference, prompt: prompt)
    #expect(result.droppedLabels == 10)
    #expect(result.kept.map(\.text) == [
        " Still pending from the contractor.",
        " Yes.",
        " Making the schedule work.",
        " Checklist and flow.",
        " That works for the team.",
        " Flight path.",
        " But the default works.",
        " First point. Second point.",
    ])
    let unhyphenated = try #require(DeepAudio.transcriptSegment(result.kept[2]))
    #expect(unhyphenated.text == "Making the schedule work.")
}

@Test func speechShapedLikeADashLabelOrAListStaysUnlessItsNamesComeFromThePrompt() {
    let segments = [
        // Not names from the prompt: ranges, a spaced dash, an addressed name, a sentence before a list.
        passage("From January +-March we grew.", at: 0),
        passage("Next Monday - Friday works for me.", at: 10),
        passage("Phase Two - testing starts soon.", at: 20),
        passage("Merci Marie +-Claire, c'est bon.", at: 30),
        passage("Thanks Kai. Lena, Omar, Jane, can you join?", at: 40),
        passage("Rhea Moss, Kai Brandt, Lena Vos, ready.", at: 50),
    ]
    let result = DeepTranscriptGuards.apply(segments, reference: nil, prompt: prompt)
    #expect(result.droppedLabels == 0)
    #expect(result.kept.map(\.text) == segments.map(\.text))
    // Without a prompt, only a colon label is looked for.
    let unprompted = [passage("Jane Ostrowski- Yes.", at: 0), passage("Jane Ostrowski +-Lind, Omar, Lena, Go.", at: 10)]
    #expect(DeepTranscriptGuards.apply(unprompted, reference: nil).droppedLabels == 0)
}

@Test func aDashLabelOfPromptNamesStaysWhenAnyOfItsNamesWasSaidAtIt() {
    // The recorded transcript misheard the surname but has the first name: the name was said.
    let addressed = [passage("Jane Ostrowski +-Making the plan.", at: 10),
                     passage("Анна Иванова — руководитель проекта.", at: 30)]
    let reference = [recorded("Jane Ostrovsky making the plan", at: 10),
                     recorded("Анна Иванов руководитель проекта", at: 30)]
    let kept = DeepTranscriptGuards.apply(addressed, reference: reference, prompt: prompt)
    #expect(kept.droppedLabels == 0 && kept.kept.map(\.text) == addressed.map(\.text))
    // Nobody said either name there, or only in the turn before ("Jane, any update?" ending 1 s before): invented.
    let invented = DeepTranscriptGuards.apply(addressed, reference: [recorded("Jane any update", at: 8.1),
                                                                     recorded("making the plan", at: 10)],
                                              prompt: prompt)
    #expect(invented.droppedLabels == 2)
    #expect(invented.kept.map(\.text) == [" Making the plan.", " руководитель проекта."])
    // A hyphenated name spelled as in the prompt is the name, not a label glued to the next word.
    let named = [passage("Jane Doe +-Smith will present.", at: 0), passage("Jane Doe +-Smith, can you share?", at: 10)]
    #expect(DeepTranscriptGuards.apply(named, reference: nil, prompt: prompt).droppedLabels == 0)
    let labelled = DeepTranscriptGuards.apply([passage("Jane Doe +-Smith - Yes.", at: 0)], reference: nil,
                                              prompt: prompt)
    #expect(labelled.kept.map(\.text) == [" Yes."])
}

@Test func speechThatLooksLikeALabelStays() {
    let reference = [
        recorded("question how long will it take", at: 0),
        recorded("Bruno says yes", at: 30, track: "mic"),
        recorded("payload 1 payload 2 payload 3 ready", at: 70),
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
        // A spoken list whose numbers the recorded transcript heard, and hyphenated non-name tokens.
        passage("Pailot 1, Pailot 2, Pailot 3, ready.", at: 70),
        passage("I'm R2 +-D2, ready.", at: 80),
        passage("For C +-12, ready.", at: 90),
        passage("Let's- go.", at: 100),
    ]
    let result = DeepTranscriptGuards.apply(segments, reference: reference, prompt: prompt + " Pailot.")
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
