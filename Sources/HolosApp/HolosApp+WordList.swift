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
            onRemove: { [weak self] terms in self?.removeWords(terms) ?? "" })
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
            .update(terms: wordList.terms, problem: wordListProblem)
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
