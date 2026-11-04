import AppKit
import Foundation
import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing
@testable import HolosApp

@MainActor
struct MeetingsPaneReadAgainTests {
    private static func meeting(in root: URL, name: String) throws {
        _ = try SessionArchive.create(root: root, name: name, source: .microphone, locale: "en-CA", backend: .speech)
    }

    /// The section as it is on screen; the fixture's window is never ordered front.
    private static func shown(_ root: URL) throws -> (NSWindow, MeetingsPane) {
        let (window, pane) = try LiveMeetingViewTests.meetings(size: .init(width: 1000, height: 700), root: root)
        pane.sectionDidShow()
        return (window, pane)
    }

    private static func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
        #expect(condition())
    }

    @Test func withNothingWorkingNothingPolls() async throws {
        let temp = try TemporaryDirectory("meetings-read-idle", permissions: 0o700)
        defer { temp.remove() }
        try Self.meeting(in: temp.url, name: "Council")
        let (_, pane) = try Self.shown(temp.url)
        try await Self.settle { pane.sessions.count == 1 }
        #expect(!pane.somethingIsWorking)
        #expect(!pane.isWaitingToReadAgain, "An idle list asks for no further read.")
    }

    @Test func aCommandStartsTheReadsAndTheirEndStopsThem() async throws {
        let temp = try TemporaryDirectory("meetings-read-work", permissions: 0o700)
        defer { temp.remove() }
        try Self.meeting(in: temp.url, name: "Council")
        let (_, pane) = try Self.shown(temp.url)
        try await Self.settle { pane.sessions.count == 1 }
        let id = try #require(pane.sessions.first?.id)
        pane.update(running: [id: "Labelling speakers…"])
        #expect(pane.isWaitingToReadAgain)
        try Self.meeting(in: temp.url, name: "Written by the command")
        try await Self.settle { pane.sessions.count == 2 }
        #expect(pane.isWaitingToReadAgain, "Still working: the next read is asked for.")
        pane.update(running: [:])
        try await Self.settle { !pane.isWaitingToReadAgain }
    }

    @Test func leavingTheSectionStopsTheReads() async throws {
        let temp = try TemporaryDirectory("meetings-read-hide", permissions: 0o700)
        defer { temp.remove() }
        let (_, pane) = try Self.shown(temp.url)
        pane.update(running: ["a": "Labelling speakers…"])
        #expect(pane.isWaitingToReadAgain)
        pane.sectionDidHide()
        #expect(!pane.isWaitingToReadAgain)
        pane.update(running: ["b": "Labelling speakers…"])
        #expect(!pane.isWaitingToReadAgain, "Off screen: the section reads when it shows again.")
    }

    @Test func theWindowBecomingKeyReadsTheList() async throws {
        let temp = try TemporaryDirectory("meetings-read-key", permissions: 0o700)
        defer { temp.remove() }
        let (window, pane) = try Self.shown(temp.url)
        try await Task.sleep(for: .milliseconds(200))
        #expect(pane.sessions.isEmpty)
        try Self.meeting(in: temp.url, name: "Council")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: NSWindow())
        try await Task.sleep(for: .milliseconds(200))
        #expect(pane.sessions.isEmpty, "Another window says nothing about this list.")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await Self.settle { pane.sessions.count == 1 }
    }
}
