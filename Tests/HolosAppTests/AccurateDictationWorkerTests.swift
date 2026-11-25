import Foundation
import HolosCore
import HolosMeeting
import HolosTestSupport
import Testing
@testable import HolosApp

@MainActor private func testLauncher(in temp: TemporaryDirectory, body: String) throws -> MaintenanceLauncher {
    let script = temp.url.appendingPathComponent("helper")
    try ("#!/bin/sh\nset -eu\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return MaintenanceLauncher(executable: script)
}

private func frame(start: Double = 0) throws -> PCMFrame {
    try PCMFrame(samples: Array(repeating: 0.125, count: 8000), sampleRate: 16_000, channels: 1, startTime: start)
}

@Test @MainActor func accurateDictationWorkerHandsTheHelperOnlyPrivateFilesAndCleansUp() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let launcher = try testLauncher(in: temp, body: """
        test "$1" = accurate-dictation
        test "$3" = --request
        test "$#" = 4
        test -s "$2"
        test "$(stat -f %Lp "$2")" = 600
        test "$(stat -f %Lp "$4")" = 600
        test "$(stat -f %Lp "$(dirname "$4")")" = 700
        case "$*" in *KNYTE*) exit 1;; esac
        grep -q KNYTE "$4"
        echo '{"text":"Keep KNYTE"}'
        """)
    let worker = AccurateDictationWorker(model: .whisper, locale: "en-CA", vocabulary: ["KNYTE"],
                                         temporaryRoot: temp.url, launcher: launcher)
    try await worker.append(frame())
    #expect(try await worker.finish().map(\.text) == ["Keep KNYTE"])
    let files = try FileManager.default.contentsOfDirectory(atPath: worker.folder.path)
    #expect(files.contains { $0.hasPrefix(TemporaryArtifact.prefix) }, "The worker owns the helper output until discard.")
    worker.discard()
    AccurateDictationWorker.finishCleanupAtQuit()
    #expect(!FileInspection.exists(worker.folder))
}

@Test(arguments: [Int32(69), 0]) @MainActor
func accurateDictationFailureHidesHelperDiagnosticsAndDiscardsAudio(code: Int32) async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let launcher = try testLauncher(in: temp, body: """
        echo 'private fixture words' >&2
        if [ \(code) -ne 0 ]; then echo '{"text":"partial fixture"}'; else echo 'damaged output'; fi
        exit \(code)
        """)
    let worker = AccurateDictationWorker(model: .parakeet, locale: "en", vocabulary: [],
                                         temporaryRoot: temp.url, launcher: launcher)
    try await worker.append(frame())
    do {
        _ = try await worker.finish()
        Issue.record("A failing helper returned a transcript")
    } catch {
        #expect(error.localizedDescription.contains(code == 0 ? "unreadable" : "could not load"))
        #expect(!error.localizedDescription.contains("private fixture"))
    }
    worker.discard()
    AccurateDictationWorker.finishCleanupAtQuit()
    #expect(!FileInspection.exists(worker.folder))
}

@Test(.timeLimit(.minutes(1))) @MainActor func cancellingAccurateDictationTerminatesTheHelperAndDeletesItsFiles() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let launcher = try testLauncher(in: temp, body: "exec /bin/sleep 120")
    let worker = AccurateDictationWorker(model: .whisper, locale: "en", vocabulary: [],
                                         temporaryRoot: temp.url, launcher: launcher)
    try await worker.append(frame())
    let finalization = Task { try await worker.finish() }
    #expect(await eventually { !launcher.runningPIDs.isEmpty })
    finalization.cancel()
    worker.discard()
    await #expect(throws: CancellationError.self) { try await finalization.value }
    #expect(launcher.runningPIDs.isEmpty)
    AccurateDictationWorker.finishCleanupAtQuit()
    #expect(!FileInspection.exists(worker.folder))
}

@Test(.timeLimit(.minutes(1))) @MainActor func accurateDictationPickerChecksBothModelsAndInstallsOnlyOnClick() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let suite = UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let launcher = try testLauncher(in: temp, body: """
        cd "$(dirname "$0")"
        test "$1" = setup
        case "$2" in --whisper|--parakeet) ;; *) exit 1 ;; esac
        if [ "$#" -eq 3 ]; then
            test "$3" = --status
            if [ -e "installed$2" ]; then echo '"installed"'; else echo '"notInstalled"'; fi
        else
            touch "installed$2"
        fi
        """)
    let settings = AccurateDictationSettings(defaults)
    let controls = AccurateDictationControls(settings: settings, launcher: launcher)
    #expect(settings.model == .whisper)
    controls.refresh(changeable: true, enabled: true)
    for index in [0, 1] {
        controls.model.selectItem(at: index)
        controls.chooseModel()
        #expect(await eventually { controls.status.stringValue == "Not installed" })
        let marker = temp.url.appendingPathComponent("installed--" + settings.model.rawValue)
        #expect(!FileInspection.exists(marker))
        #expect(!controls.download.isHidden)
        controls.downloadChosen()
        #expect(await eventually { controls.status.stringValue == "Installed" })
        #expect(FileInspection.exists(marker))
        #expect(controls.download.isHidden)
    }
    controls.refresh(changeable: true, enabled: false)
    #expect(controls.download.isHidden && !controls.model.isEnabled)
    #expect(AccurateDictationSettings(defaults).model == .parakeet)
}

@Test @MainActor func accurateDictationDiscardsAnInterruptedRecordingWithoutLaunchingAHelper() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let launcher = try testLauncher(in: temp, body: "exit 1")
    let worker = AccurateDictationWorker(model: .whisper, locale: "en", vocabulary: [],
                                         temporaryRoot: temp.url, launcher: launcher)
    try await worker.append(frame())
    await #expect(throws: HolosError.self) { try await worker.append(frame(start: 2)) }
    worker.discard()
    AccurateDictationWorker.finishCleanupAtQuit()
    #expect(!FileInspection.exists(worker.folder))
    #expect(launcher.runningPIDs.isEmpty)
}

@Test @MainActor func accurateDictationRecoversAbandonedScratchAndKeepsLiveCaptures() throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let abandoned = temp.url.appendingPathComponent("holos-dictation-\(Int32.max)-\(UUID().uuidString)")
    let active = temp.url.appendingPathComponent("holos-dictation-\(getpid())-\(UUID().uuidString)")
    let unrelated = temp.url.appendingPathComponent("holos-dictation-\(Int32.max)-other")
    for url in [abandoned, active, unrelated] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    AccurateDictationWorker.removeAbandonedCaptures(in: temp.url)
    AccurateDictationWorker.finishCleanupAtQuit()
    #expect(!FileInspection.exists(abandoned))
    #expect(FileInspection.exists(active))
    #expect(FileInspection.exists(unrelated))
}
