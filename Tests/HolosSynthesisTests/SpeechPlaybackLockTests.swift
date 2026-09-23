import Darwin
import Testing
@testable import HolosSynthesis

@MainActor @Test func zeroWaitAcquiresOnlyAnIdlePlaybackLock() async throws {
    guard let descriptor = try await SpeechPlayback.acquirePlaybackLock(maxWait: 0) else {
        Issue.record("An idle playback lock should be acquired immediately.")
        return
    }
    defer {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    let stale = try await SpeechPlayback.acquirePlaybackLock(maxWait: 0)
    #expect(stale == nil)
}
