import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// Free-space rules (docs/meeting-design.md §4.5). Sizes are decimal.

private let gigabyte: Int64 = 1_000_000_000

private func isRefuse(_ verdict: DiskVerdict) -> Bool { if case .refuse = verdict { true } else { false } }
private func isWarn(_ verdict: DiskVerdict) -> Bool { if case .warn = verdict { true } else { false } }
private func isStop(_ verdict: DiskVerdict) -> Bool { if case .stop = verdict { true } else { false } }

@Test func budgetsMatchTheWorkedValues() {
    #expect(DiskPolicy.captureBytesPerHour(.microphone) == 345_600_000)
    #expect(DiskPolicy.captureBytesPerHour(.system) == 345_600_000)
    #expect(DiskPolicy.captureBytesPerHour(.microphoneAndSystem) == 691_200_000)
    #expect(DiskPolicy.budgetBytesPerHour(.microphone) == 460_800_000)
    #expect(DiskPolicy.budgetBytesPerHour(.microphoneAndSystem) == 921_600_000)
    // mic: refuse below 3.84 GB, warn below 5.69 GB; mic+system: 5.69 GB and 9.37 GB.
    #expect(isRefuse(DiskPolicy.startCheck(freeBytes: 3_843_000_000, source: .microphone)))
    #expect(isWarn(DiskPolicy.startCheck(freeBytes: 3_844_000_000, source: .microphone)))
    #expect(isWarn(DiskPolicy.startCheck(freeBytes: 5_686_000_000, source: .microphone)))
    #expect(DiskPolicy.startCheck(freeBytes: 5_687_000_000, source: .microphone) == .ok)
    #expect(isRefuse(DiskPolicy.startCheck(freeBytes: 5_686_000_000, source: .microphoneAndSystem)))
    #expect(isWarn(DiskPolicy.startCheck(freeBytes: 9_372_000_000, source: .microphoneAndSystem)))
    #expect(DiskPolicy.startCheck(freeBytes: 9_373_000_000, source: .microphoneAndSystem) == .ok)
}

@Test func startCheckRefusesWarnsAndAllows() {
    #expect(isRefuse(DiskPolicy.startCheck(freeBytes: 3 * gigabyte, source: .microphone)))
    #expect(isWarn(DiskPolicy.startCheck(freeBytes: 5 * gigabyte, source: .microphone)))
    #expect(DiskPolicy.startCheck(freeBytes: 10 * gigabyte, source: .microphone) == .ok)
}

@Test func runtimeWarnsOnceAndRearms() {
    var warned = false
    var verdicts: [DiskVerdict] = []
    for free in [1_900_000_000, 1_900_000_000, 2_600_000_000, 1_900_000_000] as [Int64] {
        let result = DiskPolicy.runtimeCheck(freeBytes: free, warned: warned)
        verdicts.append(result.verdict)
        warned = result.warned
    }
    #expect(isWarn(verdicts[0]))
    #expect(verdicts[1] == .ok)
    #expect(verdicts[2] == .ok)
    #expect(isWarn(verdicts[3]))
    // Between 2 GB and 2.5 GB the warning stays armed as it was.
    #expect(DiskPolicy.runtimeCheck(freeBytes: 2_200_000_000, warned: true) == (.ok, true))
}

@Test func runtimeStopsBelow500MB() {
    #expect(isStop(DiskPolicy.runtimeCheck(freeBytes: 400_000_000, warned: false).verdict))
    #expect(isStop(DiskPolicy.runtimeCheck(freeBytes: 499_999_999, warned: true).verdict))
    #expect(isWarn(DiskPolicy.runtimeCheck(freeBytes: 500_000_000, warned: false).verdict))
}

@Test func renderCheckNeedsOneGigabyteHeadroom() {
    #expect(!DiskPolicy.renderCheck(freeBytes: 1_100_000_000, renderSeconds: 3_600, tracks: 1))
    #expect(DiskPolicy.renderCheck(freeBytes: 1_200_000_000, renderSeconds: 3_600, tracks: 1))
    #expect(!DiskPolicy.renderCheck(freeBytes: 1_200_000_000, renderSeconds: 3_600, tracks: 2))
}

@Test func estimateTextShowsCaptureOnly() {
    #expect(DiskPolicy.estimateText(source: .microphone, hours: 3, freeBytes: 24_100_000_000)
            == "≈1.0 GB for 3 h · 24.1 GB free")
    #expect(DiskPolicy.estimateText(source: .microphoneAndSystem, hours: 3, freeBytes: 24_100_000_000)
            == "≈2.1 GB for 3 h · 24.1 GB free")
    #expect(DiskPolicy.estimateText(source: .microphone, hours: 1.5, freeBytes: 0) == "≈0.5 GB for 1.5 h · 0.0 GB free")
}

/// A disk that refuses the start leaves no session behind.
@Test(.timeLimit(.minutes(1))) @MainActor
func refusedStartCreatesNoSession() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let captures = FakeCaptureFactory()
    var dependencies = RecordingDependencies.testing(captures: captures)
    dependencies.freeSpace = FixedFreeSpace(3 * gigabyte)
    await #expect(throws: HolosError.self) {
        try await RecordingWorkflow.run(.testing(root: temp.url), dependencies: dependencies)
    }
    #expect(sessionFolders(in: temp.url).isEmpty)
    #expect(captures.requests.isEmpty)
}
