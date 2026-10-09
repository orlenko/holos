import AppKit
import HolosCore
import HolosMeeting
import HolosStorage

/// The word list (docs/design.md "Word list"): `words.json`, edited in the Corrections section and with
/// `voiceislocal words`. The app reads it at launch, and again when the file changed since (checked at each
/// dictation, each meeting start, Run Again, when the Corrections section shows, and when the Application Support
/// folder changes, through the corrections watch in HolosApp.swift), so terms added in Terminal
/// count without a relaunch. Every change is made on the list as it is on disk (`WordListStore.update`).
extension HolosAppDelegate {
    /// Reads `words.json`; a list that cannot be read is empty for recognition and is never overwritten.
    func loadWordList() {
        let stamp = wordListStore.stamp()
        do {
            wordList = try wordListStore.load()
            wordListProblem = nil
        } catch {
            wordList = WordList()
            wordListProblem = "Could not read words.json: \(error.localizedDescription) "
                + "The word list is off until it is fixed or removed."
        }
        wordListStamp = stamp
    }

    /// Reads `words.json` again when it changed since it was last read, or could not be read then, and passes the
    /// change on.
    func refreshWordList() {
        guard wordListProblem != nil || wordListStore.stamp() != wordListStamp else { return }
        loadWordList()
        wordListChanged()
    }

    /// Dictation's contextual strings in `language`: the word list, then the words of learned corrections.
    func dictationVocabulary(language: String) -> [String] {
        RecognizerVocabulary.dictation(wordList: wordList.terms, corrections: corrections, language: language)
    }

    /// The words whose capitals dictation keeps after a pause inside a sentence (`DictationSeams`): the word list's
    /// terms, learned corrections' meant phrases, and people's names (as last read: `peopleNames` reads the people
    /// store again in the background when it changed, never on the main thread). Live dictation asks it as each
    /// dictation starts; Run Again uses the same names.
    func dictationSeamTerms() -> [String] {
        DictationSeams.terms(wordList: wordList.terms, corrections: corrections, names: peopleNames.current())
    }

    /// A meeting's contextual strings in `languages`: the word list (read again if it changed), people's names, then
    /// the words of learned corrections. The recorder saves them as the meeting's `vocabulary.json`.
    func meetingVocabulary(languages: [String]) -> [String] {
        refreshWordList()
        return RecognizerVocabulary.meeting(wordList: wordList.terms,
                                            names: VoiceProfileService.profileNames().values.sorted(),
                                            corrections: corrections, languages: languages)
    }

    func makeWordListView() -> WordListView {
        WordListView(
            onAdd: { [weak self] terms in self?.addWords(terms) ?? .init(message: "", unadded: terms) },
            onRemove: { [weak self] terms in self?.removeWords(terms) ?? "" },
            onSetHeardAs: { [weak self] term, phrases in self?.setHeardAs(phrases, for: term) ?? "" })
    }

    /// Makes `phrases` the "often heard as" words of `term`; returns what happened, for the Corrections section.
    func setHeardAs(_ phrases: [String], for term: String) -> String {
        let change: WordList.HeardAsChange?
        do {
            change = try changeWordList { list in list.setHeardAs(phrases, for: term) }
        } catch {
            return "Could not save the word list: \(error.localizedDescription)"
        }
        guard let change else { return "\(term) is no longer in the word list." }
        var parts = [change.phrases.isEmpty ? "\(change.term) has no often-heard-as words."
            : "\(change.term) is often heard as: \(change.phrases.joined(separator: ", "))."]
        if !change.refused.isEmpty {
            parts.append("Not kept: \(change.refused.joined(separator: ", ")) (the term itself, too long, or past "
                + "\(WordList.maximumHeardAs) words).")
        }
        return parts.joined(separator: " ")
    }

    /// The "often heard as" phrases of `term` in the word list (read again if it changed), nil when it does not have it:
    /// a meeting's Review offers a term it lacks.
    func wordListHeardAs(_ term: String) -> [String]? {
        refreshWordList()
        return wordList.heardAs(of: term)
    }

    /// Adds `term` from a meeting's Review (`WordListSource.review`), with `heardAs` as an "often heard as" phrase;
    /// returns what happened, for the review's footer.
    func addReviewTerm(_ term: String, heardAs: String?) -> String {
        let result: (WordList.AddOutcome, WordList.HeardAsChange?)
        do {
            result = try changeWordList { list in
                let outcome = list.add(term, source: .review)
                return (outcome, heardAs.flatMap { list.addHeardAs([$0], to: term) })
            }
        } catch {
            return "Could not save the word list: \(error.localizedDescription)"
        }
        let heard = result.1.flatMap { $0.added.first ?? $0.unchanged.first }.map { ", often heard as “\($0)”" } ?? ""
        switch result.0 {
        case .added(let added): return "Added “\(added)” to the word list\(heard)."
        case .duplicate(let existing): return "“\(existing)” is in the word list\(heard)."
        case .empty: return "Nothing to add to the word list."
        case .tooLong: return "“\(term)” is longer than \(WordList.maximumLength) characters, so it was not added."
        case .full: return "The word list is full (\(WordList.maximumTerms) terms), so “\(term)” was not added."
        }
    }

    /// Adds `terms`; returns what happened, for the Corrections section, and the terms that were not added and are not
    /// listed (too long, the list full, or all of them when the list could not be saved), to leave in the field.
    func addWords(_ terms: [String]) -> WordListView.AddResult {
        let outcomes: [WordList.AddOutcome]
        do {
            outcomes = try changeWordList { list in terms.map { list.add($0, source: .user) } }
        } catch {
            return .init(message: "Could not save the word list: \(error.localizedDescription)", unadded: terms)
        }
        let unadded = zip(terms, outcomes).compactMap { term, outcome -> String? in
            switch outcome {
            case .tooLong, .full: term
            case .added, .duplicate, .empty: nil
            }
        }
        return .init(message: Self.describe(outcomes), unadded: unadded)
    }

    /// Removes `terms`; returns what happened, for the Corrections section.
    func removeWords(_ terms: [String]) -> String {
        let removed: [String]
        do {
            removed = try changeWordList { list in terms.compactMap { list.remove($0) } }
        } catch {
            return "Could not save the word list: \(error.localizedDescription)"
        }
        return removed.isEmpty ? "Nothing removed: the list no longer has those terms."
            : "Removed: " + removed.joined(separator: ", ")
    }

    /// Applies `change` to the list on disk and shows the result: the next dictation's vocabulary and the Corrections
    /// section. Throws, changing nothing, when `words.json` cannot be read or saved.
    private func changeWordList<T>(_ change: (inout WordList) -> T) throws -> T {
        do {
            let (list, result, stamp) = try wordListStore.update(change)
            wordList = list
            wordListProblem = nil
            wordListStamp = stamp
            wordListChanged()
            return result
        } catch {
            // What is on disk may have changed or become unreadable: show that, not the list in memory.
            loadWordList()
            wordListChanged()
            throw error
        }
    }

    /// The list changed: the next dictation expects its terms and the Corrections section shows it.
    func wordListChanged() {
        updateDictationVocabulary()
        (mainWindow?.existingController(for: .corrections) as? CorrectionsPane)?.wordListView
            .update(entries: wordList.entries, problem: wordListProblem)
    }

    /// "Added: Keycloak, Urban Sky. Already listed: Apex." and the like.
    static func describe(_ outcomes: [WordList.AddOutcome]) -> String {
        var added: [String] = [], duplicates: [String] = []
        var tooLong = 0, full = 0
        for outcome in outcomes {
            switch outcome {
            case .added(let term): added.append(term)
            case .duplicate(let existing): if !duplicates.contains(existing) { duplicates.append(existing) }
            case .empty: break
            case .tooLong: tooLong += 1
            case .full: full += 1
            }
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("Added: " + added.joined(separator: ", ") + ".") }
        if !duplicates.isEmpty { parts.append("Already listed: " + duplicates.joined(separator: ", ") + ".") }
        if tooLong > 0 {
            parts.append("\(tooLong) longer than \(WordList.maximumLength) characters \(tooLong == 1 ? "was" : "were") "
                + "not added.")
        }
        if full > 0 { parts.append("The list is full (\(WordList.maximumTerms) terms): \(full) not added.") }
        return parts.isEmpty ? "Nothing to add." : parts.joined(separator: " ")
    }
}
