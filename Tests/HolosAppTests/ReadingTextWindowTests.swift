import AppKit
@testable import HolosContent
import Testing
@testable import HolosApp

@MainActor @Suite struct ReadingTextWindowTests {
    private static let text = "First sentence here. Second sentence here.\n\nThird paragraph."

    private func timeline(_ text: String = Self.text) throws -> ReadingTimeline {
        let part = ReadingPart(index: 0, sourceUTF16Offset: 0, sourceUTF16Length: text.utf16.count,
                               textSHA256: sha256(Data(text.utf8)), relativeAudioPath: "", chapter: nil, startsSection: true,
                               status: "complete", audioSHA256: nil, duration: 60)
        let manifest = ReadingManifest(kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                                       sourceSHA256: "", voiceIdentifier: "v", rate: nil, title: nil, author: nil,
                                       language: nil, comment: "", format: .current, output: "/tmp/o.m4a",
                                       outputSHA256: nil, duration: 60, chapters: [], status: "complete", parts: [part])
        return try #require(ReadingTimeline(manifest: manifest, text: text))
    }

    private func window(timeline: ReadingTimeline?) -> ReadingTextWindow {
        let window = ReadingTextWindow(entryID: UUID(), title: "A Guide", text: Self.text, timeline: timeline, length: 60)
        window.window?.setContentSize(NSSize(width: 680, height: 500))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @Test func theTextIsSelectableButNotEditable() throws {
        let window = window(timeline: nil)
        #expect(window.textView.string == Self.text)
        #expect(window.textView.isSelectable && !window.textView.isEditable)
        #expect(window.window?.title == "A Guide")
        #expect(window.textView.textLayoutManager != nil)
    }

    @Test func theSentenceBeingSpokenIsHighlightedWithoutTouchingTheTextOrSelection() throws {
        let window = window(timeline: try timeline())
        window.textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(window.highlightedRange == nil)
        window.show(.init(playing: true, current: 0, duration: 60))
        #expect(window.highlightedRange == (Self.text as NSString).range(of: "First sentence here."))
        window.show(.init(playing: true, current: 25, duration: 60))
        #expect(window.highlightedRange == (Self.text as NSString).range(of: "Second sentence here."))
        #expect(window.primaryTitle == "❚❚ Pause")
        #expect(window.textView.string == Self.text)
        #expect(window.textView.selectedRange().length == 0)
        #expect(window.textView.textStorage?.attribute(.backgroundColor, at: 25, effectiveRange: nil) == nil)
        window.show(nil)
        #expect(window.highlightedRange == nil)
        #expect(window.primaryTitle == "▶ Play")
    }

    @Test func scrollingOrSelectingStopsFollowingUntilAskedAgain() throws {
        let window = window(timeline: try timeline())
        #expect(window.followsVoice)
        window.userScrolledForTesting()
        #expect(!window.followsVoice)
        window.show(.init(playing: true, current: 25, duration: 60))
        #expect(window.highlightedRange != nil)

        window.followButton.performClick(nil)
        #expect(window.followsVoice)
        window.textView.setSelectedRange(NSRange(location: 0, length: 5))
        #expect(!window.followsVoice)
    }

    /// The last parts still playing from memory: the bar shows the place and does not offer to move it.
    @Test func theBarDoesNotOfferToMoveAReadingPlayingFromItsParts() throws {
        let window = window(timeline: nil)
        func slider() -> NSSlider? {
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            return all(window.seek).compactMap { $0 as? NSSlider }.first
        }
        window.show(.init(playing: true, current: 25, duration: 60, seekable: false))
        #expect(slider()?.isEnabled == false)
        window.show(.init(playing: true, current: 25, duration: 60))
        #expect(slider()?.isEnabled == true)
    }

    @Test func withoutATimelineTheTextStillShowsAndFollowingIsOff() {
        let window = window(timeline: nil)
        window.show(.init(playing: true, current: 25, duration: 60))
        #expect(window.highlightedRange == nil)
        #expect(!window.followsVoice)
        #expect(!window.followButton.isEnabled)
        #expect(window.followButton.toolTip?.contains("not kept") == true)
    }

    @Test func copyTextCopiesTheWholeText() {
        let window = window(timeline: nil)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("reading-text-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        window.pasteboard = pasteboard
        window.copyText()
        #expect(pasteboard.string(forType: .string) == Self.text)
    }

    /// A conventional mouse wheel posts no live-scroll notification, and following must stop for it too.
    @Test func aMouseWheelStopsFollowingButATrackpadsMomentumDoesNot() throws {
        func wheel(momentum: Bool) throws -> NSEvent {
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40,
                                             wheel2: 0, wheel3: 0))
            if momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) }
            return try #require(NSEvent(cgEvent: event))
        }
        let window = window(timeline: try timeline())
        window.textView.scrollWheel(with: try wheel(momentum: true))
        #expect(window.followsVoice)
        window.textView.scrollWheel(with: try wheel(momentum: false))
        #expect(!window.followsVoice)
    }

    /// Following scrolls to a sentence far into a long text and keeps it in view; a sentence near it does not move the page.
    @Test func followingScrollsToTheSentenceInALongText() throws {
        let paragraph = "A sentence of ordinary length that wraps around the line a little. "
        let text = String(repeating: paragraph + paragraph + "\n\n", count: 400)
        let window = ReadingTextWindow(entryID: UUID(), title: "Long", text: text, timeline: try timeline(text), length: 60)
        window.window?.setContentSize(NSSize(width: 680, height: 500))
        window.window?.contentView?.layoutSubtreeIfNeeded()
        window.textView.layoutSubtreeIfNeeded()
        #expect(window.textView.visibleRect.minY == 0)
        window.show(.init(playing: true, current: 45, duration: 60))
        let scrolled = window.textView.visibleRect.minY
        #expect(scrolled > 1_000)
        let shown = try #require(window.highlightedRange)
        #expect(shown.location > text.utf16.count / 2)
    }
}
