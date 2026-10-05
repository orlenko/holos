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
    /// With verdict `echo`: the frames file, `echo/frames.bin` (`AcousticEchoMask.bytes`).
    public var frames: Frames?
    /// Seconds the analysis took.
    public var seconds: Double?

    public struct Frames: Codable, Sendable, Equatable {
        public var count: Int
        public var hopSeconds: Double
        public var firstCentreSeconds: Double
        /// SHA-256 of frames.bin: a frames file left by another analysis is never read with this record.
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
    /// 2 bytes a frame, 62.5 frames a second: about 450 KB an hour.
    static let maximumFramesBytes = 64 << 20

    public static func directory(_ session: URL) -> URL { SessionPaths.echoDirectory(session) }
    public static func recordURL(_ session: URL) -> URL { SessionPaths.echoMask(session) }
    public static func framesURL(_ session: URL) -> URL { SessionPaths.echoFrames(session) }

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

    /// The stored analysis when it is of this session's audio as it is now and of this analysis version; nil when
    /// there is none, it is out of date, or it is damaged (its frames file missing or not the one the record names).
    /// One written by a newer Voice is Local is refused (`unavailable`); one that cannot be read now throws.
    public static func current(session: URL, manifest: SessionManifest) throws -> Stored? {
        guard let data = try AtomicFile.readIfPresent(recordURL(session), maxBytes: 1 << 20) else { return nil }
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
        guard let frames = record.frames,
              let bytes = try AtomicFile.readIfPresent(framesURL(session), maxBytes: maximumFramesBytes),
              SessionExports.sha256(bytes) == frames.sha256,
              let mask = AcousticEchoMask(bytes: bytes, frameCount: frames.count) else {
            log.error("Session \(manifest.id, privacy: .public): echo/frames.bin is missing or does not match echo/mask.json")
            return nil
        }
        return Stored(record: record, mask: mask)
    }

    /// Writes the frames file (or removes a stale one), then the record, which names the frames by their hash.
    /// Callers hold the session's processing lease.
    static func write(_ record: EchoMaskRecord, mask: AcousticEchoMask?, session: URL) throws {
        try AtomicFile.ensurePrivateDirectory(directory(session))
        if let mask {
            try AtomicFile.write(mask.bytes, to: framesURL(session))
        } else {
            try AtomicFile.removeTree([folder, "frames.bin"], in: session)
        }
        try AtomicFile.writeJSON(record, to: recordURL(session))
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
        let result: EchoAnalysis.Result
        if let system {
            guard let microphone else {
                throw HolosError.invalidInput("The microphone audio was not prepared for the echo analysis.")
            }
            result = try EchoAnalysis.analyze(microphone: RenderedEchoAudio(microphone),
                                              system: RenderedEchoAudio(system), progress: progress)
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
            guard let frames = record.frames, frames.echo + frames.local > 0 else {
                return "Microphone echo found, \(delay) behind the call."
            }
            let share = Int((Double(frames.echo) / Double(frames.echo + frames.local) * 100).rounded())
            return "Microphone echo found, \(delay) behind the call: \(share) % of the microphone's sound is echo."
        case .noEcho:
            return "The microphone did not pick up the call (headphones?), so nothing was taken out as echo."
        case .noSystemAudio:
            return "The meeting has no system audio, so the microphone has no echo of it."
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
        file = opened
        let frames = Int(bytes / 2)
        renderFrames = frames
        let rate = rendered.sampleRate
        if rendered.timeMap.isEmpty {
            spans = [Span(session: 0, render: 0, count: frames)]
        } else {
            spans = rendered.timeMap.map { span in
                let render = Int((span.renderStart * rate).rounded())
                let end = Int(((span.renderStart + span.duration) * rate).rounded())
                return Span(session: Int((span.sessionStart * rate).rounded()), render: render,
                            count: max(0, min(end, frames) - render))
            }
        }
        sampleCount = spans.map { $0.session + $0.count }.max() ?? 0
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
