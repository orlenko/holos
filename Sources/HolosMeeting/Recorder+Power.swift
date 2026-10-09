import Foundation
import HolosCore
import os

extension Recorder {
    // MARK: - Power

    /// Display sleep prevention ends before sleep/pause/stop cleanup; forced sleep/lock/lid close remain possible.
    func holdDisplay(_ hold: Bool) {
        guard hold != displayHeld else { return }
        displayHeld = hold
        if hold {
            displayAssertion = dependencies.makeDisplayAssertion(Self.powerAssertionName)
        } else {
            displayAssertion?.release()
            displayAssertion = nil
        }
    }

    /// Lets every pending sleep go ahead (IOAllowPowerChange).
    func allowSleep() {
        sleepDeadline = nil
        guard !pendingSleepTokens.isEmpty else { return }
        let tokens = pendingSleepTokens
        pendingSleepTokens.removeAll()
        for token in tokens { dependencies.power?.allowPowerChange(token: token) }
        Self.log.notice("Session \(self.archive.id, privacy: .public) allowed the system to sleep")
    }

    /// Takes or releases the idle-sleep assertion.
    func holdPower(_ hold: Bool) {
        guard hold != powerHeld else { return }
        powerHeld = hold
        if hold {
            powerAssertion = dependencies.makePowerAssertion(Self.powerAssertionName)
        } else {
            powerAssertion?.release()
            powerAssertion = nil
        }
    }

    static let powerAssertionName = "Voice is Local meeting recording"
    /// The `retryNow` reason when a tick sees the lid open again.
    static let lidOpened = RecorderMachine.lidOpened

    /// "5" or "0.2": a limit in seconds for a message.
    static func seconds(_ duration: Duration) -> String {
        let (whole, fraction) = duration.components
        return fraction == 0 ? String(whole)
            : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), Double(whole) + Double(fraction) / 1e18)
    }

    func internalStopRequest(sender: String) -> ControlRequest {
        let request = ControlRequest(sessionID: archive.id, command: .stop,
                                     sentAtNanos: RecorderChannel.continuousNanoseconds(), sender: sender)
        internalRequests.insert(request.id)
        return request
    }
}
