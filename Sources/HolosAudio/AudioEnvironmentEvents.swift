import CoreAudio
import Dispatch
import Foundation
import os
import Synchronization

/// Changes after which a recorder that is waiting for audio retries at once (docs/meeting-design.md §4.2): the
/// CoreAudio device list changed (`kAudioHardwarePropertyDevices`), or the screen was unlocked (the
/// `com.apple.screenIsUnlocked` distributed notification). Reasons are buffered in a `Mutex` until the recorder loop
/// reads them.
public final class AudioEnvironmentEvents: Sendable {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "capture")

    /// The CoreAudio device list changed.
    public static let audioDevicesChanged = "audioDevicesChanged"
    /// The screen was unlocked.
    public static let screenUnlocked = "screenUnlocked"

    private let buffer: ReasonBuffer
    private let devices: SystemAudioListener?
    private let unlock: UnlockObserver?

    /// Starts listening for device-list changes and screen unlocks.
    public convenience init() {
        let buffer = ReasonBuffer()
        let devices = SystemAudioListener(selector: kAudioHardwarePropertyDevices, label: "ca.orlenko.holos.devices") {
            buffer.post(AudioEnvironmentEvents.audioDevicesChanged)
        }
        if !devices.installed {
            AudioEnvironmentEvents.log.error("Cannot watch the audio device list; waiting recordings retry on schedule")
        }
        let unlock = UnlockObserver { buffer.post(AudioEnvironmentEvents.screenUnlocked) }
        self.init(buffer: buffer, devices: devices, unlock: unlock)
    }

    private init(buffer: ReasonBuffer, devices: SystemAudioListener?, unlock: UnlockObserver?) {
        self.buffer = buffer; self.devices = devices; self.unlock = unlock
    }

    /// Tests only: listens to nothing; `post` stands in for the system.
    static func silent() -> AudioEnvironmentEvents {
        AudioEnvironmentEvents(buffer: ReasonBuffer(), devices: nil, unlock: nil)
    }

    /// "audioDevicesChanged" or "screenUnlocked", buffered since the last call, each at most once, in first-seen order.
    public func pendingReasons() -> [String] { buffer.take() }

    /// Stops listening; buffered reasons are dropped.
    public func stop() {
        devices?.remove()
        unlock?.remove()
        buffer.close()
    }

    /// Buffers `reason` as if the system had reported it (tests; the listeners use the buffer directly).
    func post(_ reason: String) { buffer.post(reason) }

    deinit { stop() }
}

/// Reasons waiting for the loop.
private final class ReasonBuffer: Sendable {
    private struct State {
        var reasons: [String] = []
        var closed = false
    }

    private let state = Mutex(State())

    func post(_ reason: String) {
        state.withLock { state in
            guard !state.closed, !state.reasons.contains(reason) else { return }
            state.reasons.append(reason)
        }
    }

    func take() -> [String] {
        state.withLock { state in
            defer { state.reasons.removeAll() }
            return state.reasons
        }
    }

    func close() {
        state.withLock { state in
            state.closed = true
            state.reasons.removeAll()
        }
    }
}

/// A listener for one property of the CoreAudio system object, called on a private queue. `@unchecked Sendable` around
/// the listener block: it is set once in `init` and removed at most once (`removed` guards it).
final class SystemAudioListener: @unchecked Sendable {
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private let address: AudioObjectPropertyAddress
    private let removed = Mutex(false)
    /// False when CoreAudio refused the listener.
    let installed: Bool

    init(selector: AudioObjectPropertySelector, label: String, handler: @escaping @Sendable () -> Void) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        block = { _, _ in handler() }
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        var target = address
        installed = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &target, queue,
                                                        block) == noErr
    }

    func remove() {
        let first = removed.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        guard first, installed else { return }
        var target = address
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &target, queue, block)
    }

    deinit { remove() }
}

/// The `com.apple.screenIsUnlocked` observer. `@unchecked Sendable` around the observer token: set once in `init` and
/// removed at most once (`removed` guards it).
private final class UnlockObserver: @unchecked Sendable {
    private let token: any NSObjectProtocol
    private let removed = Mutex(false)

    init(_ handler: @escaping @Sendable () -> Void) {
        token = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in handler() }
    }

    func remove() {
        let first = removed.withLock { value -> Bool in
            defer { value = true }
            return !value
        }
        if first { DistributedNotificationCenter.default().removeObserver(token) }
    }

    deinit { remove() }
}
