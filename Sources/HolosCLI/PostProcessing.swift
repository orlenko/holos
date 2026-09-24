import Darwin
import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

/// The post-processor the CLI runs, after a recording and (from PR7b) for `holos session diarize`.
func makeMeetingPostProcessor(options: PostProcessingOptions = .init()) -> MeetingPostProcessor {
    MeetingPostProcessor(options: options)
}

/// The hook `holos record start` runs under the processing lease after the archive is finished.
/// It never throws: an error becomes a `.failed` record with the error's message.
func makePostProcessHook(options: PostProcessingOptions) -> PostProcessHook {
    { session, lease, progress in
        let startedAt = Date()
        do {
            return try await makeMeetingPostProcessor(options: options).run(session: session, lease: lease,
                                                                           progress: progress)
        } catch {
            let message = error is CancellationError ? "Post-processing was cancelled." : error.localizedDescription
            let sessionID = (try? SessionArchive.readManifest(at: session).id)
                ?? session.deletingPathExtension().lastPathComponent
            return PostProcessingRecord(sessionID: sessionID, state: .failed, pid: getpid(), startedAt: startedAt,
                                        updatedAt: Date(), message: message)
        }
    }
}
