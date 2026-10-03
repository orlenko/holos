import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// What the Meetings list shows for a meeting (docs/design.md "Meetings list"): day groups, the line under the title,
// badges, the displayed title, and search. Invented meetings; a fixed calendar, time zone and locale.

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let posix = Locale(identifier: "en_US_POSIX")
/// Friday 2026-10-02 15:00 UTC.
private let listNow = Date(timeIntervalSince1970: 1_790_953_200)

private func meeting(_ id: String, name: String = "Meeting 2026-10-02 10:00", hoursAgo: Double = 1,
                     minutes: Double = 52, state: SessionState = .complete, speakers: SpeakerLabelState = .labelled,
                     summary: MeetingSummaryRecord? = nil, nameSource: MeetingNameSource? = nil,
                     audioDeleted: Bool = false) -> SessionSummary {
    SessionSummary(id: id, directory: URL(fileURLWithPath: "/\(id).holos"), name: name,
                   createdAt: listNow.addingTimeInterval(-hoursAgo * 3600), source: .microphone, state: state,
                   manifestStatus: state.rawValue, savedSeconds: minutes * 60, transcriptID: "T",
                   speakerState: speakers, liveness: .exited, audioDeleted: audioDeleted, nameSource: nameSource,
                   generatedSummary: summary)
}

private func record(_ title: String, _ text: String = "We agreed on the plan.", transcript: String = "T")
    -> MeetingSummaryRecord {
    MeetingSummaryRecord(sessionID: "S", transcriptID: transcript, title: title, summary: text,
                         points: ["The parser goes first."], actions: ["Robin books the room."], model: "fake")
}

@Test func groupsAreTodayYesterdayThisWeekThenMonths() {
    func title(_ hoursAgo: Double) -> String {
        MeetingListFormat.groupTitle(for: listNow.addingTimeInterval(-hoursAgo * 3600), now: listNow, calendar: utc,
                                     locale: posix)
    }
    #expect(title(1) == "Today")
    #expect(title(15) == "Today")
    #expect(title(16) == "Yesterday")
    #expect(title(24 * 3) == "This Week")
    #expect(title(24 * 6) == "This Week")
    #expect(title(24 * 7) == "September 2026")
    #expect(title(24 * 300) == "December 2025")
}

@Test func groupsKeepTheListOrderAndAppearOnce() {
    let live = meeting("live", hoursAgo: 24 * 40)
    let list = [live, meeting("a", hoursAgo: 1), meeting("b", hoursAgo: 30), meeting("c", hoursAgo: 2)]
    let groups = MeetingListFormat.groups(list, now: listNow, calendar: utc, locale: posix)
    #expect(groups.map(\.title) == ["August 2026", "Today", "Yesterday"])
    #expect(groups[1].meetings.map(\.id) == ["a", "c"])
}

@Test func theDetailLineSaysWhenHowLongAndWho() {
    // The formatter puts a narrow no-break space before AM and PM.
    func line(_ summary: SessionSummary, _ people: [String] = []) -> String {
        MeetingListFormat.detailLine(summary, people: people, now: listNow, calendar: utc, locale: posix)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
    #expect(line(meeting("a", hoursAgo: 5, minutes: 52), ["Alex", "Sam"]) == "10:00 AM · 52 min · Alex and Sam")
    #expect(line(meeting("b", hoursAgo: 24 * 20, minutes: 65)) == "Sat, Sep 12 at 3:00 PM · 1 h 05 min")
    #expect(line(meeting("c", hoursAgo: 24 * 3)).hasPrefix("Tuesday"))
    #expect(line(meeting("d", minutes: 0)) == "2:00 PM")
}

@Test func durationsAndPeopleReadNaturally() {
    #expect(MeetingListFormat.duration(45) == "45 s")
    #expect(MeetingListFormat.duration(3_120) == "52 min")
    #expect(MeetingListFormat.duration(10_692) == "2 h 58 min")
    #expect(MeetingListFormat.peopleText([]) == nil)
    #expect(MeetingListFormat.peopleText(["Alex"]) == "Alex")
    #expect(MeetingListFormat.peopleText(["Alex", "Sam", "Robin"]) == "Alex, Sam and Robin")
    #expect(MeetingListFormat.peopleText(["Alex", "Sam", "Robin", "Kim"]) == "Alex, Sam and 2 others")
}

@Test func badgesSayWhatNeedsSaying() {
    typealias Badge = MeetingListFormat.Badge
    #expect(MeetingListFormat.badges(meeting("a"), livePhase: nil, working: nil).isEmpty)
    #expect(MeetingListFormat.badges(meeting("a", state: .recording), livePhase: .recording, working: nil)
        == [Badge("● Recording", .live)])
    #expect(MeetingListFormat.badges(meeting("a"), livePhase: nil, working: "Final transcript queued")
        == [Badge("Final transcript queued", .progress)])
    #expect(MeetingListFormat.badges(meeting("a", state: .interrupted, speakers: .none), livePhase: nil, working: nil)
        == [Badge("Interrupted", .warning)])
    #expect(MeetingListFormat.badges(meeting("a", speakers: .notLabelled, audioDeleted: true), livePhase: nil,
                                     working: nil)
        == [Badge("No audio", .note), Badge("Speakers not labelled", .note)])
    #expect(MeetingListFormat.badges(meeting("a", speakers: .failed), livePhase: nil, working: nil)
        == [Badge("Speaker labels failed", .warning)])
}

@Test func theTitleIsTheUsersNameElseTheGeneratedOne() {
    #expect(meeting("a").displayTitle == "Meeting 2026-10-02 10:00")
    #expect(meeting("a", summary: record("Parser plan")).displayTitle == "Parser plan")
    #expect(meeting("a", name: "Weekly sync", summary: record("Parser plan")).displayTitle == "Weekly sync")
    // Recorded as default although it does not look like one (an imported file's name).
    #expect(meeting("a", name: "zoom_0412", summary: record("Parser plan"), nameSource: .default).displayTitle
        == "Parser plan")
    #expect(meeting("a", summary: record("Parser plan")).summaryIsCurrent)
    #expect(!meeting("a", summary: record("Parser plan", transcript: "T0")).summaryIsCurrent)
}

@Test func searchMatchesTitleSummaryPointsAndPeople() {
    let summary = meeting("a", summary: record("Parser plan", "Ship the café menu."))
    #expect(MeetingListFormat.matches(summary, people: ["Alex Rivera"], query: ""))
    #expect(MeetingListFormat.matches(summary, people: ["Alex Rivera"], query: "parser"))
    #expect(MeetingListFormat.matches(summary, people: ["Alex Rivera"], query: "CAFE"))
    #expect(MeetingListFormat.matches(summary, people: ["Alex Rivera"], query: "rivera plan"))
    #expect(MeetingListFormat.matches(summary, people: [], query: "robin"))
    #expect(!MeetingListFormat.matches(summary, people: [], query: "budget"))
    #expect(!MeetingListFormat.matches(summary, people: [], query: "parser budget"))
}
