import Testing
@testable import HolosDesktop

private typealias Focus = TerminalFocus<String>

@Test func terminalSessionTrackingStopsOnTabPaneOrWindowSwitch() {
    let keyDown = Focus(pid: 7, window: "window 1", element: "session A")
    #expect(keyDown.tracking == .session)
    #expect(keyDown.admits(keyDown))
    // Another tab or pane in the same window: the focused session element changes.
    #expect(!keyDown.admits(Focus(pid: 7, window: "window 1", element: "session B")))
    // Another window of the same terminal.
    #expect(!keyDown.admits(Focus(pid: 7, window: "window 2", element: "session C")))
    // Another app became frontmost.
    #expect(!keyDown.admits(Focus(pid: 8, window: "window 1", element: "session A")))
}

@Test func terminalFocusThatCanNoLongerBeReadStopsTyping() {
    let keyDown = Focus(pid: 7, window: "window 1", element: "session A")
    #expect(!keyDown.admits(Focus(pid: 7, window: "window 1", element: nil)))
    #expect(!keyDown.admits(Focus(pid: 7, window: nil, element: "session A")))
    #expect(!keyDown.admits(Focus(pid: 7)))
}

@Test func terminalExposingOnlyItsWindowIsTrackedByWindow() {
    let keyDown = Focus(pid: 7, window: "window 1", element: nil)
    #expect(keyDown.tracking == .window)
    #expect(!keyDown.admits(Focus(pid: 7, window: "window 2")))
    // A pane switch inside one window is undetectable here: the terminal reports no focused element.
    #expect(keyDown.admits(Focus(pid: 7, window: "window 1")))
    // An element the terminal starts reporting later is not held against it.
    #expect(keyDown.admits(Focus(pid: 7, window: "window 1", element: "session B")))
}

@Test func terminalExposingNothingFallsBackToTheFrontmostApp() {
    let keyDown = Focus(pid: 7)
    #expect(keyDown.tracking == .app)
    #expect(keyDown.admits(Focus(pid: 7, window: "window 2", element: "session B")))
    #expect(!keyDown.admits(Focus(pid: 8)))
}

@Test func unstableTerminalIdentitiesAreNotTracked() {
    let first = Focus(pid: 7, window: "window 1", element: "session A")
    #expect(first.keepingStable(first) == first)
    // An element that is new on every read would stop typing at the first check, so only the window is kept.
    let fresh = first.keepingStable(Focus(pid: 7, window: "window 1", element: "session A'"))
    #expect(fresh == Focus(pid: 7, window: "window 1", element: nil))
    #expect(fresh.tracking == .window)
    #expect(first.keepingStable(Focus(pid: 7, window: "window 1'", element: "session A'")).tracking == .app)
    #expect(first.keepingStable(Focus(pid: 8, window: "window 1", element: "session A")) == Focus(pid: 7))
}
