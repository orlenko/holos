import Accelerate
import AudioToolbox
import Foundation
import HolosAudio
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Contents of `echo/mask.json` (docs/meeting-design.md §5.11): the acoustic echo analysis of a call's audio. It is
/// kept in the meeting folder, not in `derived/` (deleted after every run), and is keyed to the audio it was computed
/// from, so a relabel reuses it and an analysis of other audio, or of another analysis version, is never used.
public struct EchoMaskRecord: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var schemaVersion: Int
    public var sessionID: String
    /// `EchoAnalysis.version` of the analysis that made it.
    public var analysisVersion: Int
    /// The audio it was computed from: `EvalStore.audioFingerprint` of the "mic" and "system" tracks (a track without
    /// saved audio is absent). A record whose key is not the meeting's now is out of date.
    public var audio: [String: String]
    public var createdAt: Date
    public var verdict: EchoAnalysis.Verdict
    public var delay: EchoAnalysis.DelayFit?
    /// With verdict `echo`: the frames file, `echo/frames-<sha>.bin` (`AcousticEchoMask.bytes`).
    public var frames: Frames?
    /// Seconds the analysis took.
    public var seconds: Double?

    public struct Frames: Codable, Sendable, Equatable {
        public var count: Int
        public var hopSeconds: Double
        public var firstCentreSeconds: Double
        /// SHA-256 of the frames file, which is named by it (`EchoMaskStore.framesURL(sha256:)`): a frames file left by
        /// another analysis is never read with this record.
        public var sha256: String
        public var echo: Int
        public var local: Int

        public init(count: Int, hopSeconds: Double, firstCentreSeconds: Double, sha256: String, echo: Int,
                    local: Int) {
            self.count = count; self.hopSeconds = hopSeconds; self.firstCentreSeconds = firstCentreSeconds
            self.sha256 = sha256; self.echo = echo; self.local = local
        }
    }

    public init(schemaVersion: Int = currentVersion, sessionID: String, analysisVersion: Int = EchoAnalysis.version,
                audio: [String: String], createdAt: Date = Date(), verdict: EchoAnalysis.Verdict,
                delay: EchoAnalysis.DelayFit? = nil, frames: Frames? = nil, seconds: Double? = nil) {
        self.schemaVersion = schemaVersion; self.sessionID = sessionID; self.analysisVersion = analysisVersion
        self.audio = audio; self.createdAt = createdAt; self.verdict = verdict; self.delay = delay
        self.frames = frames; self.seconds = seconds
    }
}

/// Reads and writes `echo/` (docs/meeting-design.md §5.11).
public enum EchoMaskStore {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    static let folder = "echo"
    static let recordName = "echo/mask.json"
    /// The longest call the echo analysis takes: 12 hours. The analysis holds every frame's powers and levels in
    /// memory at once (2.7 million frames at 12 hours). Measured with the release CLI (`session echo-analyze`, peak
    /// memory footprint): 115 MB for a 53-minute call and 133 MB for 1 h 47 min, about 20 MB more per hour, so about
    /// 330 MB at 12 hours, which a Mac running Voice is Local holds comfortably. A longer call is not analysed
    /// (`tooLong`).
    static let maximumSeconds = 12 * 3_600

    /// The longest mask kept, in frames (`maximumSeconds` of 16 ms frames): the one limit on a call's length for the
    /// analysis. The reader reads frames files up to this size (2 bytes a frame, about 450 KB an hour), and a longer
    /// call is not analysed but saved as `tooLong`, which counts as done (`EchoAnalysisStage.analyze`). A task-local
    /// value so tests can make it small.
    @TaskLocal static var maximumFrames = Int((Double(maximumSeconds) / AcousticEchoMask.hopSeconds).rounded())

    /// The bytes of a frames file of `maximumFrames`.
    static var maximumFramesBytes: Int { 2 * maximumFrames }

    /// The longest audio the analysis takes, in samples: `maximumFrames` hops.
    static var maximumSamples: Int {
        maximumFrames * Int((AcousticEchoMask.hopSeconds * Double(EchoAnalysis.sampleRate)).rounded())
    }

    public static func directory(_ session: URL) -> URL { SessionPaths.echoDirectory(session) }
    public static func recordURL(_ session: URL) -> URL { SessionPaths.echoMask(session) }

    /// The frames file of a mask whose bytes have SHA-256 `sha256`: `echo/frames-<first 16 hex digits>.bin`. Named by
    /// its content, so a new mask never overwrites the one the record still names (`write`). Nil for a value that is
    /// not a SHA-256 in lowercase hex (a damaged record never names a path).
    public static func framesURL(_ session: URL, sha256: String) -> URL? {
        guard sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return directory(session).appendingPathComponent("frames-\(sha256.prefix(16)).bin", isDirectory: false)
    }

    /// The frames files in `echo/` (the current one and any a write left behind).
    public static func framesFiles(_ session: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(session).path)) ?? []
        return names.filter { $0.hasPrefix("frames") && $0.hasSuffix(".bin") }.sorted()
            .map { directory(session).appendingPathComponent($0, isDirectory: false) }
    }

    /// Test hook: while set (a task-local value), called after a new frames file is written and before the record
    /// that names it.
    @TaskLocal static var afterFramesWritten: (@Sendable () throws -> Void)? = nil

    /// Test hook: while set (a task-local value), called before each old frames file is deleted.
    @TaskLocal static var removeFrames: (@Sendable (URL) throws -> Void)? = nil

    /// A record with its mask (nil unless the verdict is `echo`).
    public struct Stored: Sendable {
        public var record: EchoMaskRecord
        public var mask: AcousticEchoMask?
    }

    /// The analysis key of `manifest`'s audio.
    static func audioKey(manifest: SessionManifest) -> [String: String] {
        var key: [String: String] = [:]
        for track in EchoAnalysisStage.tracks where manifest.chunks.contains(where: { $0.track == track }) {
            key[track] = EvalStore.audioFingerprint(manifest: manifest, track: track)
        }
        return key
    }

    private struct AnalysisVersionProbe: Decodable { var analysisVersion: Int? }

    /// The stored analysis when it is of this session's audio as it is now and of this analysis version; nil when
    /// there is none, it is out of date (other audio, or an older analysis version), or it is damaged (its frames
    /// file missing or not the one the record names). One written by a newer Voice is Local, by its schema or by its
    /// analysis version, is refused (`unavailable`), so it is never overwritten; one that cannot be read now throws.
    public static func current(session: URL, manifest: SessionManifest) throws -> Stored? {
        guard let data = try AtomicFile.readIfPresent(recordURL(session), maxBytes: 1 << 20) else { return nil }
        // Checked before the whole record is decoded: a newer analysis may use values this build does not know (a
        // new verdict), which must not read as damage and be analysed over.
        if let version = (try? HolosJSON.decoder().decode(AnalysisVersionProbe.self, from: data))?.analysisVersion,
           version > EchoAnalysis.version {
            throw HolosError.unavailable("\(recordName) was made by a newer version of Voice is Local; update Voice "
                                         + "is Local to use it.")
        }
        let record: EchoMaskRecord
        do {
            record = try SessionFiles.decode(EchoMaskRecord.self, from: data, current: EchoMaskRecord.currentVersion,
                                             name: recordName)
        } catch let error where SessionFiles.isDamage(error) {
            log.error("Session \(manifest.id, privacy: .public): \(recordName, privacy: .public) unusable: \(error.localizedDescription, privacy: .private)")
            return nil
        }
        guard record.sessionID == manifest.id, record.analysisVersion == EchoAnalysis.version,
              record.audio == audioKey(manifest: manifest) else { return nil }
        guard record.verdict == .echo else { return Stored(record: record, mask: nil) }
        guard let frames = record.frames, let url = framesURL(session, sha256: frames.sha256),
              let bytes = try AtomicFile.readIfPresent(url, maxBytes: maximumFramesBytes),
              SessionExports.sha256(bytes) == frames.sha256,
              let mask = AcousticEchoMask(bytes: bytes, frameCount: frames.count) else {
            log.error("Session \(manifest.id, privacy: .public): the frames file echo/mask.json names is missing or does not match it")
            return nil
        }
        // The summary counts are the mask's own, never the file's (which may be anything).
        var checked = record
        checked.frames?.echo = mask.classes.filter { $0 == AcousticEchoMask.FrameClass.echo.rawValue }.count
        checked.frames?.local = mask.classes.filter { $0 == AcousticEchoMask.FrameClass.local.rawValue }.count
        return Stored(record: checked, mask: mask)
    }

    /// The mask the labels are shown with (`SpeakerSessionSnapshot`): the stored mask of the audio as it is now and of
    /// this analysis version; nil without one, whatever the reason (none, out of date, damaged, written by a newer
    /// build, or not readable now). The labels are then shown without hiding acoustic echo; never an error.
    public static func usable(session: URL, manifest: SessionManifest) -> AcousticEchoMask? {
        usableWithIdentity(session: session, manifest: manifest).mask
    }

    /// `usable`, with its identity: the SHA-256 of its frames, nil without a mask (a saved `noEcho` or
    /// `noSystemAudio` verdict hides nothing, so it is nil too). The snapshot keeps the identity of the mask it shows,
    /// and the transcript files record it when written (`SessionExports`), so a mask saved, replaced or dropped since
    /// makes them out of date.
    static func usableWithIdentity(session: URL, manifest: SessionManifest)
        -> (mask: AcousticEchoMask?, identity: String?) {
        do {
            guard let stored = try current(session: session, manifest: manifest), let mask = stored.mask else {
                return (nil, nil)
            }
            return (mask, stored.record.frames?.sha256)
        } catch {
            log.error("Session \(manifest.id, privacy: .public): echo analysis not used: \(error.localizedDescription, privacy: .private)")
            return (nil, nil)
        }
    }

    /// `usableWithIdentity`'s identity alone.
    public static func identity(session: URL, manifest: SessionManifest) -> String? {
        usableWithIdentity(session: session, manifest: manifest).identity
    }

    /// Writes the new frames file under its own name (`framesURL(sha256:)`), then switches the record to it, then
    /// deletes every other frames file. A failure before the switch leaves the record naming the old file, which is
    /// still there, so the old mask stays in use; a failure after it leaves only an unused file, removed by the next
    /// write. Callers hold the session's processing lease and not the speaker lock: this takes it (§1.7 order: lease,
    /// speakers, profiles), because the mask changes what the labels show. A writer that checks the labels and the echo
    /// files under the speaker lock (a voice sample being published) then sees either both files before or both after.
    static func write(_ record: EchoMaskRecord, mask: AcousticEchoMask?, session: URL) throws {
        var keep: URL?
        if let mask {
            guard let sha256 = record.frames?.sha256, sha256 == SessionExports.sha256(mask.bytes),
                  let url = framesURL(session, sha256: sha256) else {
                throw HolosError.invalidInput("The echo analysis record does not name its frames.")
            }
            keep = url
        }
        try SessionArchive.withSpeakerLock(at: session) {
            try AtomicFile.ensurePrivateDirectory(directory(session))
            if let mask, let keep {
                try AtomicFile.write(mask.bytes, to: keep)
                try afterFramesWritten?()
            }
            try AtomicFile.writeJSON(record, to: recordURL(session))
            // The save is done: a file left over is never read (the record names another) and the next save removes
            // it, so a failure here is only logged.
            for url in framesFiles(session) where url.lastPathComponent != keep?.lastPathComponent {
                do {
                    try removeFrames?(url)
                    try AtomicFile.removeTree([folder, url.lastPathComponent], in: session)
                } catch {
                    log.error("Cannot delete an old echo frames file: \(error.localizedDescription, privacy: .private)")
                }
            }
        }
    }
}

/// The post-processor's echo stage (docs/meeting-design.md §5.11) and what `voiceislocal session echo-analyze` shares
/// with it.
enum EchoAnalysisStage {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    static let tracks = ["mic", "system"]

    /// A call with microphone audio gets the analysis.
    static func applies(meeting: MeetingInfo, manifest: SessionManifest) -> Bool {
        meeting.mode == .call && manifest.chunks.contains { $0.track == "mic" }
    }

    /// The tracks the analysis renders: both, or none when the meeting has no system audio (nothing to analyse).
    static func renderTracks(manifest: SessionManifest) -> [String] {
        manifest.chunks.contains { $0.track == "system" } ? tracks : []
    }

    enum Saved {
        /// The stored analysis of the audio as it is now.
        case current(EchoMaskStore.Stored)
        /// None, or out of date, or damaged: analyse.
        case missing
        /// Written by a newer Voice is Local: left alone, and not used.
        case newer

        var mask: AcousticEchoMask? {
            if case .current(let stored) = self { return stored.mask }
            return nil
        }
    }

    /// Whether the meeting still needs its analysis, worked out from its files alone (nothing records pending work):
    /// a call with microphone and system audio, its audio kept, and no saved analysis of that audio and this analysis
    /// version. Any saved verdict counts as done (`noEcho`, `noSystemAudio` too), and so does one a newer build saved
    /// (it is left alone). False when the files that decide it cannot be read.
    static func needed(session: URL) -> Bool {
        guard let manifest = try? SessionArchive.readManifest(at: session),
              let meeting = try? SessionFiles.meetingInfo(session: session, manifest: manifest),
              applies(meeting: meeting, manifest: manifest), !renderTracks(manifest: manifest).isEmpty,
              (try? SessionFiles.audioDeleted(session: session, sessionID: manifest.id)) == false else { return false }
        if case .missing = saved(session: session, manifest: manifest) { return true }
        return false
    }

    /// Renders both tracks to `derived/`, analyses them and saves the result, deleting `derived/` before and after:
    /// for a pass with no renders of its own (`voiceislocal session echo-analyze`, Recover). Caller holds the
    /// processing lease. Throws when a track cannot be rendered or there is too little disk space; nothing is saved
    /// then, so the analysis is still needed and the next pass tries again.
    static func analyzeSession(session: URL, manifest: SessionManifest, freeSpace: any FreeSpaceProvider,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> EchoMaskStore.Stored {
        let tracks = renderTracks(manifest: manifest)
        guard !tracks.isEmpty else {
            return try analyze(session: session, manifest: manifest, microphone: nil, system: nil)
        }
        try AtomicFile.removeTree(["derived"], in: session)
        defer {
            do {
                try AtomicFile.removeTree(["derived"], in: session)
            } catch {
                log.error("Session \(manifest.id, privacy: .public): cannot delete derived/: \(error.localizedDescription, privacy: .private)")
            }
        }
        let seconds = tracks.reduce(0) { $0 + TrackRenderer.renderedSeconds(manifest: manifest, track: $1) }
        if let free = try? freeSpace.availableBytes(at: SessionPaths.derived(session)),
           !SpeakerAnalysis.renderAllowed(freeBytes: free, renderSeconds: seconds) {
            throw HolosError.unavailable("Not enough disk space to prepare the audio. Free some space, then try again.")
        }
        var renders: [String: RenderedTrack] = [:]
        for track in tracks {
            progress("Preparing the \(SpeakerAnalysis.trackAudioLabel(track))…")
            renders[track] = try TrackRenderer.render(session: session, manifest: manifest, track: track,
                                                      to: SessionPaths.render(track: track, in: session))
        }
        progress("Finding microphone echo…")
        return try analyze(session: session, manifest: manifest, microphone: renders["mic"], system: renders["system"])
    }

    /// The stored analysis, as the post-processor decides on it. A file that cannot be read now counts as missing
    /// (analysed again).
    static func saved(session: URL, manifest: SessionManifest) -> Saved {
        do {
            return try EchoMaskStore.current(session: session, manifest: manifest).map(Saved.current) ?? .missing
        } catch {
            if case .unavailable? = error as? HolosError { return .newer }
            log.error("Session \(manifest.id, privacy: .public): cannot read the echo analysis: \(error.localizedDescription, privacy: .private)")
            return .missing
        }
    }

    /// Analyses the renders and saves the result. Without `system` (the meeting has no system audio) nothing is read
    /// and the verdict is `noSystemAudio`. `progress` gets 0…1.
    static func analyze(session: URL, manifest: SessionManifest, microphone: RenderedTrack?, system: RenderedTrack?,
                        progress: (@Sendable (Double) -> Void)? = nil) throws -> EchoMaskStore.Stored {
        let clock = ContinuousClock()
        let started = clock.now
        var result: EchoAnalysis.Result
        if let system {
            guard let microphone else {
                throw HolosError.invalidInput("The microphone audio was not prepared for the echo analysis.")
            }
            let microphoneAudio = try RenderedEchoAudio(microphone)
            let systemAudio = try RenderedEchoAudio(system)
            // Longer than a mask is kept for: saved as too long (done), never a frames file no read accepts.
            if max(microphoneAudio.sampleCount, systemAudio.sampleCount) > EchoMaskStore.maximumSamples {
                result = EchoAnalysis.Result(verdict: .tooLong)
            } else {
                result = try EchoAnalysis.analyze(microphone: microphoneAudio, system: systemAudio, progress: progress)
            }
            if let mask = result.mask, mask.frameCount > EchoMaskStore.maximumFrames {
                result = EchoAnalysis.Result(verdict: .tooLong)
            }
        } else {
            result = EchoAnalysis.Result(verdict: .noSystemAudio)
        }
        let elapsed = started.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var frames: EchoMaskRecord.Frames?
        if let mask = result.mask {
            frames = EchoMaskRecord.Frames(
                count: mask.frameCount, hopSeconds: AcousticEchoMask.hopSeconds,
                firstCentreSeconds: AcousticEchoMask.firstCentreSeconds, sha256: SessionExports.sha256(mask.bytes),
                echo: mask.classes.filter { $0 == AcousticEchoMask.FrameClass.echo.rawValue }.count,
                local: mask.classes.filter { $0 == AcousticEchoMask.FrameClass.local.rawValue }.count)
        }
        let record = EchoMaskRecord(sessionID: manifest.id, audio: EchoMaskStore.audioKey(manifest: manifest),
                                    verdict: result.verdict, delay: result.delay, frames: frames, seconds: seconds)
        try EchoMaskStore.write(record, mask: result.mask, session: session)
        log.notice("Session \(manifest.id, privacy: .public): echo analysis \(result.verdict.rawValue, privacy: .public) in \(seconds, privacy: .public) s")
        return EchoMaskStore.Stored(record: record, mask: result.mask)
    }

    /// One sentence for the stage outcome and the command: "Microphone echo found, 46.1 ms behind the call: 70 % of
    /// the microphone's sound is echo."
    static func message(_ record: EchoMaskRecord) -> String {
        switch record.verdict {
        case .echo:
            let delay = record.delay?.milliseconds(at: 0).map { String(format: "%.1f ms", $0) } ?? "some time"
            // In floating point, so counts read from a file can never overflow.
            guard let frames = record.frames, frames.echo >= 0, frames.local >= 0,
                  Double(frames.echo) + Double(frames.local) > 0 else {
                return "Microphone echo found, \(delay) behind the call."
            }
            let share = Int((Double(frames.echo) / (Double(frames.echo) + Double(frames.local)) * 100).rounded())
            return "Microphone echo found, \(delay) behind the call: \(share) % of the microphone's sound is echo."
        case .noEcho:
            return "The microphone did not pick up the call (headphones?), so nothing is hidden as echo."
        case .noSystemAudio:
            return "The meeting has no system audio, so the microphone has no echo of it."
        case .tooLong:
            let hours = Int(Double(EchoMaskStore.maximumSamples) / Double(EchoAnalysis.sampleRate) / 3600)
            return "The call is longer than the echo check handles (\(hours) hours), so nothing is hidden as echo."
        }
    }
}

/// A track's render (`derived/<track>-16k.caf`, 16 kHz mono Int16) read on the session timeline through its time map:
/// session time outside every span (a long gap shortened in the render) reads as silence.
///
/// `@unchecked Sendable`: the AudioFile is opened read-only in `init`, every read goes through `lock`, and it is closed
/// only in `deinit`.
final class RenderedEchoAudio: EchoAudioSource, @unchecked Sendable {
    private struct Span {
        var session: Int
        var render: Int
        var count: Int
    }

    let sampleCount: Int
    private let file: AudioFileID
    private let renderFrames: Int
    private let spans: [Span]
    private let lock = NSLock()

    init(_ rendered: RenderedTrack) throws {
        guard rendered.sampleRate == Double(EchoAnalysis.sampleRate) else {
            throw HolosError.invalidInput("The echo analysis needs 16 kHz audio.")
        }
        var opened: AudioFileID?
        guard AudioFileOpenURL(rendered.url as CFURL, .readPermission, kAudioFileCAFType, &opened) == noErr,
              let opened else {
            throw HolosError.io("Cannot open the prepared \(rendered.track) audio for the echo analysis.")
        }
        var bytes: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        guard AudioFileGetProperty(opened, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr else {
            AudioFileClose(opened)
            throw HolosError.io("Cannot read the prepared \(rendered.track) audio for the echo analysis.")
        }
        let frames = Int(bytes / 2)
        let rate = rendered.sampleRate
        var spans: [Span] = []
        if rendered.timeMap.isEmpty {
            spans = [Span(session: 0, render: 0, count: frames)]
        } else {
            for span in rendered.timeMap {
                // Times come from the manifest: one far outside any meeting would trap when made an index.
                guard let session = Self.sampleIndex(span.sessionStart, rate: rate),
                      let render = Self.sampleIndex(span.renderStart, rate: rate),
                      let end = Self.sampleIndex(span.renderStart + span.duration, rate: rate) else {
                    AudioFileClose(opened)
                    throw HolosError.invalidInput("The prepared \(rendered.track) audio's timing is out of range, so "
                                                  + "its echo cannot be analysed.")
                }
                spans.append(Span(session: session, render: render, count: max(0, min(end, frames) - render)))
            }
        }
        var count = 0
        for span in spans {
            let (end, overflow) = span.session.addingReportingOverflow(span.count)
            guard !overflow, end <= Self.representable else {
                AudioFileClose(opened)
                throw HolosError.invalidInput("The prepared \(rendered.track) audio's timing is out of range, so its "
                                              + "echo cannot be analysed.")
            }
            count = max(count, end)
        }
        file = opened
        renderFrames = frames
        self.spans = spans
        sampleCount = count
    }

    /// The largest sample index taken (2^53, where a Double still counts every sample): times past it are damage, and
    /// would trap when made an `Int`. How long a call the analysis takes is `EchoMaskStore.maximumSamples`, checked
    /// on `sampleCount` (`EchoAnalysisStage.analyze`).
    static let representable = 1 << 53

    /// `seconds × rate` rounded, as a sample index; nil when it is not finite or not within ±`representable`.
    static func sampleIndex(_ seconds: Double, rate: Double) -> Int? {
        let value = (seconds * rate).rounded()
        guard value.isFinite, abs(value) <= Double(representable) else { return nil }
        return Int(value)
    }

    deinit { AudioFileClose(file) }

    func read(from start: Int, count: Int, into destination: UnsafeMutablePointer<Float>) throws {
        guard count > 0 else { return }
        destination.update(repeating: 0, count: count)
        try lock.withLock {
            for span in spans {
                let lower = max(start, span.session)
                let upper = min(start + count, span.session + span.count)
                guard lower < upper else { continue }
                try readRender(from: span.render + (lower - span.session), count: upper - lower,
                               into: destination + (lower - start))
            }
        }
    }

    private func readRender(from frame: Int, count: Int, into destination: UnsafeMutablePointer<Float>) throws {
        let first = max(0, frame)
        let end = min(renderFrames, frame + count)
        guard first < end else { return }
        var samples = [Int16](repeating: 0, count: end - first)
        var bytes = UInt32((end - first) * 2)
        let status = samples.withUnsafeMutableBytes { raw in
            AudioFileReadBytes(file, false, Int64(first) * 2, &bytes, raw.baseAddress!)
        }
        guard status == noErr else { throw HolosError.io("Cannot read the prepared audio for the echo analysis.") }
        let read = Int(bytes) / 2
        let target = destination + (first - frame)
        samples.withUnsafeBufferPointer { buffer in
            vDSP_vflt16(buffer.baseAddress!, 1, target, 1, vDSP_Length(read))
        }
        var scale = Float(1.0 / 32_768.0)
        vDSP_vsmul(target, 1, &scale, target, 1, vDSP_Length(read))
    }
}
