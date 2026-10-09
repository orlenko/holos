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

    @Test func anInstallThatEndsDuringALookWaitsForTheNextOne() async {
        let state = NaturalVoicesAppState()
        let looks = Mutex(0)
        let firstMayEnd = DispatchSemaphore(value: 0)
        state.scan = {
            let look = looks.withLock { value -> Int in
                value += 1
                return value
            }
            // The first look reads the pack while its install still runs, and ends only after the tool exited.
            if look == 1 {
                firstMayEnd.wait()
                return [.english: .downloading, .french: .notInstalled]
            }
            return [.english: .installed, .french: .notInstalled]
        }
        state.refresh()
        #expect(await eventually { looks.withLock { $0 } == 1 })
        // The tool exits now: what is asked for after that comes from a look that starts after it.
        let seen = Mutex<DeepModelStatus?>(nil)
        state.refresh(fresh: true) { seen.withLock { $0 = state.statuses[.english] } }
        firstMayEnd.signal()
        #expect(await eventually { seen.withLock { $0 } != nil })
        #expect(seen.withLock { $0 } == .installed)
        #expect(looks.withLock { $0 } == 2)
    }
}
