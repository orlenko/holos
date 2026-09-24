import AudioToolbox
import AVFoundation
import Darwin
import Foundation
import HolosCore
import HolosStorage
import os

// MARK: - Render time map

/// One stretch of a render that is session audio: `duration` seconds from `renderStart` in the rendered file are
/// the session timeline from `sessionStart` (docs/meeting-design.md §4.7). Short gaps inside a span are rendered as
/// silence of their real length, so the mapping is linear across the whole span.
public struct RenderSpan: Sendable, Equatable {
    public var renderStart: Double
    public var sessionStart: Double
    public var duration: Double

    public init(renderStart: Double, sessionStart: Double, duration: Double) {
        self.renderStart = renderStart; self.sessionStart = sessionStart; self.duration = duration
    }
}

/// A track rendered for diarization: one mono 16 kHz 16-bit integer CAF.
public struct RenderedTrack: Sendable, Equatable {
    public var url: URL
    public var track: String
    /// 16,000.
    public var sampleRate: Double
    public var frameCount: Int
    /// The render's spans in render order; render time outside every span is inserted silence.
    public var timeMap: [RenderSpan]

    public init(url: URL, track: String, sampleRate: Double, frameCount: Int, timeMap: [RenderSpan]) {
        self.url = url; self.track = track; self.sampleRate = sampleRate; self.frameCount = frameCount
        self.timeMap = timeMap
    }
}

/// Maps times in a render back to the session timeline (docs/meeting-design.md §4.7).
public enum RenderTimeMap {
    /// A time inside a span maps linearly; a time inside inserted silence (before the first span, between spans,
    /// or after the last) snaps to the session time of the nearest span edge (the earlier edge on a tie). An empty
    /// map or a time that is not a number is returned unchanged.
    public static func sessionTime(_ renderTime: Double, map: [RenderSpan]) -> Double {
        guard renderTime.isFinite, !map.isEmpty else { return renderTime }
        for span in map where renderTime >= span.renderStart && renderTime <= span.renderStart + span.duration {
            return span.sessionStart + (renderTime - span.renderStart)
        }
        var best: (distance: Double, session: Double)?
        for span in map {
            let edges = [(span.renderStart, span.sessionStart),
                         (span.renderStart + span.duration, span.sessionStart + span.duration)]
            for (render, session) in edges {
                let distance = abs(renderTime - render)
                if best == nil || distance < best!.distance { best = (distance, session) }
            }
        }
        return best?.session ?? renderTime
    }

    /// `output` with every segment and embedding window in session time. A segment or window is cut at the span
    /// edges: each part inside a span maps linearly and parts inside inserted silence are dropped, so one that
    /// crosses a compressed gap becomes two (a window's parts keep its vector). Entries with times that are not
    /// numbers, or with no part inside a span, are dropped. Centroids and the processing time are unchanged. An
    /// empty map returns `output` unchanged.
    public static func map(_ output: DiarizerOutput, map: [RenderSpan]) -> DiarizerOutput {
        guard !map.isEmpty else { return output }
        var mapped = output
        mapped.segments = output.segments.flatMap { segment in
            pieces(segment.start, segment.end, map).map { start, end in
                RawDiarizationSegment(speaker: segment.speaker, start: start, end: end, quality: segment.quality)
            }
        }
        mapped.windows = output.windows.flatMap { window in
            pieces(window.start, window.end, map).map { start, end in
                EmbeddingWindow(speaker: window.speaker, start: start, end: end, vector: window.vector)
            }
        }
        return mapped
    }

    /// The parts of render interval [start, end) inside each span, in session time.
    private static func pieces(_ start: Double, _ end: Double, _ map: [RenderSpan]) -> [(Double, Double)] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        var result: [(Double, Double)] = []
        for span in map {
            let lower = max(start, span.renderStart)
            let upper = min(end, span.renderStart + span.duration)
            guard upper - lower > 1e-9 else { continue }
            result.append((span.sessionStart + (lower - span.renderStart),
                           span.sessionStart + (upper - span.renderStart)))
        }
        return result
    }
}

// MARK: - Renderer

/// Renders one track of a session for diarization (docs/meeting-design.md §4.7): its finalized chunks joined into
/// one mono 16 kHz 16-bit integer CAF on the session timeline, with long gaps shortened.
public enum TrackRenderer {
    /// The render's sample rate.
    public static let sampleRate = 16_000.0
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")
    /// Frames per read, conversion, and write block.
    static let blockFrames = 4_096

    /// Joins a track's finalized chunks into one mono 16 kHz Int16 CAF. Channels are averaged; gaps up to
    /// `compressGapsLongerThan` are silence, longer gaps (and a long lead-in) become `keptSilence` seconds;
    /// one AVAudioConverter per contiguous run of chunks (reset at gaps). Checks cancellation per chunk.
    ///
    /// Details:
    /// - Chunks are read in (start, path) order through descriptors opened without following a symbolic link
    ///   (`AtomicFile.openForReading`). A chunk whose file is missing, unreadable, shorter than its manifest entry,
    ///   or of another sample rate or channel count than the manifest says makes the render throw.
    /// - A chunk that starts before the audio already placed ends (legacy archives) has its leading samples
    ///   skipped, and one that lies entirely before it is skipped, so no sample is written twice.
    /// - Each run of chunks that follow each other without a gap, at one sample rate, is resampled by one
    ///   converter and placed at its time-map position, padded or trimmed to the length its session time gives, so
    ///   converter rounding never shifts later audio.
    /// - `output` (and a missing parent folder) is written like `AtomicFile.writeStream`: nothing is published
    ///   when the render fails or is cancelled.
    public static func render(session: URL, manifest: SessionManifest, track: String, to output: URL,
                              compressGapsLongerThan: Double = 60, keptSilence: Double = 5,
                              progress: (@Sendable (Double) -> Void)? = nil) throws -> RenderedTrack {
        let plan = try RenderPlan(manifest: manifest, track: track, compressGapsLongerThan: compressGapsLongerThan,
                                  keptSilence: keptSilence)
        try Task.checkCancellation()
        let totalFrames = frameIndex(plan.duration)
        let meter = ProgressMeter(total: plan.inputFrames, report: progress)
        try AtomicFile.ensurePrivateDirectory(output.deletingLastPathComponent())
        try AtomicFile.writeStream(to: output) { descriptor in
            let writer = try Int16CAFWriter(descriptor: descriptor, sampleRate: sampleRate)
            do {
                var position = 0
                for run in plan.runs {
                    let start = frameIndex(run.renderStart)
                    let end = max(start, frameIndex(run.renderEnd))
                    try writer.writeSilence(start - position)
                    try renderRun(run, session: session, frames: end - start, writer: writer, meter: meter)
                    position = end
                }
                try writer.writeSilence(totalFrames - position)
                try writer.close()
            } catch {
                writer.abandon()
                throw error
            }
        }
        progress?(1)
        log.info("Rendered \(track, privacy: .public): \(plan.chunkCount, privacy: .public) chunks, \(totalFrames, privacy: .public) frames, \(plan.spans.count, privacy: .public) spans")
        return RenderedTrack(url: output, track: track, sampleRate: sampleRate, frameCount: totalFrames,
                             timeMap: plan.spans)
    }

    /// Seconds a render of `track` lasts (gaps compressed as `render` does), without reading audio: what the
    /// post-processor's disk check budgets for. 0 when the track has no chunks.
    public static func renderedSeconds(manifest: SessionManifest, track: String,
                                       compressGapsLongerThan: Double = 60, keptSilence: Double = 5) -> Double {
        (try? RenderPlan(manifest: manifest, track: track, compressGapsLongerThan: compressGapsLongerThan,
                         keptSilence: keptSilence).duration) ?? 0
    }

    /// The render frame at render time `seconds`.
    static func frameIndex(_ seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * sampleRate).rounded())
    }

    /// Writes exactly `frames` frames for `run`: the converter's output, trimmed or padded with silence.
    private static func renderRun(_ run: RenderPlan.Run, session: URL, frames: Int, writer: Int16CAFWriter,
                                  meter: ProgressMeter) throws {
        let reader = RunReader(run: run, session: session, meter: meter)
        var remaining = frames
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: run.sampleRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(blockFrames)),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(blockFrames)) else {
            throw HolosError.io("Cannot allocate audio buffers for the render.")
        }
        if run.sampleRate == sampleRate {
            // Already 16 kHz: no resampling.
            while remaining > 0 {
                let count = try reader.read(into: input)
                guard count > 0 else { break }
                let kept = min(count, remaining)
                try writer.write(output: input, frames: kept)
                remaining -= kept
            }
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw HolosError.io("Cannot convert \(Int(run.sampleRate)) Hz audio for the render.")
            }
            let feed = ConverterFeed(reader: reader, buffer: input)
            while true {
                output.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, status in
                    feed.next(status)
                }
                if let error = feed.error { throw error }
                if status == .error {
                    throw HolosError.io("Cannot convert audio for the render: \(conversionError?.localizedDescription ?? "unknown error").")
                }
                let kept = min(Int(output.frameLength), remaining)
                if kept > 0 {
                    try writer.write(output: output, frames: kept)
                    remaining -= kept
                }
                if status == .endOfStream { break }
                // Output past the run's length is dropped, but the reader still feeds every chunk to its end, so a
                // missing or damaged chunk is reported, and progress reaches 100 %.
            }
        }
        // Anything left past the converter output (rounding) is silence; a reader that stopped early threw above.
        try writer.writeSilence(remaining)
        try reader.finish()
    }
}

// MARK: - Plan

/// Where each chunk of a track goes in the render, and the time map (docs/meeting-design.md §4.7).
struct RenderPlan {
    /// A chunk's samples to use: `frames` input frames after skipping `skipFrames`.
    struct Piece {
        var chunk: AudioChunkRecord
        var skipFrames: Int
        var frames: Int
    }

    /// Chunks that follow each other without a gap at one sample rate: one converter.
    struct Run {
        var sampleRate: Double
        var pieces: [Piece]
        var renderStart: Double
        var renderEnd: Double
    }

    var runs: [Run] = []
    var spans: [RenderSpan] = []
    /// Seconds of the whole render.
    var duration = 0.0
    /// Input frames of every piece, for progress.
    var inputFrames = 0
    var chunkCount = 0

    init(manifest: SessionManifest, track: String, compressGapsLongerThan: Double, keptSilence: Double) throws {
        guard compressGapsLongerThan.isFinite, compressGapsLongerThan >= 0, keptSilence.isFinite, keptSilence >= 0 else {
            throw HolosError.invalidInput("Render gap settings must be finite and not negative.")
        }
        let chunks = manifest.chunks.filter { $0.track == track }
            .sorted { ($0.start, $0.relativePath) < ($1.start, $1.relativePath) }
        guard !chunks.isEmpty else {
            throw HolosError.invalidInput("The \(track) track has no saved audio to label.")
        }
        // Session time up to which audio has been placed, and the open span's origin.
        var placedEnd: Double?
        var span: (render: Double, session: Double)?
        var render = 0.0
        for chunk in chunks {
            let rate = chunk.sampleRate
            let total = chunk.frameCount
            var skip = 0
            if let placedEnd, chunk.start < placedEnd {
                skip = Int(((placedEnd - chunk.start) * rate).rounded())
                if skip >= total { continue }
            }
            let keptStart = chunk.start + Double(skip) / rate
            let kept = total - skip
            let keptEnd = keptStart + Double(kept) / rate
            let gap = keptStart - (placedEnd ?? 0)
            var newRun = placedEnd == nil
            if gap > compressGapsLongerThan {
                if let open = span {
                    spans.append(RenderSpan(renderStart: open.render, sessionStart: open.session,
                                            duration: render - open.render))
                }
                span = (render + keptSilence, keptStart)
                newRun = true
            } else {
                // A short lead-in is rendered as silence from session time 0.
                if span == nil { span = (0, 0) }
                // More than a sample and a half apart: a gap, rendered as silence; the converter restarts.
                if gap > 1.5 / rate { newRun = true }
            }
            if let last = runs.last, last.sampleRate != rate { newRun = true }
            guard let open = span else { continue }
            let pieceStart = open.render + (keptStart - open.session)
            let pieceEnd = open.render + (keptEnd - open.session)
            let piece = Piece(chunk: chunk, skipFrames: skip, frames: kept)
            if newRun || runs.isEmpty {
                runs.append(Run(sampleRate: rate, pieces: [piece], renderStart: pieceStart, renderEnd: pieceEnd))
            } else {
                runs[runs.count - 1].pieces.append(piece)
                runs[runs.count - 1].renderEnd = pieceEnd
            }
            render = max(render, pieceEnd)
            placedEnd = max(placedEnd ?? 0, keptEnd)
            inputFrames += kept
            chunkCount += 1
        }
        if let open = span {
            spans.append(RenderSpan(renderStart: open.render, sessionStart: open.session, duration: render - open.render))
        }
        duration = render
    }
}

// MARK: - Reading

/// Reads a run's pieces in order as mono Float32, one chunk open at a time.
private final class RunReader {
    private let run: RenderPlan.Run
    private let session: URL
    private let meter: ProgressMeter
    private var index = 0
    private var chunk: ChunkAudioReader?
    private var remaining = 0

    init(run: RenderPlan.Run, session: URL, meter: ProgressMeter) {
        self.run = run; self.session = session; self.meter = meter
    }

    /// Fills `buffer` (mono Float32, up to its capacity) and returns the frame count; 0 at the end of the run.
    func read(into buffer: AVAudioPCMBuffer) throws -> Int {
        buffer.frameLength = 0
        while remaining == 0 {
            chunk = nil
            guard index < run.pieces.count else { return 0 }
            try Task.checkCancellation()
            let piece = run.pieces[index]
            index += 1
            let reader = try ChunkAudioReader(session: session, chunk: piece.chunk)
            try reader.seek(to: piece.skipFrames)
            chunk = reader
            remaining = piece.frames
        }
        guard let chunk, let destination = buffer.floatChannelData?[0] else { return 0 }
        let wanted = min(remaining, Int(buffer.frameCapacity))
        let count = try chunk.readMono(into: destination, frames: wanted)
        guard count == wanted else {
            throw HolosError.incomplete("Audio chunk \(chunk.relativePath) is shorter than the session manifest says.")
        }
        remaining -= count
        buffer.frameLength = AVAudioFrameCount(count)
        meter.add(count)
        return count
    }

    /// Reads whatever the converter did not ask for, so every chunk is checked to its end.
    func finish() throws {
        guard remaining > 0 || index < run.pieces.count else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: run.sampleRate, channels: 1),
              let scratch = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(TrackRenderer.blockFrames)) else {
            throw HolosError.io("Cannot allocate audio buffers for the render.")
        }
        while try read(into: scratch) > 0 {}
    }
}

/// Supplies a converter's input block from a `RunReader`, remembering the first read error.
///
/// `@unchecked Sendable`: AVAudioConverter calls the input block synchronously, on the calling thread, inside
/// `convert(to:error:withInputFrom:)`; the feed is created and used only within one `renderRun` call, so its state
/// is never touched from two threads.
private final class ConverterFeed: @unchecked Sendable {
    let reader: RunReader
    let buffer: AVAudioPCMBuffer
    private(set) var error: Error?
    private var ended = false

    init(reader: RunReader, buffer: AVAudioPCMBuffer) { self.reader = reader; self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard !ended else {
            status.pointee = .endOfStream
            return nil
        }
        do {
            if try reader.read(into: buffer) > 0 {
                status.pointee = .haveData
                return buffer
            }
        } catch {
            self.error = error
        }
        ended = true
        status.pointee = .endOfStream
        return nil
    }
}

/// One finalized chunk read through a descriptor (never by path): AudioFile over `pread`, wrapped in an
/// ExtAudioFile that delivers interleaved Float32 at the chunk's own rate, averaged to mono here.
private final class ChunkAudioReader {
    let relativePath: String
    private let handle: FileHandle
    private let size: Int64
    private var audioFile: AudioFileID?
    private var file: ExtAudioFileRef?
    private let channels: Int
    private var interleaved: [Float] = []

    init(session: URL, chunk: AudioChunkRecord) throws {
        relativePath = chunk.relativePath
        let damaged = HolosError.incomplete("Audio chunk \(chunk.relativePath) is not readable audio.")
        guard let handle = try AtomicFile.openForReading(session.appendingPathComponent(chunk.relativePath)) else {
            throw HolosError.incomplete("Audio chunk \(chunk.relativePath) is missing.")
        }
        self.handle = handle
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0, info.st_size > 0 else { throw damaged }
        size = Int64(info.st_size)
        channels = chunk.channels

        var opened: AudioFileID?
        let status = AudioFileOpenWithCallbacks(
            Unmanaged.passUnretained(handle).toOpaque(),
            { client, position, requested, buffer, actual in
                let handle = Unmanaged<FileHandle>.fromOpaque(client).takeUnretainedValue()
                return DescriptorIO.read(handle.fileDescriptor, position, requested, buffer, actual)
            },
            nil,
            { client in
                let handle = Unmanaged<FileHandle>.fromOpaque(client).takeUnretainedValue()
                return DescriptorIO.size(handle.fileDescriptor)
            },
            nil,
            kAudioFileCAFType,
            &opened)
        guard status == noErr, let opened else { throw damaged }
        audioFile = opened
        var wrapped: ExtAudioFileRef?
        guard ExtAudioFileWrapAudioFileID(opened, false, &wrapped) == noErr, let wrapped else { throw damaged }
        file = wrapped

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var frames: Int64 = 0
        var framesSize = UInt32(MemoryLayout<Int64>.size)
        guard ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileDataFormat, &formatSize, &format) == noErr,
              ExtAudioFileGetProperty(wrapped, kExtAudioFileProperty_FileLengthFrames, &framesSize, &frames) == noErr
        else { throw damaged }
        guard format.mSampleRate == chunk.sampleRate, Int(format.mChannelsPerFrame) == chunk.channels else {
            throw HolosError.incomplete("Audio chunk \(chunk.relativePath) does not match its format in the session manifest.")
        }
        guard frames >= Int64(chunk.frameCount) else {
            throw HolosError.incomplete("Audio chunk \(chunk.relativePath) is shorter than the session manifest says.")
        }
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * chunk.channels)
        var client = AudioStreamBasicDescription(
            mSampleRate: chunk.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame, mChannelsPerFrame: UInt32(chunk.channels), mBitsPerChannel: 32,
            mReserved: 0)
        guard ExtAudioFileSetProperty(wrapped, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr else {
            throw damaged
        }
    }

    deinit {
        if let file { ExtAudioFileDispose(file) }
        if let audioFile { AudioFileClose(audioFile) }
    }

    func seek(to frame: Int) throws {
        guard frame > 0 else { return }
        guard let file, ExtAudioFileSeek(file, Int64(frame)) == noErr else {
            throw HolosError.incomplete("Cannot seek in audio chunk \(relativePath).")
        }
    }

    /// Reads up to `frames` frames, averaging channels, into `destination`; returns how many it read (fewer only
    /// at the end of the file).
    func readMono(into destination: UnsafeMutablePointer<Float>, frames: Int) throws -> Int {
        guard let file else { return 0 }
        if interleaved.count < frames * channels { interleaved = [Float](repeating: 0, count: frames * channels) }
        var done = 0
        while done < frames {
            let wanted = frames - done
            var count = UInt32(wanted)
            let status = interleaved.withUnsafeMutableBufferPointer { samples -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(wanted * channels * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(samples.baseAddress!)))
                return ExtAudioFileRead(file, &count, &list)
            }
            guard status == noErr else {
                throw HolosError.incomplete("Cannot read audio chunk \(relativePath) (\(status)).")
            }
            if count == 0 { break }
            let read = Int(count)
            if channels == 1 {
                for index in 0..<read { destination[done + index] = interleaved[index] }
            } else {
                let scale = 1 / Float(channels)
                for index in 0..<read {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += interleaved[index * channels + channel] }
                    destination[done + index] = sum * scale
                }
            }
            done += read
        }
        return done
    }
}

// MARK: - Writing

/// Writes mono 16 kHz 16-bit little-endian integer PCM as CAF through a descriptor, with AudioFile's own CAF writer
/// (`AudioFileInitializeWithCallbacks` over `pread`/`pwrite`), so the header is exactly what AudioFile readers
/// (`Int16CAFSampleSource`) expect.
private final class Int16CAFWriter {
    private let io: DescriptorIO
    private var file: AudioFileID?
    private var offset: Int64 = 0
    private var samples = [Int16](repeating: 0, count: TrackRenderer.blockFrames)

    init(descriptor: Int32, sampleRate: Double) throws {
        io = DescriptorIO(descriptor)
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var created: AudioFileID?
        let status = AudioFileInitializeWithCallbacks(
            Unmanaged.passUnretained(io).toOpaque(),
            { client, position, requested, buffer, actual in
                let io = Unmanaged<DescriptorIO>.fromOpaque(client).takeUnretainedValue()
                return DescriptorIO.read(io.descriptor, position, requested, buffer, actual)
            },
            { client, position, requested, buffer, actual in
                let io = Unmanaged<DescriptorIO>.fromOpaque(client).takeUnretainedValue()
                return DescriptorIO.write(io.descriptor, position, requested, buffer, actual)
            },
            { client in
                DescriptorIO.size(Unmanaged<DescriptorIO>.fromOpaque(client).takeUnretainedValue().descriptor)
            },
            { client, size in
                let io = Unmanaged<DescriptorIO>.fromOpaque(client).takeUnretainedValue()
                return ftruncate(io.descriptor, off_t(size)) == 0 ? noErr : kAudioFileUnspecifiedError
            },
            kAudioFileCAFType, &format, AudioFileFlags(rawValue: 0), &created)
        guard status == noErr, let created else {
            throw HolosError.io("Cannot start the rendered audio file (\(status)).")
        }
        file = created
    }

    deinit { abandon() }

    /// Writes `frames` frames of `output`'s first channel, as Int16 (×32,768, clamped; not-a-number is 0).
    func write(output: AVAudioPCMBuffer, frames: Int) throws {
        guard frames > 0 else { return }
        guard let source = output.floatChannelData?[0] else {
            throw HolosError.io("The render produced audio in an unexpected format.")
        }
        var done = 0
        while done < frames {
            let count = min(frames - done, samples.count)
            for index in 0..<count {
                let value = source[done + index]
                guard value.isFinite else { samples[index] = 0; continue }
                let scaled = (value * 32_768).rounded()
                samples[index] = scaled >= 32_767 ? .max : scaled <= -32_768 ? .min : Int16(scaled)
            }
            try writeSamples(count)
            done += count
        }
    }

    func writeSilence(_ frames: Int) throws {
        guard frames > 0 else { return }
        var done = 0
        while done < frames {
            let count = min(frames - done, samples.count)
            for index in 0..<count { samples[index] = 0 }
            try writeSamples(count)
            done += count
        }
    }

    /// Finishes the header. The file is complete afterwards.
    func close() throws {
        guard let file else { return }
        self.file = nil
        let status = AudioFileClose(file)
        guard status == noErr else { throw HolosError.io("Cannot finish the rendered audio file (\(status)).") }
    }

    /// Closes without caring about the result (the file is discarded).
    func abandon() {
        if let file { AudioFileClose(file) }
        file = nil
    }

    private func writeSamples(_ count: Int) throws {
        guard let file else { throw HolosError.io("The rendered audio file is closed.") }
        var bytes = UInt32(count * MemoryLayout<Int16>.size)
        let expected = bytes
        let status = samples.withUnsafeBytes { raw in
            AudioFileWriteBytes(file, false, offset, &bytes, raw.baseAddress!)
        }
        guard status == noErr, bytes == expected else {
            throw HolosError.io("Cannot write the rendered audio (\(status)).")
        }
        offset += Int64(bytes)
    }
}

/// `pread`/`pwrite`/`fstat` for AudioFile callbacks.
private final class DescriptorIO {
    let descriptor: Int32

    init(_ descriptor: Int32) { self.descriptor = descriptor }

    static func read(_ fd: Int32, _ position: Int64, _ requested: UInt32, _ buffer: UnsafeMutableRawPointer,
                     _ actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        guard position >= 0 else {
            actual.pointee = 0
            return kAudioFilePositionError
        }
        var done = 0
        while done < Int(requested) {
            let count = pread(fd, buffer.advanced(by: done), Int(requested) - done, off_t(position) + off_t(done))
            if count < 0 {
                if errno == EINTR { continue }
                actual.pointee = UInt32(done)
                return kAudioFileUnspecifiedError
            }
            if count == 0 { break }
            done += count
        }
        actual.pointee = UInt32(done)
        return noErr
    }

    static func write(_ fd: Int32, _ position: Int64, _ requested: UInt32, _ buffer: UnsafeRawPointer,
                      _ actual: UnsafeMutablePointer<UInt32>) -> OSStatus {
        guard position >= 0 else {
            actual.pointee = 0
            return kAudioFilePositionError
        }
        var done = 0
        while done < Int(requested) {
            let count = pwrite(fd, buffer.advanced(by: done), Int(requested) - done, off_t(position) + off_t(done))
            if count < 0 {
                if errno == EINTR { continue }
                actual.pointee = UInt32(done)
                return kAudioFileUnspecifiedError
            }
            if count == 0 {
                actual.pointee = UInt32(done)
                return kAudioFileUnspecifiedError
            }
            done += count
        }
        actual.pointee = UInt32(done)
        return noErr
    }

    static func size(_ fd: Int32) -> Int64 {
        var info = stat()
        return fstat(fd, &info) == 0 ? Int64(info.st_size) : 0
    }
}

// MARK: - Progress

/// Reports the fraction of input frames read, at most once per percent.
private final class ProgressMeter {
    private let total: Int
    private let report: (@Sendable (Double) -> Void)?
    private var done = 0
    private var lastPercent = -1

    init(total: Int, report: (@Sendable (Double) -> Void)?) { self.total = total; self.report = report }

    func add(_ frames: Int) {
        guard let report, total > 0 else { return }
        done += frames
        let percent = min(100, done * 100 / total)
        guard percent > lastPercent else { return }
        lastPercent = percent
        report(Double(percent) / 100)
    }
}
