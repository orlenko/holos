import Foundation

/// When the review window rewrites a meeting's transcript files (`exports/`): `delay` after the last change saved, not
/// on every edit, and never while the review is closed or paused (`canRun`); the review then writes them at `close`,
/// or schedules them again when it resumes. `fire` queues the rewrite (the review's `.exports` change), which reports
/// back with `regenerated` or `failed`.
///
/// Invariants:
/// 1. `pending` is true from a change saved (or the files known to be behind) until a rewrite succeeds or a writer
///    rewrote the files itself (`regenerated`, `written`).
/// 2. At most one timer waits; scheduling again replaces it, and `written` and `cancel` stop it.
/// 3. A timer calls `fire` once, and only when it was not stopped or replaced first.
/// 4. `problem` is why the last rewrite failed; whatever writes the files clears it.
@MainActor final class ReviewExportScheduler {
    private(set) var pending = false
    private(set) var problem: String?
    private let delay: Duration
    private var timer: Task<Void, Never>?
    /// Whether a timer may start now (the review is open and not paused).
    var canRun: @MainActor () -> Bool = { true }
    /// Queues the rewrite; called by a timer once `delay` has passed (invariant 3).
    var fire: @MainActor () async -> Void = {}

    init(delay: Duration) {
        self.delay = delay
    }

    /// A change was saved: its writer rewrote the files from the saved labels (`exportsWritten`, a
    /// `VoiceProfileService` change), else they follow `delay` later.
    func changesSaved(exportsWritten: Bool) {
        if exportsWritten {
            written()
        } else {
            schedule()
        }
    }

    /// The files are behind the saved labels: rewritten `delay` from now (invariant 2), or once the review can run
    /// again.
    func schedule() {
        pending = true
        cancel()
        guard canRun() else { return }
        let delay = self.delay
        timer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            await self.fire()
        }
    }

    /// Something else rewrote the files from the saved labels (a writer, a relabel's command): nothing is pending.
    func written() {
        pending = false
        problem = nil
        cancel()
    }

    /// The queued rewrite succeeded. A timer started meanwhile still fires, and finds nothing pending.
    func regenerated() {
        pending = false
        problem = nil
    }

    /// The queued rewrite failed (`message` says why): the files stay pending.
    func failed(_ message: String) {
        problem = message
    }

    /// Stops a waiting timer (a pause, the close); `pending` stays as it is.
    func cancel() {
        timer?.cancel()
        timer = nil
    }
}
