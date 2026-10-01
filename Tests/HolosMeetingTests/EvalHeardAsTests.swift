import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// `voiceislocal eval apply --add-vocabulary` and the word list's "often heard as" words (docs/design.md "Meeting word
// fixes"): a reviewed passage that replaced local real words by a term proposes them as heard-as words of that term,
// not as a correction. Every sentence is invented.

private let evalDictionary: Set<String> = ["i", "asked", "cloud", "to", "help", "and", "the", "cloak", "login", "we"]

@Test func realWordsReplacedByATermAreHeardAsWords() {
    let terms = EvalApply.termIndex(["Claude", "Keycloak"])
    let isWord: (String) -> Bool = { evalDictionary.contains($0) }
    // The neighbour a correction is learned with is dropped.
    #expect(EvalApply.heardAsTerm(Correction(heard: "asked cloud", meant: "asked Claude"), terms: terms,
                                  isDictionaryWord: isWord) == Correction(heard: "cloud", meant: "Claude"))
    #expect(EvalApply.heardAsTerm(Correction(heard: "cloud,", meant: "claude"), terms: terms, isDictionaryWord: isWord)
        == Correction(heard: "cloud", meant: "Claude"), "Spelled as the list spells the term.")
    // A word that is not a real word stays a correction; so does a meant side that is no term.
    #expect(EvalApply.heardAsTerm(Correction(heard: "kay cloak", meant: "Keycloak"), terms: terms,
                                  isDictionaryWord: isWord) == nil)
    #expect(EvalApply.heardAsTerm(Correction(heard: "the cloud", meant: "the crowd"), terms: terms,
                                  isDictionaryWord: isWord) == nil)
    #expect(EvalApply.heardAsTerm(Correction(heard: "Claude", meant: "claude"), terms: terms,
                                  isDictionaryWord: { _ in true }) == nil)
}

@Test func aListedTermIsFoundWholeBeforeContextIsTrimmed() {
    let isWord: (String) -> Bool = { ["we", "use", "cloud", "code", "see", "plus", "sharp"].contains($0) }
    // "code" is part of the listed term, not context to drop.
    #expect(EvalApply.heardAsTerm(Correction(heard: "use cloud code", meant: "use Claude Code"),
                                  terms: EvalApply.termIndex(["Claude Code"]), isDictionaryWord: isWord)
        == Correction(heard: "cloud code", meant: "Claude Code"))
    // Punctuation that belongs to a term tells terms apart.
    let index = EvalApply.termIndex(["C#", "C++", ".NET"])
    #expect(EvalApply.heardAsTerm(Correction(heard: "see plus plus", meant: "C++"), terms: index,
                                  isDictionaryWord: isWord) == Correction(heard: "see plus plus", meant: "C++"))
    #expect(EvalApply.heardAsTerm(Correction(heard: "see sharp", meant: "C#."), terms: index,
                                  isDictionaryWord: isWord) == Correction(heard: "see sharp", meant: "C#"))
    #expect(EvalApply.heardAsTerm(Correction(heard: "see", meant: "C"), terms: index, isDictionaryWord: isWord)
        == nil)
}

@Test func applyProposesHeardAsWordsAndAddsThemToTheirTerms() async throws {
    let temp = try TemporaryDirectory("eval-heard-as")
    defer { temp.remove() }
    let words = ["I", "asked", "cloud", "to", "help", "and", "the", "kay", "cloak", "login"]
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(words, track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 6], transcript: transcript)
    let manifest = try SessionArchive.readManifest(at: session)
    let passages = [
        EvalPassage(id: "mic-1", track: "mic", start: 1.5, end: 1.9, local: "cloud", cloud: "Claude",
                    group: .namesAndTerms, before: "I asked", after: "to help", localFirst: 2, localEnd: 3),
        EvalPassage(id: "mic-2", track: "mic", start: 4, end: 4.9, local: "kay cloak", cloud: "Keycloak",
                    group: .namesAndTerms, before: "and the", after: "login", localFirst: 7, localEnd: 9),
    ]
    let report = CompareReport(sessionID: manifest.id, run: "gpt-transcribe-20260929T000000Z", model: "gpt-transcribe",
                               transcriptID: transcript.id, createdAt: SessionFixtures.date, total: EvalScore(),
                               tracks: [.init(track: "mic", score: EvalScore(), groups: [:], warnings: [])],
                               passages: passages)
    let decisions = ReviewDecisions(sessionID: manifest.id, run: report.run, transcriptID: transcript.id,
                                    decisions: [.init(id: "mic-1", choice: .edited, text: "Claude"),
                                                .init(id: "mic-2", choice: .cloud, text: "Keycloak")],
                                    terms: ["Keycloak"])
    let result = try EvalApply.build(session: session, report: report, decisions: decisions, knownTerms: ["Claude"],
                                     isDictionaryWord: { evalDictionary.contains($0) })
    #expect(result.heardAs == [Correction(heard: "cloud", meant: "Claude")])
    #expect(result.corrections == [Correction(heard: "kay cloak", meant: "Keycloak")])
    #expect(result.terms == ["Keycloak"])
    // Without the term in the list or marked, the pair is a correction as before.
    let unknown = try EvalApply.build(session: session, report: report, decisions: decisions,
                                      isDictionaryWord: { evalDictionary.contains($0) })
    #expect(unknown.heardAs.isEmpty)
    #expect(unknown.corrections.contains(Correction(heard: "cloud to", meant: "Claude to")),
            "Learned with the next word, as a lone dictionary word is.")

    // --add-vocabulary: the marked terms, then the heard-as words to their terms; a missing term is said.
    let store = WordListStore(url: temp.url.appendingPathComponent("words.json"))
    _ = try WordListCommand.add(["Claude"], store: store)
    let added = try EvalApply.addToHeardAs(result.heardAs + [Correction(heard: "codecs", meant: "Codex")],
                                           store: store)
    #expect(added.output == ["Claude is often heard as: cloud."])
    #expect(added.errors == ["Not in the word list, so its often-heard-as words were not added: Codex"])
    #expect(added.exitCode == 1)
    #expect(try store.load().heardAsPairs == [Correction(heard: "cloud", meant: "Claude")])
    #expect(try EvalApply.addToHeardAs(result.heardAs, store: store).errors == ["Already listed for Claude: cloud"])
}
