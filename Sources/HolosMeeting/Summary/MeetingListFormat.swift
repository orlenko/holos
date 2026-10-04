import Foundation
import HolosCore

/// What the Meetings list shows for each meeting (docs/design.md "Meetings list"): its day group, the line under its
/// title (when, how long, who), its badges, and whether it matches a search. Pure, so the list's text is tested
/// without AppKit.
public enum MeetingListFormat {
    // MARK: - Groups

    /// "Today", "Yesterday", "This Week" (the five days before), then the month ("September 2026").
    public static func groupTitle(for date: Date, now: Date, calendar: Calendar = .current,
                                  locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            return "This Week"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return formatter.string(from: date)
    }

    /// The meetings in groups, in the order they are given (newest first, the live one first); a group appears once,
    /// where its first meeting is.
    public static func groups(_ summaries: [SessionSummary], now: Date, calendar: Calendar = .current,
                              locale: Locale = .current) -> [(title: String, meetings: [SessionSummary])] {
        var groups: [(title: String, meetings: [SessionSummary])] = []
        var index: [String: Int] = [:]
        for summary in summaries {
            let title = groupTitle(for: summary.createdAt, now: now, calendar: calendar, locale: locale)
            if let at = index[title] {
                groups[at].meetings.append(summary)
            } else {
                index[title] = groups.count
                groups.append((title, [summary]))
            }
        }
        return groups
    }

    // MARK: - The line under the title

    /// "2:05 PM · 52 min · Alex, Sam and 2 others": the start (the time alone today and yesterday, the weekday this
    /// week, else the date), the length once there is any audio, and the people the speaker labels name.
    public static func detailLine(_ summary: SessionSummary, people: [String], now: Date,
                                  calendar: Calendar = .current, locale: Locale = .current) -> String {
        var parts = [startText(summary.createdAt, now: now, calendar: calendar, locale: locale)]
        if summary.savedSeconds >= 1 { parts.append(duration(summary.savedSeconds)) }
        if let people = peopleText(people) { parts.append(people) }
        return parts.joined(separator: " · ")
    }

    static func startText(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        let group = groupTitle(for: date, now: now, calendar: calendar, locale: locale)
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        switch group {
        case "Today", "Yesterday": formatter.setLocalizedDateFormatFromTemplate("jmm")
        case "This Week": formatter.setLocalizedDateFormatFromTemplate("EEEEjmm")
        default: formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEMMMdjmm" : "MMMdyyyyjmm")
        }
        return formatter.string(from: date)
    }

    /// "45 s", "52 min", "1 h 05 min".
    public static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite ? Int(max(0, min(seconds, 1e9)).rounded()) : 0
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }

    /// "Alex", "Alex and Sam", "Alex, Sam and Robin", "Alex, Sam and 2 others"; nil for nobody.
    public static func peopleText(_ people: [String]) -> String? {
        switch people.count {
        case 0: return nil
        case 1: return people[0]
        case 2: return "\(people[0]) and \(people[1])"
        case 3: return "\(people[0]), \(people[1]) and \(people[2])"
        default: return "\(people[0]), \(people[1]) and \(people.count - 2) others"
        }
    }

    // MARK: - Badges

    public struct Badge: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// Recording now (red).
            case live
            /// Paused (orange).
            case paused
            /// Work in progress or waiting: saving, labelling, a final transcript.
            case progress
            /// Something needs attention: interrupted, failed, damaged.
            case warning
            /// A plain fact: no audio.
            case note
        }

        public var text: String
        public var kind: Kind

        public init(_ text: String, _ kind: Kind) {
            self.text = text; self.kind = kind
        }
    }

    /// The badges of a meeting, most important first: the live phase (`livePhase`, for the meeting the app follows),
    /// what a command or final transcript is doing (`working`), then the meeting's state, its audio, and its speaker
    /// labels when they need attention.
    public static func badges(_ summary: SessionSummary, livePhase: LiveMeetingPhase?, working: String?)
        -> [Badge] {
        var badges: [Badge] = []
        switch livePhase {
        case .recording?: badges.append(Badge("● Recording", .live))
        case .paused?: badges.append(Badge("● Paused", .paused))
        case .starting?: badges.append(Badge("Starting…", .progress))
        case .saving?: badges.append(Badge("Saving…", .progress))
        case .saved?, .interrupted?, .failed?, nil: break
        }
        let live = livePhase.map { [.recording, .paused, .starting, .saving].contains($0) } ?? false
        if let working, !working.isEmpty { badges.append(Badge(working, .progress)) }
        guard !live else { return badges }
        switch summary.state {
        case .recording: badges.append(Badge("Recording", .live))
        case .processing: badges.append(Badge("Processing", .progress))
        case .interrupted: badges.append(Badge("Interrupted", .warning))
        case .failed: badges.append(Badge("Failed", .warning))
        case .damaged: badges.append(Badge("Damaged", .warning))
        case .transcriptionIncomplete: badges.append(Badge("Transcript incomplete", .warning))
        case .incomplete: badges.append(Badge("Incomplete", .warning))
        case .audioOnly: badges.append(Badge("Audio only", .note))
        case .complete, .recovered: break
        }
        if summary.audioDeleted { badges.append(Badge("No audio", .note)) }
        if working == nil {
            switch summary.speakerState {
            case .running: badges.append(Badge("Labelling speakers…", .progress))
            case .failed: badges.append(Badge("Speaker labels failed", .warning))
            case .interrupted: badges.append(Badge("Labelling interrupted", .warning))
            case .unreadable: badges.append(Badge("Speaker labels unreadable", .warning))
            case .notLabelled where summary.transcriptID != nil:
                badges.append(Badge("Speakers not labelled", .note))
            case .notLabelled, .none, .labelled: break
            }
        }
        if summary.languageWork != nil { badges.append(Badge("Language missing", .warning)) }
        return badges
    }

    // MARK: - Titles

    /// The meetings in `summaries` whose title (`displayTitle`) differs from the one `shown` had for them (by session
    /// ID; meetings not shown before are left out): after a catalog read, the meetings renamed elsewhere or given a
    /// new generated title, whose open windows follow.
    public static func titlesChanged(from shown: [String: String], to summaries: [SessionSummary]) -> [String] {
        summaries.compactMap { summary in
            guard let before = shown[summary.id], before != summary.displayTitle else { return nil }
            return summary.id
        }
    }

    // MARK: - Search

    /// Whether `query`'s words all appear (any case, any accents) in the meeting's title, name, generated title and
    /// summary, key points, action items, or people.
    public static func matches(_ summary: SessionSummary, people: [String], query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        var fields = [summary.displayTitle, summary.name] + people
        if let generated = summary.generatedSummary {
            fields += [generated.title, generated.summary] + generated.points + generated.actions
        }
        let haystack = fields.joined(separator: "\n")
        return words.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
