import Foundation
import HolosCore
import HolosStorage

/// Gaps and markers for exports, read from a session's event journal (docs/meeting-design.md §4.11, §5.5 PR7b).
public enum SessionTimelineReader {
    /// A discontinuity must be longer than this to be a gap.
    static let minimumGapSeconds = 0.05
    /// An unexplained timestamp gap (or a reason this build does not know) must be longer than this.
    static let unexplainedGapSeconds = 1.0
    /// Gaps of the two tracks with one reason whose starts and ends each differ by at most this are one gap.
    static let sameGapToleranceSeconds = 1.0

    /// Gaps from audioDiscontinuity events longer than 0.05 s. Reasons that are GapReason raw values map 1:1;
    /// timestampGap longer than 1 s → audioGap; formatChanged and shorter timestampGaps are ignored; any other
    /// reason longer than 1 s → audioGap. Within a gap, the stretch between `paused` and `resumed` events is
    /// `paused`, and between `systemWillSleep` and `didWake` is `sleep`. The same gap on both tracks merges into
    /// one with track nil. Markers from marker events. Tolerates torn and corrupt lines.
    ///
    /// Details:
    /// - Event times are session seconds written with `String(Double)`; an event whose times do not parse, or are
    ///   not finite, is ignored.
    /// - Pause and sleep stretches pair events in journal order; one left open runs to the end of the gap. Where a
    ///   pause and a sleep overlap (sleep while paused), the pause wins: the user paused the meeting. Pieces of a
    ///   split gap that are 0.05 s or shorter are dropped, except that a gap always keeps its longest piece.
    /// - Gaps of "mic" and "system" with the same reason whose starts and ends each differ by at most 1 s become
    ///   one gap with track nil, spanning both.
    /// - Gaps are sorted by (start, track, reason); markers by time, in journal order for equal times.
    public static func read(session: URL) throws -> (gaps: [TimelineGap], markers: [TimelineMarker]) {
        let timeline = try readTimeline(session: session)
        return (timeline.gaps, timeline.markers)
    }

    /// `read`, with how much of the event journal it had to skip.
    struct Timeline {
        var gaps: [TimelineGap]
        var markers: [TimelineMarker]
        /// Journal lines that could not be read (damaged, or a last line cut off) plus gap, pause, sleep, and marker
        /// events whose times do not parse: the exports may miss the gaps and markers they held.
        var skippedEvents: Int
    }

    /// `read`, also counting what it skipped (`Timeline.skippedEvents`).
    static func readTimeline(session: URL) throws -> Timeline {
        let journal = try SessionArchive.readEvents(at: session)
        var skipped = journal.unreadableLines + (journal.tornTail ? 1 : 0)
        var raw: [TimelineGap] = []
        var markers: [TimelineMarker] = []
        var pauses = Stretches()
        var sleeps = Stretches()
        for event in journal.events {
            let at = time(event.details["at"])
            switch event.kind {
            case MeetingEventKind.audioDiscontinuity:
                guard time(event.details["previousEnd"]) != nil, time(event.details["nextStart"]) != nil else {
                    skipped += 1
                    continue
                }
                if let gap = gap(from: event.details) { raw.append(gap) }
            case MeetingEventKind.paused, MeetingEventKind.resumed, MeetingEventKind.systemWillSleep,
                 MeetingEventKind.didWake, MeetingEventKind.marker:
                guard let at else {
                    skipped += 1
                    continue
                }
                switch event.kind {
                case MeetingEventKind.paused: pauses.open(at)
                case MeetingEventKind.resumed: pauses.close(at)
                case MeetingEventKind.systemWillSleep: sleeps.open(at)
                case MeetingEventKind.didWake: sleeps.close(at)
                default:
                    let label = event.details["label"].flatMap { $0.isEmpty ? nil : $0 }
                    markers.append(TimelineMarker(at: at, label: label))
                }
            default:
                continue
            }
        }
        let pauseRanges = pauses.finished()
        let sleepRanges = sleeps.finished()
        let split = raw.flatMap { split($0, pauses: pauseRanges, sleeps: sleepRanges) }
        let gaps = mergeTracks(split).sorted {
            ($0.start, $0.track ?? "", $0.reason.rawValue) < ($1.start, $1.track ?? "", $1.reason.rawValue)
        }
        let orderedMarkers = markers.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        return Timeline(gaps: gaps, markers: orderedMarkers, skippedEvents: skipped)
    }

    // MARK: - Private

    /// Reasons that are `GapReason` raw values; every other reason is unexplained.
    private static let knownReasons: Set<GapReason> = [
        .paused, .sleep, .deviceChanged, .captureRestarted, .audioUnavailable, .overflow, .audioGap, .redacted,
    ]

    private static func time(_ text: String?) -> Double? {
        guard let text, let value = Double(text), value.isFinite else { return nil }
        return value
    }

    private static func gap(from details: [String: String]) -> TimelineGap? {
        guard let start = time(details["previousEnd"]), let end = time(details["nextStart"]) else { return nil }
        let length = end - start
        guard length > minimumGapSeconds else { return nil }
        let track = details["track"].flatMap { $0.isEmpty ? nil : $0 }
        let reasonText = details["reason"] ?? ""
        let reason: GapReason
        if knownReasons.contains(GapReason(reasonText)) {
            reason = GapReason(reasonText)
        } else if reasonText == "formatChanged" {
            return nil
        } else if length > unexplainedGapSeconds {
            // "timestampGap", or a reason written by a newer Holos.
            reason = .audioGap
        } else {
            return nil
        }
        return TimelineGap(track: track, start: start, end: end, reason: reason)
    }

    /// Overlays pause stretches (reason `paused`) and sleep stretches (`sleep`) on `gap`; the rest keeps its reason.
    private static func split(_ gap: TimelineGap, pauses: [ClosedRange<Double>],
                              sleeps: [ClosedRange<Double>]) -> [TimelineGap] {
        // Cut points: the gap's ends and every stretch edge inside it.
        var cuts = [gap.start, gap.end]
        for range in pauses + sleeps {
            for edge in [range.lowerBound, range.upperBound] where edge > gap.start && edge < gap.end {
                cuts.append(edge)
            }
        }
        cuts = Array(Set(cuts)).sorted()
        var pieces: [TimelineGap] = []
        for (lower, upper) in zip(cuts, cuts.dropFirst()) {
            let middle = (lower + upper) / 2
            let reason: GapReason
            if pauses.contains(where: { $0.contains(middle) }) {
                reason = .paused
            } else if sleeps.contains(where: { $0.contains(middle) }) {
                reason = .sleep
            } else {
                reason = gap.reason
            }
            // Adjacent pieces with one reason stay one piece.
            if let last = pieces.last, last.reason == reason, last.end == lower {
                pieces[pieces.count - 1].end = upper
            } else {
                pieces.append(TimelineGap(track: gap.track, start: lower, end: upper, reason: reason))
            }
        }
        let kept = pieces.filter { $0.end - $0.start > minimumGapSeconds }
        return kept.isEmpty && !pieces.isEmpty ? [pieces.max { ($0.end - $0.start) < ($1.end - $1.start) }!] : kept
    }

    /// Merges a "mic" gap and a "system" gap with one reason and nearly the same bounds into one with track nil.
    private static func mergeTracks(_ gaps: [TimelineGap]) -> [TimelineGap] {
        var result: [TimelineGap] = []
        var used = Set<Int>()
        let ordered = gaps.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        for (position, entry) in ordered.enumerated() where !used.contains(entry.offset) {
            let gap = entry.element
            used.insert(entry.offset)
            guard let track = gap.track else {
                result.append(gap)
                continue
            }
            let partner = ordered[(position + 1)...].first { candidate in
                !used.contains(candidate.offset)
                    && candidate.element.track != nil && candidate.element.track != track
                    && candidate.element.reason == gap.reason
                    && abs(candidate.element.start - gap.start) <= sameGapToleranceSeconds
                    && abs(candidate.element.end - gap.end) <= sameGapToleranceSeconds
            }
            if let partner {
                used.insert(partner.offset)
                result.append(TimelineGap(track: nil, start: min(gap.start, partner.element.start),
                                          end: max(gap.end, partner.element.end), reason: gap.reason))
            } else {
                result.append(gap)
            }
        }
        return result
    }

    /// Open/close pairs of events in journal order.
    private struct Stretches {
        private var openAt: Double?
        private var ranges: [ClosedRange<Double>] = []

        mutating func open(_ at: Double) {
            if openAt == nil { openAt = at }
        }

        mutating func close(_ at: Double) {
            guard let start = openAt else { return }
            openAt = nil
            if at >= start { ranges.append(start...at) }
        }

        /// Every stretch, one still open running to infinity.
        func finished() -> [ClosedRange<Double>] {
            guard let start = openAt else { return ranges }
            return ranges + [start...Double.greatestFiniteMagnitude]
        }
    }
}
