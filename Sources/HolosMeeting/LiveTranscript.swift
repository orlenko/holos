import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// Words of the live transcript as shown (docs/design.md "Live transcript"): finalized text, or volatile words the
/// recognizer may still change.
public struct LiveRun: Sendable, Equatable {
    public var text: String
    public var isFinal: Bool
    /// The finalized segment the words come from (`transcriptFinalized`'s `segmentID`); nil for volatile words. A
    /// later correction made during the meeting attaches here.
    public var segmentID: String?

    public init(text: String, isFinal: Bool, segmentID: String? = nil) {
        self.text = text; self.isFinal = isFinal; self.segmentID = segmentID
    }
}

/// One paragraph of the live transcript: a track's consecutive words.
public struct LiveParagraph: Sendable, Equatable {
    /// "mic" or "system".
    public var track: String
    /// Session time of its first word.
    public var start: Double
    public var runs: [LiveRun]

    public init(track: String, start: Double, runs: [LiveRun]) {
        self.track = track; self.start = start; self.runs = runs
    }

    /// Whether every word is final.
    public var isFinal: Bool { runs.allSatisfy(\.isFinal) }
}

/// Builds the live transcript from what live speech finalized and what it still hears. Pure.
///
/// - Volatile words follow the finalized words of their track: a volatile word that starts inside a finalized segment
///   of its track is already in it (the recorder keeps a volatile copy in `live.json` until its final segment is
///   journaled), so it is left out, and a volatile segment with no word left disappears. Words outside every
///   finalized segment stay, also when they are earlier than the newest one (an older speech session still
///   finishing after a capture restart).
/// - Microphone echo of a call (the laptop speakers playing the call into the microphone) is hidden with the rule
///   post-processing uses (`EchoFilter.echoSpans` with the meeting's `SpeakerAnalysis.alignmentParameters`): runs
///   of at least three microphone words that repeat the system track's words in order, each starting at most
///   1 s after its system word. Volatile words of both tracks take part, so a microphone phrase is hidden as soon as
///   the system track has heard the same words, final or not. A microphone segment whose every word is echo is not
///   shown; its other words stay (the user talking over the call). Fewer than three echoed words are never hidden,
///   so the first one or two volatile words of an echo can show until the third arrives.
/// - Paragraphs: words in order of their start; a new paragraph starts when the track changes or after a pause of
///   more than `paragraphGapSeconds`.
public enum LiveTranscript {
    public static let paragraphGapSeconds = 8.0
    /// Timing jitter between a volatile word and the finalized segment that replaced it.
    static let finalOverlapTolerance = 0.05

    /// The echo filter's parameters for a meeting recorded as `mode` (post-processing's own,
    /// `SpeakerAnalysis.alignmentParameters`); nil when it filters nothing (in person: no system audio).
    public static func echoParameters(mode: MeetingMode) -> AlignmentParameters? {
        let parameters = SpeakerAnalysis.alignmentParameters(
            meeting: MeetingInfo(sessionID: "", mode: mode, othersInRoom: false))
        return parameters.echoWindowSeconds == nil ? nil : parameters
    }

    /// The paragraphs to show. `finals`: finalized segments with `track` set; `volatile`: volatile segments by track
    /// (`LiveTextFile.volatile`); `echo`: `echoParameters(mode:)`, nil to hide nothing.
    public static func paragraphs(finals: [TranscriptSegment], volatile: [String: [TranscriptSegment]],
                                  echo: AlignmentParameters?) -> [LiveParagraph] {
        var items: [Item] = []
        /// Each track's finalized intervals.
        var finalized: [String: [(start: Double, end: Double)]] = [:]
        for segment in finals {
            let track = segment.track ?? "mic"
            finalized[track, default: []].append((segment.start, segment.end))
            items.append(Item(segment: segment, track: track, isFinal: true))
        }
        for track in volatile.keys.sorted() {
            let covered = finalized[track] ?? []
            for (index, original) in (volatile[track] ?? []).enumerated() {
                var segment = original
                // Unique among the finals for the echo filter's word references.
                segment.id = "volatile:\(track):\(index)"
                segment.track = track
                var item = Item(segment: segment, track: track, isFinal: false)
                // Only words a finalized segment covers: an older speech session (finished in the background after a
                // capture restart) can still hold volatile words before a newer session's finals.
                for (word, timing) in item.words.enumerated()
                where covered.contains(where: { timing.start >= $0.start - finalOverlapTolerance
                                               && timing.start < $0.end - finalOverlapTolerance }) {
                    item.keep[word] = false
                }
                items.append(item)
            }
        }
        if let echo { hideEcho(in: &items, parameters: echo) }
        let shown = items.compactMap { $0.shown() }.enumerated().sorted { left, right in
            // Finals before volatile words at the same time; otherwise as listed.
            (left.element.start, left.element.isFinal ? 0 : 1, left.offset)
                < (right.element.start, right.element.isFinal ? 0 : 1, right.offset)
        }.map(\.element)
        var paragraphs: [LiveParagraph] = []
        /// End of the current paragraph's last word.
        var paragraphEnd = -Double.infinity
        for item in shown {
            let run = LiveRun(text: item.text, isFinal: item.isFinal, segmentID: item.isFinal ? item.segmentID : nil)
            if let last = paragraphs.last, last.track == item.track, item.start - paragraphEnd <= paragraphGapSeconds {
                paragraphs[paragraphs.count - 1].runs.append(run)
                paragraphEnd = max(paragraphEnd, item.end)
            } else {
                paragraphs.append(LiveParagraph(track: item.track, start: item.start, runs: [run]))
                paragraphEnd = item.end
            }
        }
        return paragraphs
    }

    /// Leaves out the microphone words `EchoFilter.echoSpans` finds to be echo. It is given only the words still
    /// shown (a volatile word a final segment replaced is not heard twice), each segment cut down to them, and its
    /// word references are mapped back to the full segment.
    private static func hideEcho(in items: inout [Item], parameters: AlignmentParameters) {
        var segments: [TranscriptSegment] = []
        /// For each cut-down segment (by ID): the item and, per word, the word's index in the item.
        var origins: [String: (item: Int, words: [Int])] = [:]
        for (index, item) in items.enumerated() {
            let kept = item.words.indices.filter { item.keep[$0] }
            guard !kept.isEmpty else { continue }
            var segment = item.segment
            segment.words = kept.map { word in
                let timing = item.words[word]
                return TimedWord(text: timing.text, start: timing.start, end: timing.end, utf16Offset: 0,
                                 utf16Length: 0)
            }
            segments.append(segment)
            origins[segment.id] = (index, kept)
        }
        let transcript = Transcript(source: "", locale: "", backend: .speech, segments: segments)
        for ref in EchoFilter.words(in: EchoFilter.echoSpans(transcript: transcript, parameters: parameters)) {
            guard let origin = origins[ref.segmentID], items[origin.item].track == EchoFilter.microphoneTrack,
                  ref.word >= 0, ref.word < origin.words.count else { continue }
            items[origin.item].keep[origin.words[ref.word]] = false
        }
    }

    /// A finalized or volatile segment and which of its words show.
    private struct Item {
        var segment: TranscriptSegment
        let track: String
        let isFinal: Bool
        /// `WordTiming.effectiveWords(of: segment)`, the words `EchoFilter` refers to.
        let words: [EffectiveWord]
        var keep: [Bool]

        init(segment: TranscriptSegment, track: String, isFinal: Bool) {
            self.segment = segment
            self.track = track
            self.isFinal = isFinal
            words = WordTiming.effectiveWords(of: segment)
            keep = [Bool](repeating: true, count: words.count)
        }

        /// What shows of it; nil when no word with a letter or digit is left.
        func shown() -> Shown? {
            let kept = words.indices.filter { keep[$0] }
            guard kept.contains(where: { words[$0].text.contains(where: { $0.isLetter || $0.isNumber }) }) else {
                return nil
            }
            let text: String
            if kept.count == words.count {
                text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = kept.map { Self.text(of: words[$0], in: segment.text) }.filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            guard !text.isEmpty else { return nil }
            return Shown(track: track, start: words[kept[0]].start, end: words[kept[kept.count - 1]].end,
                         text: text, isFinal: isFinal, segmentID: segment.id)
        }

        /// The word as it appears in the segment's text, else its own text; trimmed.
        private static func text(of word: EffectiveWord, in text: String) -> String {
            let utf16 = text.utf16
            // Ranges come from a file: checked without adding them, which could overflow.
            guard word.utf16Offset >= 0, word.utf16Length > 0, word.utf16Offset <= utf16.count,
                  word.utf16Length <= utf16.count - word.utf16Offset
            else { return word.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            let start = utf16.index(utf16.startIndex, offsetBy: word.utf16Offset)
            let end = utf16.index(start, offsetBy: word.utf16Length)
            return String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private struct Shown {
        let track: String
        let start: Double
        let end: Double
        let text: String
        let isFinal: Bool
        let segmentID: String
    }
}

/// Whether the live transcript follows its newest words (docs/design.md "Live transcript"): it does while the user
/// is at the bottom; scrolling up stops it and offers "Jump to Live", and scrolling back to the bottom (or the
/// button) resumes it. Pure.
public struct LiveFollow: Sendable, Equatable {
    /// Within this many points of the bottom counts as at the bottom.
    public static let bottomSlack = 24.0

    public private(set) var following = true

    public init() {}

    /// "Jump to Live" shows while the view does not follow.
    public var showsJumpToLive: Bool { !following }

    /// The user moved the view (scrolling, the keyboard, a resize): it follows when it is at the bottom.
    public mutating func moved(distanceFromBottom: Double) {
        following = !(distanceFromBottom > Self.bottomSlack)
    }

    /// "Jump to Live": back to the newest words, following them again.
    public mutating func jumpToLive() { following = true }

    /// New words arrived: whether the view scrolls to them.
    public var scrollsToNewWords: Bool { following }
}

/// The finalized segments of a session's `events.jsonl`, read incrementally, and its `live.json`: what the live
/// transcript shows. Each read continues where the last one stopped, keeps a partial last line for the next read, and
/// starts over if the journal got shorter (a repaired torn tail). Reading does not block on the recorder; meant to
/// run off the main actor.
public struct LiveTranscriptReader: Sendable {
    /// At most this many finalized segments are kept (the newest).
    public static let maxSegments = 1_000
    /// At most this much is read at once, so a long meeting's first read stays bounded.
    static let maxRead = 32 << 20

    public let session: URL
    public private(set) var finals: [TranscriptSegment] = []
    /// Changes whenever `finals` does.
    public private(set) var revision = 0
    /// `live.json`'s volatile segments by track, as last read; empty when it was not read or there is none.
    public private(set) var volatile: [String: [TranscriptSegment]] = [:]
    /// The meeting's mode from meeting.json, once read.
    public private(set) var mode: MeetingMode?
    private var offset: UInt64 = 0
    private var partial = Data()

    public init(session: URL) {
        self.session = session
    }

    /// Reads what was appended to the journal, and `live.json` when `includeVolatile` (while audio is captured);
    /// otherwise forgets the volatile words.
    public mutating func read(includeVolatile: Bool) {
        if mode == nil {
            mode = (try? AtomicFile.readJSON(MeetingInfo.self, from: SessionPaths.meetingInfo(session),
                                             maxBytes: 1 << 20))?.mode
        }
        // live.json first: the recorder drops a volatile copy from it only after its final segment is in the journal,
        // so the journal read next has every word live.json no longer shows (`VolatileText`).
        volatile = includeVolatile ? (LiveTextFile.read(session: session)?.volatile ?? [:]) : [:]
        readJournal()
    }

    private mutating func readJournal() {
        guard let handle = try? AtomicFile.openForReading(SessionPaths.events(session)) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset {
            offset = 0
            partial = Data()
            finals = []
            revision += 1
        }
        guard size > offset else { return }
        // A first read of a long journal skips to its last part; the first line there may be cut.
        var start = offset
        var skipFirst = false
        if size - offset > UInt64(Self.maxRead) {
            start = size - UInt64(Self.maxRead)
            partial = Data()
            skipFirst = true
        }
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.read(upToCount: Int(size - start)) else { return }
        offset = start + UInt64(data.count)
        var buffer = partial + data
        partial = Data()
        if let last = buffer.lastIndex(of: 0x0A) {
            partial = buffer.suffix(from: buffer.index(after: last))
            buffer = buffer.prefix(through: last)
        } else {
            partial = buffer
            return
        }
        let decoder = HolosJSON.decoder()
        let marker = Data(MeetingEventKind.transcriptFinalized.utf8)
        var added = false
        for (index, line) in buffer.split(separator: 0x0A).enumerated() {
            if skipFirst && index == 0 { continue }
            guard line.range(of: marker) != nil,
                  let event = try? decoder.decode(ArchiveEvent.self, from: Data(line)),
                  let segment = Self.segment(event, decoder: decoder) else { continue }
            finals.append(segment)
            added = true
        }
        if finals.count > Self.maxSegments { finals.removeFirst(finals.count - Self.maxSegments) }
        if added { revision += 1 }
    }

    /// The segment a `transcriptFinalized` event journaled; nil for another event or one without text.
    static func segment(_ event: ArchiveEvent, decoder: JSONDecoder) -> TranscriptSegment? {
        guard event.kind == MeetingEventKind.transcriptFinalized,
              let text = event.details["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let start = event.details["start"].flatMap(Double.init) ?? 0
        let end = event.details["end"].flatMap(Double.init) ?? start
        let words = event.details["words"].flatMap { try? decoder.decode([TimedWord].self, from: Data($0.utf8)) }
        return TranscriptSegment(id: event.details["segmentID"] ?? "event-\(event.sequence)",
                                 start: start.isFinite ? start : 0, end: end.isFinite ? end : 0, text: text,
                                 words: words ?? [], track: event.details["track"] == "system" ? "system" : "mic")
    }
}
