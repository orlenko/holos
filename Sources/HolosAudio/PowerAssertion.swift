import Foundation
import HolosCore
import IOKit.pwr_mgt
import os
import Synchronization

/// Keeps the Mac from idle-sleeping while a meeting records (docs/meeting-design.md §4.4). Lid close and forced sleep
/// still happen. Held from `starting` through post-processing, except while the meeting is paused.
public final class PowerAssertion: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "power")

    /// The IOKit assertion; nil once released.
    private let assertion: Mutex<IOPMAssertionID?>

    /// `kIOPMAssertionTypePreventUserIdleSystemSleep` named `reason`. Released by `release()` or deinit.
    public init(reason: String) throws {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw HolosError.unavailable("Could not keep the Mac awake for the recording (IOKit error \(result)).")
        }
        assertion = Mutex(id)
        Self.log.notice("Took the idle-sleep assertion")
    }

    /// Lets the Mac idle-sleep again. Later calls do nothing.
    public func release() {
        guard let id = assertion.withLock({ value -> IOPMAssertionID? in
            defer { value = nil }
            return value
        }) else { return }
        let result = IOPMAssertionRelease(id)
        if result == kIOReturnSuccess {
            Self.log.notice("Released the idle-sleep assertion")
        } else {
            Self.log.error("Could not release the idle-sleep assertion (IOKit error \(result, privacy: .public))")
        }
    }

    deinit { release() }
}
