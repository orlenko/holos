import Foundation
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosApp

/// The app's natural voices state (`NaturalVoicesAppState`, HolosApp+Reading.swift): the packs are looked at off the
/// main actor, and one download runs at a time.
@MainActor @Suite struct NaturalVoicesAppStateTests {
    @Test func thePacksAreLookedAtOffTheMainActorAndKept() async {
        let state = NaturalVoicesAppState()
        let onMain = Mutex<Bool?>(nil)
        state.scan = {
            onMain.withLock { $0 = Thread.isMainThread }
            return [.english: .installed, .french: .downloading]
        }
        let done = Mutex(0)
        state.refresh { done.withLock { $0 += 1 } }
        // A second ask during the look gets that look's result, not a look of its own.
        state.refresh { done.withLock { $0 += 1 } }
        #expect(await eventually { done.withLock { $0 } == 2 })
        #expect(onMain.withLock { $0 } == false)
        #expect(state.installed == [.english])
        #expect(state.statuses[.french] == .downloading)
        #expect(state.downloads[.english]?.phase == .installed)
    }

    @Test func oneDownloadRunsAtATime() {
        let state = NaturalVoicesAppState()
        #expect(state.mayStart(.english))
        #expect(state.mayStart(.french))
        var english = NaturalVoiceDownload(pack: .english)
        let started = english.start()
        #expect(started)
        state.downloads[.english] = english
        #expect(!state.mayStart(.french))
        // Its own row may still act (Cancel).
        #expect(state.mayStart(.english))
    }
}
