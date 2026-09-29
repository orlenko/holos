import Foundation
import HolosCore
import HolosStorage

/// Writes the review page and its audio (`voiceislocal eval review`).
public enum EvalReview {
    /// Writes eval/review/<run>/review.html, and review-audio/<track>.m4a for each track that does not have one yet
    /// (the whole track, rendered as the run rendered it, so the page's times match). Without audio (Delete Audio
    /// removed it) the page is still written, and its play buttons do nothing. Returns the page's URL. The caller
    /// holds the session's processing lease.
    public static func build(session: URL, run: CloudRunRecord, report: CompareReport,
                             progress: @Sendable (String) -> Void = { _ in }) throws -> URL {
        let manifest = try SessionArchive.readManifest(at: session)
        let audioDeleted = try AudioDeletedRecord.isDeleted(session: session, sessionID: manifest.id)
        let folder = EvalPaths.review(run.id, in: session)
        let audioFolder = EvalPaths.reviewAudio(run.id, in: session)
        if !audioDeleted {
            // The page seeks with the run's time maps: the audio must still be what the run sent.
            for track in run.tracks
            where EvalStore.audioFingerprint(manifest: manifest, track: track.track) != track.audioFingerprint {
                throw HolosError.invalidInput("The \(track.track) audio changed since run \(run.id); its times no "
                    + "longer match the recording.")
            }
            try AtomicFile.ensurePrivateDirectory(audioFolder)
            // Half-written files a killed review left.
            for name in (try? FileManager.default.contentsOfDirectory(atPath: audioFolder.path)) ?? []
            where name.hasPrefix(".") && name.hasSuffix(".partial.m4a") {
                AtomicFile.removeRegularFile(audioFolder.appendingPathComponent(name))
            }
            let work = EvalPaths.work(run.id, in: session)
            defer { _ = try? AtomicFile.removeTree(["derived", "eval-cloud"], in: session) }
            for track in run.tracks {
                try Task.checkCancellation()
                let destination = audioFolder.appendingPathComponent("\(track.track).m4a")
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                progress("Preparing the \(track.track) audio for the page…")
                let render = work.appendingPathComponent("review-\(track.track).caf")
                let rendered = try EvalAudio.render(session: session, manifest: manifest, track: track.track,
                                                    to: render)
                // The samples too, segment by segment, when the run recorded their digests (every run made by a
                // build that records them does): other audio of the same length would pass the checks above.
                let recorded = track.segments.map(\.audioSHA256)
                let samplesMatch = try recorded.contains(nil) || EvalAudio.segmentDigests(
                    of: render, ranges: track.segments.map { ($0.startFrame, $0.endFrame) }).map(Optional.some)
                    == recorded
                guard rendered.frameCount == track.frameCount, rendered.timeMap.map(EvalSpan.init) == track.timeMap,
                      samplesMatch else {
                    throw HolosError.invalidInput("The \(track.track) audio changed since run \(run.id); its times "
                        + "no longer match the recording.")
                }
                try EvalAudio.writeM4A(from: render, startFrame: 0, endFrame: rendered.frameCount, to: destination)
                try? FileManager.default.removeItem(at: render)
            }
        }
        let data = EvalReviewPage.pageData(report: report, run: run, sessionName: manifest.name)
        let page = folder.appendingPathComponent("review.html")
        try EvalStore.writeData(Data(try EvalReviewPage.html(data).utf8), to: page)
        return page
    }
}
