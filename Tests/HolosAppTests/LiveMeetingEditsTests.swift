import AppKit
import Foundation
import HolosMeeting
import Testing
@testable import HolosApp

/// Correcting and naming phrases while a meeting records (docs/design.md "Live transcript"): the selected phrase
/// survives the view re-rendering its words four times a second, stays in view, and is offered on a right-click.
/// Invented words and names.
@MainActor
struct LiveMeetingEditsTests {
    /// Windows the tests make stay alive until the run ends, as AppKit expects of a window it laid out.
    private static var windows: [NSWindow] = []

    private static func run(_ text: String, segment: String, start: Double) -> LiveRun {
        LiveRun(text: text, isFinal: true, segmentID: segment, firstWord: 0,
                endWord: text.split(separator: " ").count, start: start, end: start + 2)
    }

    private static let first = LiveParagraph(track: "mic", start: 3, runs: [run("the budget looks fine", segment: "M1",
                                                                              start: 3)])
    private static func later(_ volatile: String) -> [LiveParagraph] {
        [first, LiveParagraph(track: "system", start: 20, runs: [
            run("next item on the agenda", segment: "S1", start: 20), LiveRun(text: volatile, isFinal: false),
        ])]
    }

    /// The live view of a recording meeting, in a window that is never shown.
    private static func recording() throws -> (LiveMeetingViewController, NSTextView) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-edits-\(UUID().uuidString)")
        let live = LiveMeetingViewController(sessionID: "S", directory: directory, onBack: {}, onOpenFinished: {},
                                             knownNames: { ["Robin", "Alex"] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentViewController = live
        live.update(header: LiveMeetingHeader(name: "Meeting", phase: .recording, detail: "0:01:00"),
                    finishedAction: nil)
        Self.windows.append(window)
        return (live, try #require(live.preferredFirstResponder as? NSTextView))
    }

    @Test func theSelectedPhraseStaysSelectedAsNewWordsArrive() throws {
        let (live, text) = try Self.recording()
        live.show(Self.later("and"))
        let budget = (text.string as NSString).range(of: "budget")
        text.setSelectedRange(budget)
        #expect(live.canEditSelection)
        #expect(!live.followsNewWords, "Selecting a phrase holds the view still.")
        for words in ["and then", "and then we", "and then we can"] {
            live.show(Self.later(words))
            #expect(text.selectedRange() == budget, "Still the same word after \"\(words)\".")
            #expect(live.canEditSelection)
        }
    }

    @Test func rightClickingAPhraseOffersItsEdits() throws {
        let (live, text) = try Self.recording()
        live.show(Self.later("and"))
        let agenda = (text.string as NSString).range(of: "agenda")
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [],
                                                    timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                                    clickCount: 1, pressure: 1))
        let menu = try #require(live.textView(text, menu: NSMenu(), for: event, at: agenda.location + 2))
        #expect(menu.items.prefix(2).map(\.title) == ["Correct Text…", "Name Speaker…"])
        #expect(text.selectedRange() == agenda, "The word under the pointer is selected.")
        #expect(live.canEditSelection)
        let volatile = (text.string as NSString).range(of: "and", options: .backwards)
        let plain = try #require(live.textView(text, menu: NSMenu(), for: event, at: volatile.location))
        #expect(plain.items.isEmpty, "Words not yet final have no edits.")
    }

    @Test func theSelectionFollowsItsPhraseAndStaysInside() throws {
        let short = LiveEditTarget(range: NSRange(location: 10, length: 4),
                                   hint: LiveHint(segmentID: "A", track: "mic", firstWord: 0, endWord: 2, start: 0,
                                                  end: 1, heard: "ab c", action: .replaceText("ab c")))
        var long = short
        long.range = NSRange(location: 40, length: 12)
        let anchor = try #require(LiveSelectionAnchor(selected: NSRange(location: 49, length: 0), targets: [long]))
        #expect(anchor.range(in: [long]) == NSRange(location: 49, length: 0))
        #expect(anchor.range(in: [short]) == NSRange(location: 13, length: 0),
                "An insertion point past a shortened phrase stays on it.")
        let words = try #require(LiveSelectionAnchor(selected: NSRange(location: 38, length: 8), targets: [long]))
        #expect(words.range(in: [long]) == NSRange(location: 40, length: 6), "Only the part in the phrase.")
        #expect(LiveSelectionAnchor(selected: NSRange(location: 0, length: 5), targets: [long]) == nil)
    }

    @Test func nameChoicesPutThisMeetingFirstAndNameEachPersonOnce() {
        #expect(LiveSpeakerNames.choices(inMeeting: ["Sam", "sam", " Kim "], known: ["Robin", "SAM", ""])
            == ["Sam", "Kim", "Robin"])
    }

    @Test func theCorrectionFieldOpensWithTheSelectedWordsHighlighted() throws {
        let field = PreselectingTextField(string: "the budget looks fine")
        field.initialSelection = NSRange(location: 4, length: 6)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 10, y: 10, width: 360, height: 24)
        Self.windows.append(window)
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor()?.selectedRange == NSRange(location: 4, length: 6))
    }
}
