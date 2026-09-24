import Darwin
import Dispatch

/// Asks a running recording to stop. `RecordingWorkflow.run` polls `shouldStop` every 100 ms. A stop from a
/// `SignalStopController` ends the recording with `StopReason.signal`; any other source (`ManualStopSource`)
/// and a `stop.request` file give `.requested`.
public protocol RecorderStopSource: Sendable {
    var shouldStop: Bool { get }
    /// Called once audio is durable, so a second signal ends processing immediately.
    func restoreDefaultHandlers()
}

/// SIGINT and SIGTERM request a graceful stop: audio is saved and transcription finishes.
/// After `restoreDefaultHandlers()` a further signal terminates the process, keeping the saved archive.
public final class SignalStopController: RecorderStopSource {
    private let requested = LockedValue(false)
    private let sources: [any DispatchSourceSignal]

    public init() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let state = requested
        sources = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { state.withLock { $0 = true } }
            source.resume()
            return source
        }
    }

    public var shouldStop: Bool { requested.value }

    public func restoreDefaultHandlers() {
        for source in sources { source.cancel() }
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }

    deinit { for source in sources { source.cancel() } }
}

/// A stop requested in code: tests, and a recording that runs inside the app.
public final class ManualStopSource: RecorderStopSource {
    private let requested = LockedValue(false)

    public init() {}

    public var shouldStop: Bool { requested.value }

    public func requestStop() { requested.withLock { $0 = true } }

    /// Nothing to restore: no signal handlers are installed.
    public func restoreDefaultHandlers() {}
}
