import Darwin
import Foundation
import Synchronization

/// Seconds on a meeting's session timeline (docs/meeting-design.md §2.3): 0 is the first captured audio of epoch 0.
public protocol SessionClock: Sendable {
    func now() -> Double
}

/// The recorder's clock: continuous time (it keeps counting while the Mac sleeps) since epoch 0's capture origin.
///
/// Created right after epoch 0's `start()` returns, from the capture's host-time origin (host clock seconds,
/// `mach_absolute_time` based). It samples `mach_continuous_time()` and `mach_absolute_time()` together once to
/// convert that origin to continuous time; host time stops during sleep and continuous time does not, which is why
/// later epochs take their offset from this clock.
public struct ContinuousSessionClock: SessionClock {
    /// The capture origin in continuous-clock seconds.
    private let origin: Double

    public init(hostTimeOrigin: Double) {
        let continuous = Self.continuousSeconds()
        let host = Self.seconds(mach_absolute_time())
        origin = continuous - (host - hostTimeOrigin)
    }

    public func now() -> Double { Self.continuousSeconds() - origin }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func continuousSeconds() -> Double { seconds(mach_continuous_time()) }

    private static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
}

/// A clock that only moves when told: the test double.
public final class ManualSessionClock: SessionClock {
    private let value: Mutex<Double>

    public init(_ start: Double = 0) { value = Mutex(start) }

    public func now() -> Double { value.withLock { $0 } }

    public func advance(by seconds: Double) { value.withLock { $0 += seconds } }

    /// Sets the time (tests).
    public func set(_ seconds: Double) { value.withLock { $0 = seconds } }
}

/// Real time elapsed since the clock was made, for dependency bundles that must not depend on the capture's host
/// clock (the inert default of `RecordingDependencies.makeClock`).
struct ElapsedSessionClock: SessionClock {
    private let start = ContinuousClock.now

    func now() -> Double {
        let (seconds, attoseconds) = start.duration(to: .now).components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
