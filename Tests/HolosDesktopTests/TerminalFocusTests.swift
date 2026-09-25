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

/// Returns `reads` in order, counting how many were taken.
private final class Reads {
    private var remaining: [Focus]
    private(set) var taken = 0
    init(_ reads: [Focus]) { remaining = reads }
    func next() -> Focus {
        taken += 1
        return remaining.removeFirst()
    }
}

@Test func captureKeepsAFocusTwoConsecutiveReadsAgreeOn() {
    let a = Focus(pid: 7, window: "window 1", element: "session A")
    let steady = Reads([a, a])
    #expect(Focus.settled(steady.next) == a)
    #expect(steady.taken == 2)
    // A terminal that exposes nothing agrees with itself and is tracked by the frontmost app.
    #expect(Focus.settled(Reads([Focus(pid: 7), Focus(pid: 7)]).next)?.tracking == .app)
}

@Test func captureRereadsAfterAFocusChangeWithoutWeakeningTracking() {
    let a = Focus(pid: 7, window: "window 1", element: "session A")
    let b = Focus(pid: 7, window: "window 1", element: "session B")
    // The user switched tabs between the first two reads; the next two agree on the new session.
    let switched = Reads([a, b, b])
    let focus = Focus.settled(switched.next)
    #expect(focus == b)
    #expect(focus?.tracking == .session)
    #expect(switched.taken == 3)
}

@Test func captureRefusesAFocusThatNeverSettles() {
    // Every read differs, whether from repeated switching or an identity that is new on every read.
    let reads = (0..<4).map { Focus(pid: 7, window: "window 1", element: "session \($0)") }
    let unstable = Reads(reads)
    #expect(Focus.settled(unstable.next) == nil)
    #expect(unstable.taken == 4)
    // An identity that drops out between reads (an Accessibility timeout) is a disagreement too.
    let a = Focus(pid: 7, window: "window 1", element: "session A")
    let dropping = Focus(pid: 7, window: "window 1", element: nil)
    #expect(Focus.settled(Reads([a, dropping, a, dropping]).next) == nil)
}

@Test func appOnlyTrackingReadsNoAccessibilityWhileTyping() {
    var levels: [Focus.Tracking] = []
    let appOnly = Focus(pid: 7)
    #expect(appOnly.stillAdmitted { levels.append($0); return Focus(pid: 7) })
    #expect(levels.isEmpty)
}

@Test func windowTrackingReadsOnlyTheWindowWhileTyping() {
    var levels: [Focus.Tracking] = []
    let byWindow = Focus(pid: 7, window: "window 1")
    #expect(byWindow.stillAdmitted { levels.append($0); return Focus(pid: 7, window: "window 1") })
    #expect(!byWindow.stillAdmitted { levels.append($0); return Focus(pid: 7, window: "window 2") })
    #expect(levels == [.window, .window])

    levels = []
    let bySession = Focus(pid: 7, window: "window 1", element: "session A")
    #expect(!bySession.stillAdmitted { levels.append($0); return Focus(pid: 7, window: "window 1", element: "session B") })
    #expect(levels == [.session])
}
