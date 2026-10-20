import Testing
@testable import HolosSpeakers

@Test func weakCorrelationWindowsDoNotHideAConsistentEchoPath() throws {
    let windows = (0..<100).map { index in
        EchoAnalysis.DelayWindow(
            centre: 5 + Double(index) * 30,
            milliseconds: index < 12 ? 60 : 200 + Double(index) * 11,
            peakRatio: index < 18 ? 80 : 5)
    }
    let fit = EchoAnalysis.fitDelay(windows)
    #expect(fit.windows == 100)
    #expect(fit.confidentWindows == 18)
    #expect(fit.agreeingWindows == 12)
    #expect(abs(try #require(fit.milliseconds(at: 180)) - 60) < 0.01)
    #expect(EchoAnalysis.isPresent(fit, duration: 3_000))
}

@Test func echoStillNeedsSeveralConfidentWindowsThatAgree() {
    let insufficient = EchoAnalysis.DelayFit(windows: 100, confidentWindows: 2, agreeingWindows: 2,
                                             startMilliseconds: 60, driftMillisecondsPerHour: 0)
    #expect(!EchoAnalysis.isPresent(insufficient, duration: 3_000))
    let scattered = EchoAnalysis.DelayFit(windows: 100, confidentWindows: 20, agreeingWindows: 5,
                                         startMilliseconds: 60, driftMillisecondsPerHour: 0)
    #expect(!EchoAnalysis.isPresent(scattered, duration: 3_000))
}

@Test(arguments: [-5.0, 0, 0.5, 1_501])
func aConsistentNonPhysicalDelayIsNotRoomEcho(milliseconds: Double) {
    let fit = EchoAnalysis.DelayFit(windows: 100, confidentWindows: 18, agreeingWindows: 12,
                                    startMilliseconds: milliseconds, driftMillisecondsPerHour: 0)
    #expect(!EchoAnalysis.isPresent(fit, duration: 3_000))
}
