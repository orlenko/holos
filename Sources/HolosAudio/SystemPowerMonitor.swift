import Dispatch
import Foundation
import HolosCore
import IOKit
import IOKit.pwr_mgt
import os
import Synchronization

/// A system power change the recorder loop reacts to (docs/meeting-design.md §4.4).
public enum PowerEvent: Sendable, Equatable {
    /// The system will sleep. The loop calls `allowPowerChange(token:)` after closing chunks.
    case willSleep(token: Int)
    /// The system woke (fully, or a dark wake).
    case didWake
}

/// A power event with how long before the drain that returned it the event arrived.
public struct TimedPowerEvent: Sendable, Equatable {
    public var event: PowerEvent
    /// Seconds of continuous time (it keeps counting while the Mac sleeps) from the event's arrival to the drain.
    public var secondsAgo: Double

    public init(_ event: PowerEvent, secondsAgo: Double = 0) {
        self.event = event; self.secondsAgo = secondsAgo
    }
}

/// System sleep and wake, polled by the recorder loop every 100 ms. The test seam for `SystemPowerMonitor`.
public protocol SystemPowerEvents: Sendable {
    /// Events buffered since the last call.
    func pendingEvents() -> [PowerEvent]
    /// Events buffered since the last call, with their age. The loop times sleep and wake by it: when the loop is held
    /// up (a slow restart) and macOS sleeps without waiting for it, willSleep and didWake are drained together after
    /// the wake, and only their arrival times tell how long the Mac slept. The default reports every event as new.
    func pendingTimedEvents() -> [TimedPowerEvent]
    func allowPowerChange(token: Int)
    /// AppleClamshellState from IOPMrootDomain; true when the property is absent.
    func isLidOpen() -> Bool
    /// From the recorder's start until its loop attaches: sleep and wake are queued for the loop, but willSleep is
    /// acknowledged at once (nothing is recording yet, and the Mac is never held awake by a start that is waiting).
    func observe()
    /// The loop acknowledges willSleep itself, after closing its chunks. Events queued while observing are kept.
    func attach()
    /// Neither observing nor attached: the monitor acknowledges willSleep itself and queues nothing.
    func detach()
}

extension SystemPowerEvents {
    public func pendingTimedEvents() -> [TimedPowerEvent] { pendingEvents().map { TimedPowerEvent($0) } }
}

/// `IORegisterForSystemPower` on a private dispatch queue (docs/meeting-design.md §4.4). Events are buffered in a
/// `Mutex` for the loop. "Can sleep" queries are allowed at once. "Will sleep" is handed to the loop only while one is
/// attached, and the loop acknowledges it after closing its chunks. While the recorder starts (`observe()`), sleep and
/// wake are queued for the loop that will attach, but the monitor acknowledges "will sleep" itself; while detached
/// (during transcription and post-processing) it acknowledges and queues nothing. Holos never delays a lid close
/// except to close the chunks of a running loop.
public final class SystemPowerMonitor: SystemPowerEvents {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "power")

    // IOKit's iokit_common_msg values (IOMessage.h); the macros are not imported into Swift.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemWillNotSleep: UInt32 = 0xE000_0290
    static let systemHasPoweredOn: UInt32 = 0xE000_0300
    static let systemWillPowerOn: UInt32 = 0xE000_0320

    private let core: PowerEventCore
    /// The IOKit registration; nil for a monitor made for tests.
    private let registration: PowerRegistration?
    /// Tests only: the lid state.
    private let lidState: (@Sendable () -> Bool)?

    /// Registers for system power notifications. Throws `HolosError.unavailable` when IOKit refuses.
    public init() throws {
        let port = PowerPort()
        let core = PowerEventCore { token in
            let root = port.value
            guard root != IO_OBJECT_NULL else { return }
            let result = IOAllowPowerChange(root, token)
            if result != kIOReturnSuccess {
                Self.log.error("IOAllowPowerChange failed (IOKit error \(result, privacy: .public))")
            }
        }
        let queue = DispatchQueue(label: "ca.orlenko.holos.power", qos: .userInitiated)
        let refcon = Unmanaged.passRetained(core)
        var notifyPort: IONotificationPortRef?
        var notifier: io_object_t = IO_OBJECT_NULL
        let root = IORegisterForSystemPower(refcon.toOpaque(), &notifyPort, { refcon, _, message, argument in
            guard let refcon else { return }
            Unmanaged<PowerEventCore>.fromOpaque(refcon).takeUnretainedValue()
                .receive(message: message, argument: Int(bitPattern: argument),
                         at: PowerEventCore.continuousNanoseconds())
        }, &notifier)
        guard root != IO_OBJECT_NULL, let notifyPort else {
            refcon.release()
            throw HolosError.unavailable("Cannot watch for system sleep (IORegisterForSystemPower failed).")
        }
        port.set(root)
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        registration = PowerRegistration(queue: queue, rootPort: root, notifyPort: notifyPort, notifier: notifier,
                                         refcon: refcon, rootDomain: rootDomain, port: port)
        self.core = core
        lidState = nil
        // Messages are delivered on `queue` from here on.
        IONotificationPortSetDispatchQueue(notifyPort, queue)
        Self.log.notice("Watching for system sleep and wake")
    }

    /// Tests only: no IOKit registration. `acknowledge` stands in for `IOAllowPowerChange`; `deliver` stands in for a
    /// message from IOKit.
    init(acknowledge: @escaping @Sendable (Int) -> Void, lidOpen: @escaping @Sendable () -> Bool = { true }) {
        core = PowerEventCore(acknowledge: acknowledge)
        registration = nil
        lidState = lidOpen
    }

    /// Tests only: handles `message` as if IOKit had sent it, `nanosecondsAgo` before now.
    func deliver(_ message: UInt32, argument: Int, nanosecondsAgo: UInt64 = 0) {
        core.receive(message: message, argument: argument, at: PowerEventCore.continuousNanoseconds() - nanosecondsAgo)
    }

    public func pendingEvents() -> [PowerEvent] { core.pendingTimedEvents().map(\.event) }

    /// Events stamped with `mach_continuous_time` when IOKit delivered them.
    public func pendingTimedEvents() -> [TimedPowerEvent] { core.pendingTimedEvents() }

    public func allowPowerChange(token: Int) { core.allowPowerChange(token: token) }

    public func isLidOpen() -> Bool {
        if let lidState { return lidState() }
        return registration?.isLidOpen() ?? true
    }

    public func observe() { core.observe() }

    public func attach() { core.attach() }

    public func detach() { core.detach() }

    /// Acknowledges anything pending and stops watching. Later messages are not received.
    public func stop() {
        core.detach()
        core.stop()
        registration?.tearDown()
    }

    deinit { stop() }
}

/// The buffer between IOKit's queue and the recorder loop.
final class PowerEventCore: Sendable {
    private struct State {
        var attached = false
        /// Queueing for a loop that has not attached yet; willSleep is acknowledged at once.
        var observing = false
        var stopped = false
        /// Events with their arrival in `mach_continuous_time` nanoseconds.
        var events: [(event: PowerEvent, at: UInt64)] = []
        /// willSleep tokens handed to the loop and not yet acknowledged.
        var outstanding: Set<Int> = []
    }

    private let state = Mutex(State())
    private let acknowledge: @Sendable (Int) -> Void

    init(acknowledge: @escaping @Sendable (Int) -> Void) { self.acknowledge = acknowledge }

    /// `at`: when IOKit delivered the message, in `mach_continuous_time` nanoseconds.
    func receive(message: UInt32, argument: Int, at: UInt64) {
        switch message {
        case SystemPowerMonitor.canSystemSleep:
            // Idle sleep is prevented by the power assertion, not by vetoing here.
            acknowledge(argument)
        case SystemPowerMonitor.systemWillSleep:
            let held = state.withLock { state -> Bool in
                guard !state.stopped, state.attached || state.observing else { return false }
                state.events.append((.willSleep(token: argument), at))
                guard state.attached else { return false }
                state.outstanding.insert(argument)
                return true
            }
            if !held { acknowledge(argument) }
        case SystemPowerMonitor.systemHasPoweredOn:
            state.withLock { state in
                if !state.stopped, state.attached || state.observing { state.events.append((.didWake, at)) }
            }
        default:
            break
        }
    }

    /// The buffered events, each with its age at this call.
    func pendingTimedEvents() -> [TimedPowerEvent] {
        let events = state.withLock { state in
            defer { state.events.removeAll() }
            return state.events
        }
        let now = Self.continuousNanoseconds()
        return events.map { TimedPowerEvent($0.event, secondsAgo: Double(now > $0.at ? now - $0.at : 0) / 1e9) }
    }

    /// `mach_continuous_time` in nanoseconds: it keeps counting while the Mac sleeps.
    static func continuousNanoseconds() -> UInt64 {
        let ticks = mach_continuous_time()
        let base = timebase
        guard base.numer != base.denom, base.denom != 0 else { return ticks }
        return UInt64(Double(ticks) * Double(base.numer) / Double(base.denom))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Acknowledges a willSleep handed to the loop, once.
    func allowPowerChange(token: Int) {
        let pending = state.withLock { $0.outstanding.remove(token) != nil }
        if pending { acknowledge(token) }
    }

    func observe() { state.withLock { if !$0.stopped { $0.observing = true } } }

    /// Queued events (from observing) stay for the loop.
    func attach() { state.withLock { if !$0.stopped { $0.attached = true } } }

    /// Stops queueing, drops queued events, and acknowledges every willSleep the loop has not.
    func detach() {
        let tokens = state.withLock { state -> [Int] in
            state.attached = false
            state.observing = false
            state.events.removeAll()
            defer { state.outstanding.removeAll() }
            return state.outstanding.sorted()
        }
        for token in tokens { acknowledge(token) }
    }

    func stop() { state.withLock { $0.stopped = true } }
}

/// The root power port, set once IOKit has registered the monitor.
private final class PowerPort: Sendable {
    private let port = Mutex<io_connect_t>(IO_OBJECT_NULL)
    var value: io_connect_t { port.withLock { $0 } }
    func set(_ value: io_connect_t) { port.withLock { $0 = value } }
}

/// One IOKit power registration. `@unchecked Sendable` around C handles: every handle is set once in `init` and
/// released exactly once, after `released` is set under its lock. The notification handles are released on the
/// notification queue, so no message is being handled then; the root domain is read only under the lock, before that.
private final class PowerRegistration: @unchecked Sendable {
    private let queue: DispatchQueue
    private let rootPort: io_connect_t
    private let notifyPort: IONotificationPortRef
    private var notifier: io_object_t
    private let refcon: Unmanaged<PowerEventCore>
    private let rootDomain: io_service_t
    private let port: PowerPort
    private let released = Mutex(false)

    init(queue: DispatchQueue, rootPort: io_connect_t, notifyPort: IONotificationPortRef, notifier: io_object_t,
         refcon: Unmanaged<PowerEventCore>, rootDomain: io_service_t, port: PowerPort) {
        self.queue = queue; self.rootPort = rootPort; self.notifyPort = notifyPort; self.notifier = notifier
        self.refcon = refcon; self.rootDomain = rootDomain; self.port = port
    }

    /// `AppleClamshellState` of IOPMrootDomain is false; true when it is absent (no lid) or after `tearDown`.
    func isLidOpen() -> Bool {
        released.withLock { released in
            guard !released, rootDomain != IO_OBJECT_NULL,
                  let value = IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  CFGetTypeID(value) == CFBooleanGetTypeID(), let closed = value as? Bool else { return true }
            return !closed
        }
    }

    func tearDown() {
        let first = released.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        guard first else { return }
        queue.sync {
            IODeregisterForSystemPower(&notifier)
            port.set(IO_OBJECT_NULL)
            IOServiceClose(rootPort)
            IONotificationPortDestroy(notifyPort)
        }
        if rootDomain != IO_OBJECT_NULL { IOObjectRelease(rootDomain) }
        refcon.release()
    }
}
