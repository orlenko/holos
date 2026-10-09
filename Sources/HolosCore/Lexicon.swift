import Foundation
import Synchronization

/// The words the dictation language knows, for the guard on a model's fix (`AIFixGuard`): a real word ("bat",
/// "teeth", "wanted", "Windows") says something, so a fix may replace it only by a listed homophone or a taught pair
/// said there; a word the language does not know ("Onobunto", "bundu") is a mishearing, which one close-sounding real
/// word may replace. A word is real when the system spell checker knows it in the dictation language, lowercased or
/// capitalized (proper nouns: "Mary"), when it has a digit, or when it is a word of a meant phrase the speaker taught
/// or of a term of the speaker's word list (`WordList`: "Keycloak", "AtmoSys"). Each distinct word asks the spell
/// checker at most once.
///
/// The spell checker is a service another process runs, and a call may stall. The fixer therefore asks it ahead of
/// the guard (`prepare`), on `SystemSpelling`'s own queue and within a time budget, never on the task that waits; a
/// word the budget did not reach counts as real, the side that changes nothing. A lexicon made with `blocking` asks
/// on the spot instead, for tests and tools.
public final class Lexicon: Sendable {
    private let taught: Set<String>
    private let lookup: @Sendable (String) -> Bool
    private let blocking: Bool
    /// Where lookups run: `SystemSpelling.queue` for the spell checker.
    private let queue: DispatchQueue
    private let cache = Mutex<[String: Bool]>([:])

    /// The system spell checker's dictionary for `language` (a locale identifier; English and French when nil), and
    /// the words of `taught`: the meant phrases of learned corrections and the terms of the word list. With no
    /// dictionary for the language, every word is real: only homophones and taught pairs may then change a word.
    public convenience init(language: String?, taught: [String] = [], blocking: Bool = true) {
        self.init(taught: taught, blocking: blocking) { SystemSpelling.knows($0, language: language) }
    }

    /// `lookup` says whether a word, as spelled (case included), is known; it may block, and runs on `queue`.
    init(taught: [String] = [], blocking: Bool = true, queue: DispatchQueue = SystemSpelling.queue,
         lookup: @escaping @Sendable (String) -> Bool) {
        self.taught = Set(taught.flatMap { AIFixGuard.words(in: $0) })
        self.blocking = blocking
        self.queue = queue
        self.lookup = lookup
    }

    /// Whether `word` (as `AIFixGuard.words` gives it: lowercased, plain apostrophes) is a real word. A word not yet
    /// looked up is looked up now when the lexicon is `blocking`, and is real otherwise.
    public func isWord(_ word: String) -> Bool {
        if let known = settled(word) { return known }
        if let known = cache.withLock({ $0[word] }) { return known }
        guard blocking else { return true }
        let known = queue.sync { self.looksUp(word) }
        cache.withLock { $0[word] = known }
        return known
    }

    /// Looks up each of `words` not known yet on the spell checker's queue, waiting at most `budget`: the words it
    /// did not reach count as real. Returns at once when the task is cancelled.
    public func prepare(_ words: some Sequence<String>, within budget: Duration) async {
        var seen = Set<String>()
        let missing = words.filter { word in
            settled(word) == nil && cache.withLock({ $0[word] }) == nil && seen.insert(word).inserted
        }
        guard !missing.isEmpty else { return }
        let run = PreparedRun()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                run.start(continuation)
                queue.async { [self] in
                    for word in missing {
                        guard run.isOpen else { break }
                        let known = looksUp(word)
                        // After the budget the guard may already be reading the cache: nothing is added then.
                        guard run.record({ cache.withLock { $0[word] = known } }) else { break }
                    }
                    run.finish()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + budget.timeInterval) { run.finish() }
            }
        } onCancel: {
            run.finish()
        }
    }

    /// What does not need the spell checker: a word with a digit, and a taught word, are real.
    private func settled(_ word: String) -> Bool? {
        word.contains(where: \.isNumber) || taught.contains(word) ? true : nil
    }

    private func looksUp(_ word: String) -> Bool {
        lookup(word) || lookup(word.prefix(1).uppercased() + word.dropFirst())
    }
}

/// One `Lexicon.prepare`: open until the lookups end, the budget runs out, or the task is cancelled, whichever comes
/// first; that one resumes the waiting task.
private final class PreparedRun: Sendable {
    private struct State {
        var open = true
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    var isOpen: Bool { state.withLock { $0.open } }

    func start(_ continuation: CheckedContinuation<Void, Never>) {
        let closed = state.withLock { state -> Bool in
            guard state.open else { return true }
            state.continuation = continuation
            return false
        }
        if closed { continuation.resume() }
    }

    /// Runs `write` while the run is open; false once it is closed.
    func record(_ write: () -> Void) -> Bool {
        state.withLock { state in
            guard state.open else { return false }
            write()
            return true
        }
    }

    func finish() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.open = false
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}

/// A spell checker for `Lexicon` and `DictationSeams`. The app and `voiceislocal` install HolosSpelling's
/// `SystemSpellChecker` (`NSSpellChecker`, AppKit) at launch (`SystemSpelling.install`).
public protocol SpellChecking: Sendable {
    /// Whether the spell checker knows `word` in `language` (see `dictionaries`); true when it has no dictionary
    /// for it. Called on `SystemSpelling.queue` only.
    func knows(_ word: String, language: String?) -> Bool

    /// The spell checker's languages for dictation in `language` (a locale identifier; English and French when nil);
    /// nil when it has none of them. Called on `SystemSpelling.queue` only.
    func dictionaries(for language: String?) -> [String]?
}

/// The process's spell checker (`SpellChecking`), one call at a time on `queue`: the system's is shared by the whole
/// process, not documented as thread-safe, and each call asks another process, which may stall.
///
/// Invariants:
/// 1. `knows` runs on `queue` only, so the installed checker answers one call at a time.
/// 2. Until a checker is installed there is no dictionary: every word is known, and `dictionaries` is nil.
/// 3. An install replaces the checker for every later call; a call already running finishes with the one it read.
public enum SystemSpelling {
    public static let queue = DispatchQueue(label: "ca.orlenko.holos.spelling")

    private static let installed = Mutex<(any SpellChecking)?>(nil)

    /// Makes `checker` the spell checker every lexicon and seam asks from then on. An executable installs it at
    /// launch, before any dictation, fix or lookup.
    public static func install(_ checker: any SpellChecking) {
        installed.withLock { $0 = checker }
    }

    /// Whether the installed spell checker knows `word` in `language`; true when none is installed (invariant 2).
    /// Call on `queue` (invariant 1).
    static func knows(_ word: String, language: String?) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let checker = installed.withLock({ $0 }) else { return true }
        return checker.knows(word, language: language)
    }

    /// The installed spell checker's languages for dictation in `language`; nil when none is installed. Call on
    /// `queue`.
    static func dictionaries(for language: String?) -> [String]? {
        installed.withLock { $0 }?.dictionaries(for: language)
    }
}

extension Duration {
    /// Seconds, for Dispatch.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
