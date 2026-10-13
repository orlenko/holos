import Foundation
import HolosCore

/// The app's language snapshot and asset-check bookkeeping; readers are injected by the app.
///
/// Invariants:
/// 1. All state is confined to the main actor; picker groups are derived from `locales`.
/// 2. Refresh requests coalesce through the entire operation, including language loading.
/// 3. Asset readers for the same locale/backend share one request; a changed pair cancels the obsolete request.
/// 4. Only the owning request clears its task slot, and a cancelled reader returns no successful result.
@MainActor
public final class DictationLanguageState {
    public var locales: RecognizerLocales?
    public var languageTask: Task<Void, Never>?
    public var assetStatus: String?
    /// Deferred setup acts only on a confirmed readiness result; a failed check waits for another check.
    public var canResumeSetup: Bool { ["installed", "supported", "downloading"].contains(assetStatus) }
    public var dictationGroups: [[String]] { DictationLanguage.groups(locales?.dictationLocales ?? []) }
    public var meetingGroups: [[String]] { DictationLanguage.groups(locales?.speech ?? []) }

    private struct Refresh: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private struct Check: Sendable {
        let id: UUID
        let locale: String
        let backend: SpeechBackend
        let task: Task<String, Error>
    }
    private var refresh: Refresh?
    private var check: Check?

    public init() {}
    deinit {
        languageTask?.cancel()
        refresh?.task.cancel()
        check?.task.cancel()
    }

    public func refreshAssets(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        guard refresh == nil else { return }  // invariant 2
        let id = UUID()
        let task = Task { [weak self] in
            await operation()
            if self?.refresh?.id == id { self?.refresh = nil }  // invariant 4
        }
        refresh = Refresh(id: id, task: task)
    }

    public func checkAssets(locale: String, backend: SpeechBackend,
                            read: @escaping @MainActor @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        if let check, check.locale == locale, check.backend == backend {
            let status = try await check.task.value  // invariant 3
            try Task.checkCancellation()
            return status
        }
        check?.task.cancel()
        let id = UUID()
        let task = Task {
            let status = try await read()
            try Task.checkCancellation()  // invariant 4: an uncooperative reader cannot return late success
            return status
        }
        check = Check(id: id, locale: locale, backend: backend, task: task)
        defer { if check?.id == id { check = nil } }
        let status = try await task.value
        try Task.checkCancellation()
        return status
    }

    func waitForRefresh() async { await refresh?.task.value }
}
