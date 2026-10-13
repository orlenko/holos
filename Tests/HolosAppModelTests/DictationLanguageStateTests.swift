import HolosCore
import Testing
@testable import HolosAppModel

@Test @MainActor func overlappingAndReentrantAssetRefreshesRunOneOperation() async {
    let state = DictationLanguageState()
    var reads = 0
    state.refreshAssets {
        reads += 1
        state.refreshAssets { reads += 1; state.assetStatus = "unknown" }
        await Task.yield()
        state.assetStatus = "installed"
    }
    state.refreshAssets { reads += 1; state.assetStatus = "unknown" }
    await state.waitForRefresh()
    #expect(reads == 1)
    #expect(state.assetStatus == "installed")
    #expect(state.canResumeSetup)
    state.assetStatus = "unknown"
    #expect(!state.canResumeSetup)
}

@Test(.timeLimit(.minutes(1))) @MainActor func enableAndSettingsShareTheSameAssetRequest() async throws {
    let state = DictationLanguageState()
    var reads = 0
    var held: CheckedContinuation<String, Never>?
    let started = AsyncStream<Void>.makeStream()
    let joined = AsyncStream<Void>.makeStream()
    let reader: @MainActor @Sendable () async throws -> String = {
        reads += 1
        return await withCheckedContinuation { held = $0; started.continuation.yield(()) }
    }
    let first = Task { try await state.checkAssets(locale: "en-CA", backend: .speech, read: reader) }
    var starts = started.stream.makeAsyncIterator()
    _ = await starts.next()
    let second = Task {
        joined.continuation.yield(())
        return try await state.checkAssets(locale: "en-CA", backend: .speech, read: reader)
    }
    var joins = joined.stream.makeAsyncIterator()
    _ = await joins.next()
    held?.resume(returning: "installed"); held = nil
    #expect(try await first.value == "installed")
    #expect(try await second.value == "installed")
    #expect(reads == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor func aLateObsoleteRequestCannotClearTheRecoveredRequest() async throws {
    let state = DictationLanguageState()
    var oldHeld: CheckedContinuation<String, Never>?
    var newHeld: CheckedContinuation<String, Never>?
    var newReads = 0
    let oldStarted = AsyncStream<Void>.makeStream()
    let newStarted = AsyncStream<Void>.makeStream()
    let joined = AsyncStream<Void>.makeStream()
    let old = Task {
        try await state.checkAssets(locale: "en-CA", backend: .dictation) {
            await withCheckedContinuation { oldHeld = $0; oldStarted.continuation.yield(()) }
        }
    }
    var oldStarts = oldStarted.stream.makeAsyncIterator()
    _ = await oldStarts.next()
    let recovered = Task {
        try await state.checkAssets(locale: "en-CA", backend: .speech) {
            newReads += 1
            return await withCheckedContinuation { newHeld = $0; newStarted.continuation.yield(()) }
        }
    }
    var newStarts = newStarted.stream.makeAsyncIterator()
    _ = await newStarts.next()
    oldHeld?.resume(returning: "obsolete"); oldHeld = nil
    do {
        _ = try await old.value
        Issue.record("An obsolete request must not return late success")
    } catch { #expect(error is CancellationError) }
    let join = Task {
        joined.continuation.yield(())
        return try await state.checkAssets(locale: "en-CA", backend: .speech) {
            newReads += 1
            return "unexpected duplicate"
        }
    }
    var joins = joined.stream.makeAsyncIterator()
    _ = await joins.next()
    newHeld?.resume(returning: "installed"); newHeld = nil
    #expect(try await recovered.value == "installed")
    #expect(try await join.value == "installed")
    #expect(newReads == 1)
}
