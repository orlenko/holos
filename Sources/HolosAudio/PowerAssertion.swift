import Foundation
import HolosCore
import IOKit.pwr_mgt
import os
import Synchronization

/// Prevents idle system or display sleep (docs/meeting-design.md §4.4), never lid close or forced sleep.
/// System assertions span processing; display assertions are held only while capture is active.
public protocol PowerAssertionHandle: Sendable {
    func release()
}

public final class PowerAssertion: PowerAssertionHandle {
    public enum Kind: Sendable {
        case system
        case display
    }
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "power")

    /// The IOKit assertion; nil once released.
    private let assertion: Mutex<IOPMAssertionID?>

    /// The selected idle-sleep assertion named `reason`. Released by `release()` or deinit.
    public init(reason: String, kind: Kind = .system) throws {
        var id: IOPMAssertionID = 0
        let type = kind == .display ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                                    : kIOPMAssertionTypePreventUserIdleSystemSleep
        let result = IOPMAssertionCreateWithName(type as CFString,
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
