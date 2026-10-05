import HolosCore
import Foundation
import ScreenCaptureKit
import Testing
@testable import HolosAudio

/// Stop-before-start is checked before any permission request or device/content lookup. No hardware is opened.
@Test(arguments: [AudioSource.microphone, .system, .microphoneAndSystem]) @MainActor
func aStoppedCaptureCannotStartLater(source: AudioSource) async throws {
    let capture = AudioCapture()
    try await capture.stop()
    await #expect(throws: CancellationError.self) {
        try await capture.start(source: source)
    }
}

@Test
func onlyDeliberateScreenCaptureStopsAreNormalized() {
    let stop = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue)
    #expect(CaptureInterruption.screenCaptureError(stop) as? CaptureInterruption == .userStoppedSharing)
    let otherDomain = NSError(domain: "synthetic.other", code: stop.code)
    let otherCode = NSError(domain: SCStreamErrorDomain, code: stop.code - 1)
    #expect(CaptureInterruption.screenCaptureError(otherDomain) as NSError === otherDomain)
    #expect(CaptureInterruption.screenCaptureError(otherCode) as NSError === otherCode)
}

@Test
func onlyAnAlreadyStoppedStreamConfirmsCleanupDespiteAnError() {
    let stopped = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.attemptToStopStreamState.rawValue)
    let failed = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.failedToStopAudioCapture.rawValue)
    #expect(CaptureInterruption.isAlreadyStoppedStream(stopped))
    #expect(!CaptureInterruption.isAlreadyStoppedStream(failed))
    #expect(!CaptureInterruption.isAlreadyStoppedStream(NSError(domain: "synthetic.other", code: stopped.code)))
}
