import Foundation
import HolosCore
import Testing
@testable import HolosSpeech

@Test func boundedAssetRequestsKeepTheirOriginalErrors() async {
    do {
        let _: String = try await AppleSpeechEngine.boundedAssetCall(timeout: .seconds(1)) {
            throw HolosError.unavailable("Synthetic asset failure")
        }
        Issue.record("The request should fail")
    } catch {
        #expect(error.localizedDescription.contains("Synthetic asset failure"))
    }
}

@Test(.timeLimit(.minutes(1))) func aHungAssetRequestTimesOutWithoutWaitingForLateCompletion() async {
    let query = HeldLocaleQuery()
    do {
        _ = try await AppleSpeechEngine.boundedAssetCall(timeout: .milliseconds(10)) { await query.wait() }
        Issue.record("The request should time out")
    } catch {
        #expect(error.localizedDescription.contains("timed out"))
    }
    await query.release()
}

@Test @MainActor func aCancelledAssetRequestDoesNotStartPlatformWork() async {
    let task = Task {
        try await AppleSpeechEngine.boundedAssetCall(timeout: .seconds(1)) {
            Issue.record("A cancelled request must not start platform work")
            return "installed"
        }
    }
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("The request should be cancelled")
    } catch {
        #expect(error is CancellationError)
    }
}
