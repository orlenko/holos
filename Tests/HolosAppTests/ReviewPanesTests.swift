import AppKit
import Foundation
import HolosCore
import HolosMeeting
import HolosSpeakers
import Testing
@testable import HolosApp

/// The review window's speakers pane hidden and shown, and the turn list with short interjections hidden or shown,
/// laid out offscreen (the windows are never shown). Synthetic text only.
@MainActor
struct ReviewPanesTests {
    @Test func hidingTheSpeakersPaneGivesTheTurnListItsWidth() throws {
        let speakers = NSView()
        let list = NSView()
        let panes = Self.panes(speakers: speakers, list: list)
        let width = panes.view.frame.width
        #expect(width == 1100)
        #expect(!panes.speakersHidden)
        #expect(speakers.frame.width >= ReviewPanes.speakersMinimumWidth)
        #expect(list.frame.width < width - ReviewPanes.speakersMinimumWidth)
        var reported: [Bool] = []
        panes.onSpeakersHiddenChange = { reported.append($0) }

        // Asked to animate, in a window that is not on screen: hidden at once.
        panes.setSpeakersHidden(true, animated: true)
        panes.view.layoutSubtreeIfNeeded()
        #expect(panes.speakersHidden)
        #expect(panes.speakersItem.isCollapsed)
        #expect(list.frame.width == width)
        #expect(list.frame.minX == 0)
        #expect(reported == [true])
        // Asking again changes nothing.
        panes.setSpeakersHidden(true, animated: false)
        #expect(reported == [true])

        panes.setSpeakersHidden(false, animated: false)
        panes.view.layoutSubtreeIfNeeded()
        #expect(!panes.speakersHidden)
        #expect(speakers.frame.width >= ReviewPanes.speakersMinimumWidth)
        #expect(list.frame.width >= ReviewPanes.listMinimumWidth)
        #expect(list.frame.width < width - ReviewPanes.speakersMinimumWidth)
        #expect(reported == [true, false])
    }

    @Test func thePaneOpensHiddenWhenItWasLeftHidden() {
        let panes = Self.panes(speakers: NSView(), list: NSView(), hidden: true)
        #expect(panes.speakersHidden)
        #expect(ReviewWindow.speakersTitle(hidden: true) == "Show Speakers")
        #expect(ReviewWindow.speakersTitle(hidden: false) == "Hide Speakers")
    }

    @Test func eachMeetingRemembersItsOwnPane() throws {
        let suite = "ReviewPanesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = ReviewSpeakersPaneMemory(defaults: defaults)
        #expect(!memory.isHidden(sessionID: "A"))
        memory.setHidden(true, sessionID: "A")
        #expect(memory.isHidden(sessionID: "A"))
        #expect(!memory.isHidden(sessionID: "B"))
        memory.setHidden(false, sessionID: "A")
        #expect(!memory.isHidden(sessionID: "A"))
        // At most `limit` meetings: the oldest is forgotten first.
        for index in 0...ReviewSpeakersPaneMemory.limit { memory.setHidden(true, sessionID: "M\(index)") }
        #expect(!memory.isHidden(sessionID: "M0"))
        #expect(memory.isHidden(sessionID: "M1"))
        #expect(memory.isHidden(sessionID: "M\(ReviewSpeakersPaneMemory.limit)"))
        #expect(defaults.stringArray(forKey: ReviewSpeakersPaneMemory.key)?.count == ReviewSpeakersPaneMemory.limit)
    }

    @Test func showShortInterjectionsListsTheHiddenTurnsAgain() throws {
        let (projection, transcript) = Self.meeting()
        #expect(projection.interjections == ["T2": .hidden, "T5": .attached(speakerID: "S2")])
        let list = Self.list()
        // Off (the default): the lone "an" is not listed, so Avery's turns are one row, and the words that finish
        // Blake's sentence are in Blake's row.
        Self.update(list, projection.shownTurns(includingHidden: false), projection: projection, transcript: transcript)
        #expect(list.paragraphs.map(\.turnIDs) == [["T1", "T3"], ["T4", "T5"]])
        let blake = try Self.cell(list, row: 1)
        #expect(blake.bodyText.string == "We asked them, but they agreed to it.")
        #expect(blake.speakerPopUp.titleOfSelectedItem == "2 · Blake")
        // On: the hidden turn is a row of the unknown speaker again; the attached one stays with Blake.
        Self.update(list, projection.shownTurns(includingHidden: true), projection: projection, transcript: transcript)
        #expect(list.paragraphs.map(\.turnIDs) == [["T1"], ["T2"], ["T3"], ["T4", "T5"]])
        let hidden = try Self.cell(list, row: 1)
        #expect(hidden.bodyText.string == "an")
        #expect(hidden.speakerPopUp.titleOfSelectedItem == "Unknown")
        #expect(list.table.numberOfRows == 4)
    }

    /// The View menu's items have no target: AppKit sends them up the key window's responder chain, where the window
    /// hands an action it does not answer to its delegate, the `ReviewWindow` (which also validates them).
    @Test func theViewMenusReviewItemsReachTheWindowsController() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = ReviewKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                                     backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = ViewMenuController()
        window.delegate = controller
        // The selectors the main menu's View items send (AppKeyboard) are the window's methods.
        let actions = ["toggleSpeakers:", "toggleShortInterjections:"].map(NSSelectorFromString)
        #expect(actions == [#selector(ReviewWindow.toggleSpeakers(_:)),
                            #selector(ReviewWindow.toggleShortInterjections(_:))])
        for action in actions {
            #expect(window.supplementalTarget(forAction: action, sender: nil) as AnyObject? === controller)
        }
        window.delegate = nil
        #expect(window.supplementalTarget(forAction: actions[0], sender: nil) == nil)
    }

    /// Answers the View menu's review actions as `ReviewWindow` does.
    final class ViewMenuController: NSObject, NSWindowDelegate {
        @objc func toggleSpeakers(_ sender: Any?) {}
        @objc func toggleShortInterjections(_ sender: Any?) {}
    }

    // MARK: - Fixtures

    static var windows: [NSWindow] = []

    /// Panes of `speakers` and `list` in a 1100 × 600 window that is never shown, laid out.
    static func panes(speakers: NSView, list: NSView, hidden: Bool = false) -> ReviewPanes {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let panes = ReviewPanes(speakers: speakers, list: list)
        panes.setSpeakersHidden(hidden, animated: false)
        window.contentView = panes.view
        windows.append(window)
        panes.view.layoutSubtreeIfNeeded()
        return panes
    }

    static func list() -> TurnListView {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let list = TurnListView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = list
        windows.append(window)
        return list
    }

    static func update(_ list: TurnListView, _ turns: [ProjectedTurn], projection: SpeakerProjection,
                       transcript: Transcript) {
        list.update(paragraphs: ReviewParagraphs.group(turns), speakers: projection.speakers, people: [],
                    editable: true, hints: [:],
                    text: { TranscriptExporter.text(of: $0.spans, in: transcript) }, words: { _ in [] },
                    resolve: { $0 })
        list.layoutSubtreeIfNeeded()
        list.table.layoutSubtreeIfNeeded()
    }

    static func cell(_ list: TurnListView, row: Int) throws -> TurnCellView {
        let cell = try #require(list.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TurnCellView)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// Avery: "That part is fine.", an unknown "an", Avery again; Blake: "We asked them, but they", then an unknown
    /// "agreed to it." right after.
    static func meeting() -> (SpeakerProjection, Transcript) {
        let lines: [(id: String, start: Double, speaker: String?, text: String)] = [
            ("T1", 0, "S1", "That part is fine."),
            ("T2", 2.2, nil, "an"),
            ("T3", 3, "S1", "It makes sense."),
            ("T4", 5, "S2", "We asked them, but they"),
            ("T5", 7.3, nil, "agreed to it."),
        ]
        var segments: [TranscriptSegment] = []
        var turns: [SpeakerTurn] = []
        for line in lines {
            var words: [TimedWord] = []
            for (index, token) in line.text.split(separator: " ").enumerated() {
                let start = line.start + Double(index) * 0.4
                words.append(TimedWord(text: String(token), start: start, end: start + 0.4,
                                       utf16Offset: line.text.utf16.distance(from: line.text.startIndex,
                                                                             to: token.startIndex),
                                       utf16Length: token.utf16.count))
            }
            let segment = TranscriptSegment(id: "seg-\(line.id)", start: line.start, end: words.last?.end ?? line.start,
                                            text: line.text, words: words, track: "system")
            segments.append(segment)
            turns.append(SpeakerTurn(id: line.id, track: "system", start: segment.start, end: segment.end,
                                     speakerID: line.speaker, clusterID: line.speaker,
                                     spans: [WordSpan(segmentID: segment.id, first: 0, end: words.count)],
                                     overlap: false, otherClusters: [],
                                     assignmentScore: line.speaker == nil ? 0 : 0.9, timing: .measured))
        }
        let transcript = Transcript(id: "TRANSCRIPT", source: "mic+system", locale: "en-CA", backend: .speech,
                                    segments: segments)
        let run = DiarizationRun(
            id: "RUN", sessionID: "SESSION", createdAt: Date(timeIntervalSince1970: 0), transcriptID: "TRANSCRIPT",
            engine: .fake, alignment: AlignmentInfo(version: 1, parameters: .v1, trackOffsets: ["system": 0]),
            tracks: [TrackDiarization(track: "system", policy: .diarized)],
            speakers: [SessionSpeaker(id: "S1", ordinal: 1, provenance: .diarizer, clusterIDs: ["S1"]),
                       SessionSpeaker(id: "S2", ordinal: 2, provenance: .diarizer, clusterIDs: ["S2"])],
            turns: turns)
        let edits = [SpeakerEditAction.rename(speakerID: "S1", name: "Avery"),
                     .rename(speakerID: "S2", name: "Blake")].enumerated().map { index, action in
            SpeakerEdit(id: "E\(index)", baseRunID: "RUN", at: Date(timeIntervalSince1970: 0), source: "cli",
                        action: action)
        }
        let projection = SpeakerProjection.make(run: run, transcript: transcript, edits: edits, recognition: nil,
                                                profileNames: [:])
        return (projection, transcript)
    }
}
