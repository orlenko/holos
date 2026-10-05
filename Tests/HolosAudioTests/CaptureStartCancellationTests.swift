import HolosCore
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
