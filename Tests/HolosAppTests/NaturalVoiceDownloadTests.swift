import AppKit
import Foundation
@testable import HolosContent
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosApp

/// Settings › Reading's natural voice download (`NaturalVoiceDownload`) and the watch on installs made
/// elsewhere (`NaturalVoicesWatch`, `NaturalVoicesInstallPoll`): nothing is downloaded.
@MainActor @Suite struct NaturalVoiceDownloadTests {
    @Test func aDownloadRunsSaysItsProgressAndEndsInstalled() {
        var download = NaturalVoiceDownload(pack: .english)
        #expect(download.row.button == "Download (530 MB)…")
        #expect(download.row.detail.contains("about 530 MB"))
        let result1 = download.start()
        #expect(result1)
        #expect(download.phase == .downloading(NaturalVoiceDownload.startingLine))
        let result2 = download.start()
        #expect(!result2)
        download.said("[19:20:09.487] [INFO] [FluidAudio.DownloadUtils] Found 48 files")
        #expect(download.phase == .downloading(NaturalVoiceDownload.startingLine))
        download.said("Natural voices (English): 45%")
        #expect(download.row.detail == "Natural voices (English): 45%")
        #expect(download.row.button == "Cancel")
        // The files are not looked at while this app's download runs.
        download.checked(.notInstalled)
        #expect(download.isRunning)
        download.ended(code: 0, lastLine: "Ready: natural voices (English, Kyutai Pocket TTS).", installed: true)
        #expect(download.phase == .installed)
        #expect(download.row.done)
        #expect(download.row.button == nil)
        let result3 = download.start()
        #expect(!result3)
    }

    @Test func cancelStopsTheDownloadAndOffersItAgain() {
        var download = NaturalVoiceDownload(pack: .french)
        let result4 = download.cancel()
        #expect(!result4)
        let result5 = download.start()
        #expect(result5)
        let result6 = download.cancel()
        #expect(result6)
        #expect(download.phase == .cancelling)
        #expect(!download.row.enabled)
        let result7 = download.cancel()
        #expect(!result7)
        download.ended(code: 143, lastLine: nil, installed: false)
        #expect(download.phase == .notInstalled)
        #expect(download.row.button == "Download (1.9 GB)…")
    }

    @Test func aFailureIsShownUntilTheFilesSayOtherwise() {
        var download = NaturalVoiceDownload(pack: .english)
        let result8 = download.start()
        #expect(result8)
        download.ended(code: 1, lastLine: "Error: Could not download the natural voices (offline).", installed: false)
        #expect(download.phase == .failed("Could not download the natural voices (offline)."))
        #expect(download.row.problem)
        #expect(download.row.button == "Try Again (530 MB)…")
        download.checked(.notInstalled)
        #expect(download.phase == .failed("Could not download the natural voices (offline)."))
        download.checked(.downloading)
        #expect(download.phase == .otherProcess)
        #expect(!download.row.enabled)
        download.checked(.installed)
        #expect(download.phase == .installed)
        var silent = NaturalVoiceDownload(pack: .english)
        let result9 = silent.start()
        #expect(result9)
        silent.ended(code: 9, lastLine: nil, installed: false)
        #expect(silent.phase == .failed("The download failed (code 9)."))
    }

    @Test func theMenusAreToldWhenPacksAreInstalledElsewhere() {
        var watch = NaturalVoicesWatch()
        let first = watch.observe([])
        #expect(!first)
        let same = watch.observe([])
        #expect(!same)
        // Installed from Terminal while the app was in the background.
        let installed = watch.observe([.english])
        #expect(installed)
        let again = watch.observe([.english])
        #expect(!again)
        let removed = watch.observe([])
        #expect(removed)
    }

    @Test func packsFoundByTheFirstLookFillTheMenusAgain() {
        // The menus were filled at launch before the packs were looked at (off the main actor): with none.
        var watch = NaturalVoicesWatch()
        let found = watch.observe([.english])
        #expect(found)
        let again = watch.observe([.english])
        #expect(!again)
    }

    @Test func anInstallElsewhereIsFollowedUntilItEnds() async {
        // What a fake status source says at each look: installing for three looks, then installed.
        var looks = 0
        var watch = NaturalVoicesWatch()
        _ = watch.observe([])
        var announced = 0
        var pauses = 0
        await NaturalVoicesInstallPoll.run(
            inProgress: { looks < 3 },
            check: {
                looks += 1
                if watch.observe(looks >= 3 ? [.english] : []) { announced += 1 }
            },
            pause: { pauses += 1 })
        // The check after the install ended told the menus once, and the polling stopped there.
        #expect(announced == 1)
        #expect(looks == 3)
        #expect(pauses == 3)
        // Nothing being installed: no polling at all.
        var idleChecks = 0
        await NaturalVoicesInstallPoll.run(inProgress: { false }, check: { idleChecks += 1 }, pause: {})
        #expect(idleChecks == 0)
    }
}
