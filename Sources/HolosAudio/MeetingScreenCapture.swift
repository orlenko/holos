import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import HolosCore
import HolosStorage
import ImageIO
import os
import ScreenCaptureKit
import Synchronization
import UniformTypeIdentifiers

/// What a meeting's optional screen capture records (docs/meeting-design.md §4.15). `record start --screen` takes the
/// raw value, or `off`.
public enum ScreenCaptureTarget: String, Codable, Sendable, Equatable, CaseIterable {
    /// Every display, each in its own stream, every window on them except Voice is Local's own; a display connected
    /// during the meeting is added, one disconnected ends its stream. What the app asks for.
    case display
    /// Only the main display (the one with the menu bar), as before all displays were captured.
    case main
}

/// The pure decisions behind the display filters, testable without ScreenCaptureKit objects or a permission.
public enum ScreenCapturePlan {
    /// The app and its bundled `voiceislocal` tool: the live transcript, Review, and the menu are never captured
    /// and read back into the meeting's context.
    public static let ownBundleIdentifiers: Set<String> = ["ca.orlenko.holos.app", "ca.orlenko.holos.cli"]

    /// Whether an application is Voice is Local itself: one of its bundle identifiers, this process's, or this
    /// process (a development build run under another identifier).
    public static func isOwn(bundleIdentifier: String, processID: Int32,
                             currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
                             currentBundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        processID == currentProcessID || ownBundleIdentifiers.contains(bundleIdentifier)
            || (currentBundleIdentifier.map { !$0.isEmpty && $0 == bundleIdentifier } ?? false)
    }

    /// The applications every display's filter leaves out (`SCContentFilter(display:excludingApplications:…)`).
    public static func excluded<Application>(_ applications: [Application],
                                             bundleIdentifier: (Application) -> String,
                                             processID: (Application) -> Int32,
                                             currentProcessID: Int32 = ProcessInfo.processInfo.processIdentifier,
                                             currentBundleIdentifier: String? = Bundle.main.bundleIdentifier)
        -> [Application] {
        applications.filter {
            isOwn(bundleIdentifier: bundleIdentifier($0), processID: processID($0),
                  currentProcessID: currentProcessID, currentBundleIdentifier: currentBundleIdentifier)
        }
    }

    /// The main display, or the first one when the main display is not listed (it is being reconfigured).
    public static func display<Display>(_ displays: [Display], id: (Display) -> CGDirectDisplayID,
                                        main: CGDirectDisplayID = CGMainDisplayID()) -> Display? {
        displays.first { id($0) == main } ?? displays.first
    }

    /// The displays a target captures: all of them, or the main one alone.
    public static func displays(_ candidates: [ScreenDisplayCandidate],
                                for target: ScreenCaptureTarget) -> [ScreenDisplayCandidate] {
        switch target {
        case .display: candidates
        case .main:
            display(candidates, id: \.id, main: candidates.first(where: \.isMain)?.id ?? kCGNullDirectDisplay)
                .map { [$0] } ?? []
        }
    }

    /// The stream's frame size: the display's pixels, scaled down so neither side exceeds
    /// `ScreenContextStore.maximumImageDimension` (5K → 2560×1440), never below 2×2.
    public static func size(pixelWidth: Int, pixelHeight: Int,
                            maximum: Int = ScreenContextStore.maximumImageDimension) -> (width: Int, height: Int) {
        let width = max(1, pixelWidth), height = max(1, pixelHeight)
        let scale = min(1, Double(max(1, maximum)) / Double(max(width, height)))
        return (max(2, Int((Double(width) * scale).rounded())), max(2, Int((Double(height) * scale).rounded())))
    }
}

/// The cheap view of the display arrangement the capture polls: which displays are connected, and which is main.
struct ScreenDisplayLayout: Equatable, Sendable {
    var ids: [CGDirectDisplayID]
    var main: CGDirectDisplayID
    /// Each display that shows another's picture, and the display it mirrors: mirroring turned on or off leaves the
    /// IDs and the main display as they were.
    var mirroring: [CGDirectDisplayID: CGDirectDisplayID] = [:]

    /// Whether a ScreenCaptureKit snapshot lists every display this layout says can be captured (every active
    /// display that mirrors none). While displays are being reconfigured, CoreGraphics can already report a new
    /// display that the snapshot still leaves out; such a refresh is tried again.
    func isCovered(by candidates: [ScreenDisplayCandidate]) -> Bool {
        Set(ids.filter { mirroring[$0] == nil }).isSubset(of: candidates.map(\.id))
    }

    /// A snapshot's display that this layout says is connected and mirrors none.
    func isCapturable(_ candidate: ScreenDisplayCandidate) -> Bool {
        ids.contains(candidate.id) && mirroring[candidate.id] == nil
    }
}

/// What the capture needs from ScreenCaptureKit and CoreGraphics. Tests use a fake, so hot-plug, stream failures and
/// the shared caps run without a stream, a screen or the permission.
@MainActor protocol ScreenCaptureSystem: AnyObject {
    /// The connected displays' IDs, the main one and mirroring, cheaply (`CGGetActiveDisplayList`, `CGMainDisplayID`,
    /// `CGDisplayMirrorsDisplay`): polled to notice a display come or go, the main display change, or mirroring.
    func layout() -> ScreenDisplayLayout
    /// The displays that can be captured now (`SCShareableContent`).
    func displays() async throws -> [ScreenDisplayCandidate]
    /// One display's stream, not started yet; its samples go to `output` on the capture's queue.
    func stream(for display: ScreenDisplay, output: ScreenDisplayOutput) throws -> any ScreenStreamControl
}

/// One display's stream. `stop` may come while `start` is still pending: a meeting that stops during a slow platform
/// start must not leave the screen captured until that start returns. ScreenCaptureKit holds a stream's output and
/// delegate weakly, so the capture keeps each `ScreenDisplayOutput` while its stream may run.
@MainActor protocol ScreenStreamControl: AnyObject {
    func start() async throws
    func stop() async
}

/// One display's stream for as long as it may run: its control, its output (ScreenCaptureKit holds that only
/// weakly, so this keeps it), whether it broke while starting, and its phase. Callbacks name a stream by its token,
/// never by its display alone, so nothing an old stream of a display does can touch a newer one of the same display.
@MainActor final class ScreenDisplayStream {
    enum Phase { case starting, running, stopped }
    let display: ScreenDisplay
    let token: UUID
    let control: any ScreenStreamControl
    let output: ScreenDisplayOutput
    var phase = Phase.starting

    init(display: ScreenDisplay, token: UUID, control: any ScreenStreamControl, output: ScreenDisplayOutput) {
        self.display = display; self.token = token; self.control = control; self.output = output
    }
}

/// Optional screen capture, independent of audio: one stream per display, all writing one timeline in
/// `screen/context.json`. Startup never delays the audio consumer.
///
/// Hot-plug: every `pollInterval` the capture compares the display layout (connected IDs, the main display and
/// mirroring: cheap CoreGraphics calls that work in the command-line recorder, which has no AppKit run loop for the
/// display-reconfiguration callback) with that of the last complete refresh; only when they differ, or a stream stops
/// with an error, does it ask ScreenCaptureKit again and start or stop streams (`ScreenDisplayRoster`). CoreGraphics
/// says which displays are connected: a display the ScreenCaptureKit snapshot still lists after CoreGraphics dropped
/// it counts as gone. A refresh whose query fails, or whose snapshot leaves out a display CoreGraphics has, records no
/// layout, so a later poll tries again, after 4, 8, 16, 32, then every 60 seconds (`pollsBeforeRetry`). Each
/// display's stream starts in its own task, so one slow or hung platform start holds up neither the other displays
/// nor hot-plug. A disconnected display's interval already ends at its last observed sample, so ending its stream
/// invents nothing.
@MainActor public final class MeetingScreenCapture {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "screen")
    /// Snapshots in a row that may leave out a display CoreGraphics reports before a capture that never started a
    /// stream gives up (about a minute of backoff).
    static let incompleteLimit = 5
    private let permissionCheck: @MainActor () -> Bool
    private let system: any ScreenCaptureSystem
    private let pollInterval: Duration
    private var target = ScreenCaptureTarget.display
    private var receiver: ScreenFrameReceiver?
    /// The first refresh; tests wait for it.
    private(set) var initial: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var roster = ScreenDisplayRoster()
    /// Every display's stream that is starting or running.
    private var streams: [CGDirectDisplayID: ScreenDisplayStream] = [:]
    /// The tasks finishing platform starts, and those stopping streams (tests wait for them).
    private var starts: [UUID: Task<Void, Never>] = [:]
    private var stops: [UUID: Task<Void, Never>] = [:]
    /// The layout the last complete refresh matched; nil until one succeeds.
    private var reconciled: ScreenDisplayLayout?
    /// Refreshes in a row that failed or came back incomplete, and polls to skip before the next try.
    private var failedRefreshes = 0
    private var pollsUntilRetry = 0
    /// The last snapshot left out a display CoreGraphics reports.
    private var incomplete = false
    private var refreshing = false
    private var refreshAgain = false
    /// A stream was ever started in this capture.
    private var everStarted = false
    private var stopped = false
    /// Stream errors handled (tests wait for them).
    private(set) var streamErrors = 0

    public convenience init(permissionCheck: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() }) {
        self.init(permissionCheck: permissionCheck, system: LiveScreenCaptureSystem(), pollInterval: .seconds(2))
    }

    init(permissionCheck: @escaping @MainActor () -> Bool, system: any ScreenCaptureSystem, pollInterval: Duration) {
        self.permissionCheck = permissionCheck; self.system = system; self.pollInterval = pollInterval
    }

    public func start(_ target: ScreenCaptureTarget, session: URL, origin: Double) {
        guard receiver == nil, !stopped else { return }
        self.target = target
        let receiver = ScreenFrameReceiver(session: session, origin: origin, onFailure: { [weak self] in
            Task { @MainActor in await self?.stop() }
        }, onDisplayCapped: { [weak self] id in
            Task { @MainActor in self?.capped(id) }
        })
        self.receiver = receiver
        guard permissionCheck() else { receiver.failed(); return }
        let interval = pollInterval
        let first = Task { [weak self] in
            let known = await receiver.knownDisplays()
            await self?.begin(known: known)
        }
        initial = first
        monitor = Task { [weak self] in
            await first.value
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let changed = self?.displaysChanged() else { return }
                if changed { await self?.refresh() }
            }
        }
    }

    /// The first refresh, numbering displays after those the meeting's saved keyframes already name.
    private func begin(known: [ScreenDisplay]) async {
        guard !stopped else { return }
        roster = ScreenDisplayRoster(known: known)
        await refresh()
    }

    /// Whether the layout differs from that of the last complete refresh (and a failed one's backoff has passed);
    /// the refresh then starts and stops streams.
    private func displaysChanged() -> Bool {
        guard system.layout() != reconciled else { return false }
        guard pollsUntilRetry == 0 else { pollsUntilRetry -= 1; return false }
        return true
    }

    /// Polls to wait after `failures` failed refreshes in a row: 1, 3, 7, 15, then 29 (a retry after 4, 8, 16, 32
    /// and 60 seconds at one poll every two seconds).
    nonisolated static func pollsBeforeRetry(failures: Int) -> Int {
        failures <= 0 ? 0 : min((1 << min(failures, 5)) - 1, 29)
    }

    /// Asks ScreenCaptureKit for the displays and starts and stops streams to match. One refresh at a time; a
    /// request during one runs once more after it.
    func refresh() async {
        guard !stopped, let receiver else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await reconcile(receiver)
        } while refreshAgain && !stopped
    }

    private func reconcile(_ receiver: ScreenFrameReceiver) async {
        // Read before the query: a change during it differs from what is recorded, and the next poll refreshes.
        let layout = system.layout()
        let snapshot: [ScreenDisplayCandidate]
        do { snapshot = try await system.displays() } catch {
            // Nothing captures any more (the permission was withdrawn, say): the capture fails as it always did.
            // While other streams run, the layout stays unrecorded and a later poll tries again, backing off.
            retryLater()
            if streams.isEmpty { receiver.failed() }
            return
        }
        // CoreGraphics is the truth for what is connected: a display the snapshot still lists after it was
        // unplugged is gone, so its stream ends (and a failed one may come back when it is plugged in again).
        let candidates = snapshot.filter(layout.isCapturable)
        incomplete = !layout.isCovered(by: candidates)
        if incomplete {
            // A display CoreGraphics reports is not in the snapshot yet: capture what is there, and look again.
            retryLater()
        } else {
            reconciled = layout
            failedRefreshes = 0
            pollsUntilRetry = 0
        }
        guard !stopped else { return }
        let change = roster.reconcile(ScreenCapturePlan.displays(candidates, for: target))
        for id in change.stop {
            receiver.end(id)
            if let stream = streams.removeValue(forKey: id) { requestStop(stream) }
            Self.log.info("Display \(id, privacy: .public) is gone; its screen capture ended")
        }
        for display in change.start {
            guard !stopped else { return }
            let token = UUID()
            receiver.begin(display, stream: token)
            let output = ScreenDisplayOutput(display: display, stream: token, receiver: receiver) { [weak self] in
                Task { @MainActor in await self?.streamStopped(display.id, token: token) }
            }
            let control: any ScreenStreamControl
            do { control = try system.stream(for: display, output: output) } catch {
                startFailed(display, receiver)
                continue
            }
            // Registered before the start is awaited, so a stop during a slow start stops this stream too.
            let stream = ScreenDisplayStream(display: display, token: token, control: control, output: output)
            streams[display.id] = stream
            everStarted = true
            starts[token] = Task { [weak self] in
                await self?.finishStart(stream, receiver)
                self?.starts[token] = nil
            }
        }
        failIfNothingCaptures(receiver)
    }

    /// One display's platform start, in its own task: a hung one holds up nothing else.
    private func finishStart(_ stream: ScreenDisplayStream, _ receiver: ScreenFrameReceiver) async {
        let id = stream.display.id
        do {
            try await stream.control.start()
        } catch {
            guard streams[id] === stream, stream.phase == .starting else { return }
            streams[id] = nil
            stream.phase = .stopped
            // As for a running stream's error: the display may have been unplugged while it started. A refresh
            // against the current layout tells that from a broken stream before anything decides nothing captures.
            roster.failed(id)
            receiver.end(id)
            Self.log.error("Display \(stream.display.number, privacy: .public) could not be captured")
            await refresh()
            return
        }
        // Stopped, disconnected or capped while starting: the stop came before the platform had a stream to stop,
        // so it is stopped again now.
        guard !stopped, streams[id] === stream, stream.phase == .starting else {
            await stream.control.stop()
            return
        }
        stream.phase = .running
        Self.log.info("Capturing display \(stream.display.number, privacy: .public) of the meeting")
    }

    private func startFailed(_ display: ScreenDisplay, _ receiver: ScreenFrameReceiver) {
        roster.failed(display.id)
        receiver.end(display.id)
        Self.log.error("Display \(display.number, privacy: .public) could not be captured")
        failIfNothingCaptures(receiver)
    }

    /// No display captures or is starting, and one is connected but failing, or none was ever there: the capture
    /// fails as one display's did. While snapshots still leave out a display CoreGraphics reports (displays being
    /// reconfigured), it waits, up to `incompleteLimit` refreshes. Every display gone after one was captured (a lid
    /// closed on the last one) waits for one to return.
    private func failIfNothingCaptures(_ receiver: ScreenFrameReceiver) {
        guard !stopped, roster.running.isEmpty else { return }
        let waitingForSnapshot = incomplete && failedRefreshes < Self.incompleteLimit
        if roster.anyFailed || (!everStarted && !waitingForSnapshot) { receiver.failed() }
    }

    /// A refresh that failed or came back incomplete: the layout stays unrecorded, and polls back off.
    private func retryLater() {
        reconciled = nil
        failedRefreshes += 1
        pollsUntilRetry = Self.pollsBeforeRetry(failures: failedRefreshes)
    }

    /// Asks the platform to stop a stream without waiting: one stalled stop never holds up another stream's, or a
    /// refresh. The task keeps the stream (and its output) alive until the stop returns.
    @discardableResult private func requestStop(_ stream: ScreenDisplayStream) -> Task<Void, Never> {
        stream.phase = .stopped
        let key = UUID()
        let task = Task { [weak self] in
            await stream.control.stop()
            self?.stops[key] = nil
        }
        stops[key] = task
        return task
    }

    /// Every pending platform start and stop has returned (tests).
    func settle() async {
        await initial?.value
        while let next = starts.values.first ?? stops.values.first { await next.value }
    }

    /// The current stream of a display stopped with an error (tests; the output reports it with its token).
    func streamStopped(_ id: CGDirectDisplayID) async {
        guard let token = streams[id]?.token else { return }
        await streamStopped(id, token: token)
    }

    /// A stream stopped with an error: a display being disconnected, or a broken stream. The refresh tells them
    /// apart. An older stream of the display (already replaced) is ignored.
    private func streamStopped(_ id: CGDirectDisplayID, token: UUID) async {
        streamErrors += 1
        guard !stopped, let stream = streams[id], stream.token == token else { return }
        // Also while its start is pending, which may never return: the stream is retired at once (a late return of
        // its start finds another stream, or none, under its display and is stopped again), and the refresh decides.
        streams[id] = nil
        requestStop(stream)
        roster.failed(id)
        receiver?.end(id)
        await refresh()
    }

    /// The shared caps stopped this display (the busiest); the others go on.
    func capped(_ id: CGDirectDisplayID) {
        guard !stopped else { return }
        roster.capped(id)
        if let stream = streams.removeValue(forKey: id) { requestStop(stream) }
        Self.log.info("Display \(id, privacy: .public) stopped for the shared screen storage limit")
    }

    /// The display IDs with a running stream (tests).
    var capturing: [CGDirectDisplayID] { streams.filter { $0.value.phase == .running }.keys.sorted() }

    public func stop() async {
        stopped = true
        initial?.cancel()
        monitor?.cancel()
        // Streams still starting too: a hung platform start must not keep the screen captured. The one whose start
        // returns later is stopped again then; closing the receiver fences any frame it delivers.
        let all = Array(streams.values)
        streams = [:]
        // Close the receiver first: even a hung/late platform start cannot persist another frame.
        await receiver?.close()
        // Every stop is asked for before any is waited for: one stalled stop never leaves another stream running.
        let requested = all.map { requestStop($0) }
        for stop in requested { await stop.value }
    }
}

/// ScreenCaptureKit itself: a display filter per display that leaves Voice is Local out, at most 0.5 fps.
@MainActor final class LiveScreenCaptureSystem: ScreenCaptureSystem {
    private var content: SCShareableContent?

    func layout() -> ScreenDisplayLayout {
        let main = CGMainDisplayID()
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .init(ids: [], main: main) }
        var ids = [CGDirectDisplayID](repeating: kCGNullDirectDisplay, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .init(ids: [], main: main) }
        // Sorted, so only a real change differs; the main display and mirroring are compared on their own.
        let active = ids.prefix(Int(count)).sorted()
        var mirroring: [CGDirectDisplayID: CGDirectDisplayID] = [:]
        for id in active {
            let mirrored = CGDisplayMirrorsDisplay(id)
            if mirrored != kCGNullDirectDisplay { mirroring[id] = mirrored }
        }
        return ScreenDisplayLayout(ids: active, main: main, mirroring: mirroring)
    }

    /// Displays that show another display's picture (hardware mirroring) are left out: their snapshots would repeat.
    func displays() async throws -> [ScreenDisplayCandidate] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        self.content = content
        let main = CGMainDisplayID()
        return content.displays.filter { CGDisplayMirrorsDisplay($0.displayID) == kCGNullDirectDisplay }
            .map { ScreenDisplayCandidate(id: $0.displayID, frame: $0.frame, isMain: $0.displayID == main) }
    }

    func stream(for display: ScreenDisplay, output: ScreenDisplayOutput) throws -> any ScreenStreamControl {
        guard let content, let screen = content.displays.first(where: { $0.displayID == display.id }) else {
            throw HolosError.unavailable("No display is available to capture.")
        }
        let own = ScreenCapturePlan.excluded(content.applications, bundleIdentifier: \.bundleIdentifier,
                                             processID: \.processID)
        let filter = SCContentFilter(display: screen, excludingApplications: own, exceptingWindows: [])
        let mode = CGDisplayCopyDisplayMode(screen.displayID)
        let size = ScreenCapturePlan.size(pixelWidth: mode?.pixelWidth ?? screen.width,
                                          pixelHeight: mode?.pixelHeight ?? screen.height)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 2, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        return LiveScreenStream(stream: stream, output: output)
    }
}

/// An `SCStream` and, until it is stopped, its output and delegate, which the stream itself holds only weakly.
@MainActor final class LiveScreenStream: ScreenStreamControl {
    private let stream: SCStream
    private var output: ScreenDisplayOutput?
    init(stream: SCStream, output: ScreenDisplayOutput) { self.stream = stream; self.output = output }
    func start() async throws { try await stream.startCapture() }
    func stop() async {
        try? await stream.stopCapture()
        output = nil
    }
}

/// JPEG snapshots within `ScreenContextStore`'s bounds.
enum ScreenFrameEncoding {
    /// Downscaled so neither side exceeds `maximumImageDimension`, then encoded at quality 0.65, 0.5, 0.35 until
    /// it fits `maximumImageBytes`; then at half the size again. A dense full-screen frame is made smaller rather
    /// than ending the capture. Anything still too large is returned and the caller's cap stops the capture.
    static func jpeg(_ image: CGImage) throws -> Data {
        var image = try downscaled(image, maximum: ScreenContextStore.maximumImageDimension)
        var data = Data()
        for attempt in 0..<2 {
            if attempt > 0 { image = try downscaled(image, maximum: max(image.width, image.height) / 2) }
            for quality in [0.65, 0.5, 0.35] {
                data = try encode(image, quality: quality)
                if data.count <= ScreenContextStore.maximumImageBytes { return data }
            }
        }
        return data
    }

    static func downscaled(_ image: CGImage, maximum: Int) throws -> CGImage {
        guard max(image.width, image.height) > maximum else { return image }
        let size = ScreenCapturePlan.size(pixelWidth: image.width, pixelHeight: image.height, maximum: maximum)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw HolosError.unavailable("A screen snapshot could not be scaled.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else { throw HolosError.unavailable("A screen snapshot could not be scaled.") }
        return scaled
    }

    private static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw HolosError.unavailable("A screen snapshot could not be encoded.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw HolosError.unavailable("A screen snapshot could not be encoded.")
        }
        return data as Data
    }
}

/// One display's stream output and delegate: hands its samples, tagged with the display, to the capture's receiver.
final class ScreenDisplayOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let display: ScreenDisplay
    /// The stream's token: its samples count only while it is the display's current stream.
    let stream: UUID
    let receiver: ScreenFrameReceiver
    private let onStop: @Sendable () -> Void
    var queue: DispatchQueue { receiver.queue }

    init(display: ScreenDisplay, stream: UUID, receiver: ScreenFrameReceiver,
         onStop: @escaping @Sendable () -> Void) {
        self.display = display; self.stream = stream; self.receiver = receiver; self.onStop = onStop
        super.init()
    }

    /// A disconnected display or a broken stream; only this display's stream has ended.
    func stream(_ stream: SCStream, didStopWithError error: any Error) { stopped() }
    func stopped() { onStop() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        receiver.receive(sampleBuffer, from: display, stream: self.stream)
    }
}

/// The writer of one capture generation, for every display: all image conversion, diffing, encoding and IO are on
/// this one serial utility queue, which every display's stream delivers to. Each display has its own retained frame
/// and pending change; the record, its keyframe and byte totals, and the generation fence are shared.
final class ScreenFrameReceiver: Sendable {
    let queue = DispatchQueue(label: "ca.orlenko.holos.screen", qos: .utility)
    private let session: URL
    private let origin: Double
    private let captureID = UUID().uuidString
    private let onFailure: @Sendable () -> Void
    private let onDisplayCapped: @Sendable (CGDirectDisplayID) -> Void
    private let encoder: @Sendable (CGImage) throws -> Data
    /// One context for every frame of every display; the software renderer keeps conversion off the GPU.
    private let images = CIContext(options: [.useSoftwareRenderer: true])
    /// The last sample seen. Its image is kept only while it is a change that has not settled yet.
    private struct Sample {
        var fingerprint: [UInt8]
        var time: Double
        var image: CGImage?
    }
    /// One display's keyframe state: independent of every other display's.
    private struct Screen {
        var display: ScreenDisplay
        /// The retained (last saved) frame's fingerprint.
        var fingerprint: [UInt8]?
        var previous: Sample?
        /// Keyframes and JPEG bytes this display saved in the meeting, for the shared caps.
        var keyframes = 0
        var bytes = 0
        /// Disconnected, or stopped by the shared caps: late samples are ignored.
        var ended = false
        /// Its stream has delivered a sample: it is capturing, not still starting (or hung starting), so it takes
        /// part in the shared caps' reservations.
        var delivering = false
        /// The token of the display's current stream. A sample of an older stream of the display (one whose stop
        /// has not finished when the display came back) is ignored, so it cannot touch the new stream's state.
        var stream: UUID?
    }
    private struct State {
        var stopped = false
        var record: ScreenContextRecord?
        var screens: [CGDirectDisplayID: Screen] = [:]
        var bytes = 0
    }
    private enum Step { case none, kept }
    private let state = Mutex(State())
    private let stopped = Mutex(false)
    init(session: URL, origin: Double, onFailure: @escaping @Sendable () -> Void = {},
         onDisplayCapped: @escaping @Sendable (CGDirectDisplayID) -> Void = { _ in },
         encoder: @escaping @Sendable (CGImage) throws -> Data = ScreenFrameEncoding.jpeg) {
        self.session = session; self.origin = origin; self.onFailure = onFailure
        self.onDisplayCapped = onDisplayCapped
        self.encoder = encoder
        queue.async {
            let initialized = self.state.withLock { value in
                do {
                    let id = try SessionArchive.readManifest(at: session).id
                    value.record = try ScreenContextStore.update(session: session, sessionID: id) {
                        $0.captureID = self.captureID; $0.ocrID = nil; $0.failure = nil
                    }
                    value.bytes = value.record?.imageBytes ?? 0
                    return true
                } catch { value.stopped = true; return false }
            }
            if !initialized { self.failed() }
        }
    }

    /// The displays the meeting's saved keyframes name, so a restarted capture keeps their numbers.
    func knownDisplays() async -> [ScreenDisplay] {
        await withCheckedContinuation { continuation in
            queue.async {
                let frames = self.state.withLock { $0.record?.frames ?? [] }
                var known: [UInt32: ScreenDisplay] = [:]
                for frame in frames { if let display = frame.display { known[display.id] = display } }
                continuation.resume(returning: known.values.sorted { $0.number < $1.number })
            }
        }
    }

    /// A display's stream is starting: a fresh retained frame, so its first sample is kept at once. A display that
    /// comes back keeps its keyframe and byte counts for the shared caps; only its sampling starts again.
    func begin(_ display: ScreenDisplay, stream: UUID? = nil) {
        queue.async {
            self.state.withLock { value in
                guard let known = value.screens[display.id] else {
                    value.screens[display.id] = Self.screen(display, value, stream: stream)
                    return
                }
                value.screens[display.id] = Screen(display: display, keyframes: known.keyframes, bytes: known.bytes,
                                                   stream: stream)
            }
        }
    }

    /// Whether a sample of `stream` belongs to the display's current stream (or is the display's first).
    private static func current(_ value: State, _ id: CGDirectDisplayID, _ stream: UUID?) -> Bool {
        value.screens[id].map { $0.stream == stream } ?? true
    }

    /// A display's stream ended: a change of it that never settled is dropped, and its last keyframe's interval
    /// stays at its last observed sample.
    func end(_ id: CGDirectDisplayID) {
        queue.async {
            self.state.withLock { value in
                value.screens[id]?.ended = true
                value.screens[id]?.previous = nil
            }
        }
    }

    /// A display first seen by this capture generation, with what the meeting's saved keyframes say it used: each
    /// keyframe's own JPEG size, or, for one saved without it, the meeting's average.
    private static func screen(_ display: ScreenDisplay, _ value: State, stream: UUID? = nil) -> Screen {
        let frames = value.record?.frames ?? []
        let own = frames.filter { $0.display?.id == display.id }
        let average = frames.isEmpty ? 0 : (value.record?.imageBytes ?? 0) / frames.count
        return Screen(display: display, keyframes: own.count, bytes: own.reduce(0) { $0 + ($1.bytes ?? average) },
                      stream: stream)
    }

    func failed() {
        let wasStopped = stopped.withLock { value in let old = value; value = true; return old }
        guard !wasStopped else { return }
        queue.async { self.seal(failure: "captureFailed"); self.onFailure() }
    }

    func close() async {
        stopped.withLock { $0 = true }
        await withCheckedContinuation { continuation in
            queue.async {
                self.seal(failure: nil)
                continuation.resume()
            }
        }
    }

    private func seal(failure: String?) {
        state.withLock { value in
            for id in value.screens.keys { value.screens[id]?.previous = nil }
            guard let record = value.record else { return }
            // The final frame is known only through its last sample, not all the way to stop: locking the screen
            // or an idle stream must not invent screen evidence in a later gap. A change that never settled is
            // dropped.
            value.record = try? ScreenContextStore.update(session: session, sessionID: record.sessionID) {
                guard $0.captureID == self.captureID else { return }
                if let failure { $0.failure = failure }
                $0.captureID = nil
            }
        }
    }

    /// Called on `queue` by a display's stream.
    func receive(_ sampleBuffer: CMSampleBuffer, from display: ScreenDisplay, stream: UUID) {
        // An older stream's sample is not even converted.
        guard state.withLock({ Self.current($0, display.id, stream) }), sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return }
        let stamp = sampleBuffer.presentationTimeStamp.seconds
        guard stamp.isFinite else { return }
        let time = max(0, stamp - origin)
        var image: CGImage?
        if raw == SCFrameStatus.complete.rawValue, let buffer = sampleBuffer.imageBuffer {
            // A rendered copy: the stream's buffer is returned to its pool while a change waits to settle.
            let input = CIImage(cvPixelBuffer: buffer)
            image = images.createCGImage(input, from: input.extent)
        }
        receive(image, at: time, status: raw, from: display, stream: stream)
    }

    /// Called on `queue`, also by synthetic-frame tests. No screen/device lookup occurs here.
    func receive(_ image: CGImage?, at time: Double, status raw: Int, from display: ScreenDisplay,
                 stream: UUID? = nil) {
        if raw != SCFrameStatus.complete.rawValue && raw != SCFrameStatus.idle.rawValue {
            state.withLock { value in
                guard Self.current(value, display.id, stream) else { return }
                value.screens[display.id]?.fingerprint = nil; value.screens[display.id]?.previous = nil
            }
            return
        }
        guard time.isFinite, time >= 0, !stopped.withLock({ $0 }) else { return }
        state.withLock { value in
            guard !value.stopped, Self.current(value, display.id, stream) else { return }
            var screen = value.screens[display.id] ?? Self.screen(display, value, stream: stream)
            guard !screen.ended else { return }
            screen.delivering = true
            let step: Step
            do {
                step = try keep(image, at: time, status: raw, screen: &screen, &value)
            } catch {
                value.stopped = true
                for id in value.screens.keys { value.screens[id]?.previous = nil }
                if var record = value.record { record.failure = "storageFailed"; try? publish(record) }
                onFailure()
                return
            }
            guard !value.stopped else { value.screens[display.id] = screen; return }
            value.screens[display.id] = screen
            guard step == .kept, let record = value.record else { return }
            // The shared caps: past the share held back for quieter displays, the busiest one stops.
            let running = value.screens.values.filter { !$0.ended && $0.delivering }
                .map { ScreenStoragePolicy.Usage(display: $0.display, keyframes: $0.keyframes, bytes: $0.bytes) }
            for id in ScreenStoragePolicy.displaysToStop(running, frames: record.frames.count, bytes: value.bytes) {
                value.screens[id]?.ended = true
                value.screens[id]?.previous = nil
                onDisplayCapped(id)
            }
        }
    }

    /// One display's sample against its own retained frame; a kept keyframe joins the shared timeline.
    private func keep(_ image: CGImage?, at time: Double, status raw: Int, screen: inout Screen,
                      _ value: inout State) throws -> Step {
        if value.record == nil {
            let id = try SessionArchive.readManifest(at: session).id
            value.record = try ScreenContextStore.update(session: session, sessionID: id) {
                $0.captureID = self.captureID; $0.ocrID = nil
            }
        }
        guard var record = value.record else { return .none }
        let display = screen.display
        // This display's latest keyframe: only its own samples extend it.
        let last = record.frames.lastIndex { $0.display?.id == display.id }
        // The sample that becomes a new keyframe, and when its content was first seen.
        let kept: (image: CGImage, fingerprint: [UInt8], start: Double)
        if raw == SCFrameStatus.idle.rawValue {
            // Nothing changed on screen since the previous sample: a change waiting to settle has settled.
            guard screen.fingerprint != nil else { return .none }
            if let previous = screen.previous, let image = previous.image {
                kept = (image, previous.fingerprint, previous.time)
            } else {
                guard let last else { return .none }
                record.frames[last].end = max(record.frames[last].end, time)
                value.record = record
                try publish(record)
                return .none
            }
        } else {
            guard let image, let fingerprint = ScreenFrameDifference.fingerprint(image) else { return .none }
            let previous = screen.previous
            if ScreenFrameDifference.settledChange(fingerprint, retained: screen.fingerprint,
                                                   previousSample: previous?.fingerprint) {
                // From the previous sample only when it showed this very picture; a picture that settled
                // in part but still differs elsewhere (a slide build's next bullet) is new at this sample.
                let shownBefore = screen.fingerprint != nil
                    && previous.map { ScreenFrameDifference.unchanged(fingerprint, comparedWith: $0.fingerprint) } == true
                kept = (image, fingerprint, shownBefore ? previous?.time ?? time : time)
            } else if ScreenFrameDifference.meaningful(fingerprint, comparedWith: screen.fingerprint) {
                // A slide that just changed, a scroll, or a moving video: wait for the next sample.
                screen.previous = Sample(fingerprint: fingerprint, time: time, image: image)
                return .none
            } else if previous?.image != nil {
                // Back to the retained picture after a change that never settled: the retained frame's
                // interval ended at its last matching sample, so this is a new interval, with its own
                // snapshot, rather than one that claims the change was never on screen.
                kept = (image, fingerprint, time)
            } else {
                screen.previous = Sample(fingerprint: fingerprint, time: time, image: nil)
                guard let last else { return .none }
                record.frames[last].end = max(record.frames[last].end, time)
                value.record = record
                try publish(record)
                return .none
            }
        }
        guard !ScreenStoragePolicy.full(frames: record.frames.count, bytes: value.bytes) else {
            try stopForStorage(&record, &value, &screen)
            return .none
        }
        let data = try encoder(kept.image)
        guard data.count <= ScreenContextStore.maximumImageBytes,
              value.bytes + data.count <= ScreenContextStore.maximumTotalImageBytes else {
            try stopForStorage(&record, &value, &screen)
            return .none
        }
        let start = max(kept.start, last.map { record.frames[$0].end } ?? 0)
        let frame = ScreenKeyframe(start: start, end: max(time, start), display: display, bytes: data.count)
        guard !stopped.withLock({ $0 }) else { return .none }
        record.frames.insert(frame, at: record.insertionIndex(start: start))
        value.bytes += data.count
        record.imageBytes = value.bytes
        screen.keyframes += 1
        screen.bytes += data.count
        screen.fingerprint = kept.fingerprint
        screen.previous = Sample(fingerprint: kept.fingerprint, time: time, image: nil)
        value.record = record
        try publish(record, newImage: (frame.id, data))
        return .kept
    }

    /// The meeting reached a cap: every display stops, and the record says why.
    private func stopForStorage(_ record: inout ScreenContextRecord, _ value: inout State,
                                _ screen: inout Screen) throws {
        record.failure = "storageLimit"; value.stopped = true
        screen.previous = nil
        for id in value.screens.keys { value.screens[id]?.previous = nil }
        value.record = record
        try publish(record)
        onFailure()
    }

    private func publish(_ record: ScreenContextRecord, newImage: (id: String, data: Data)? = nil) throws {
        try ScreenContextStore.update(session: session, sessionID: record.sessionID) { current in
            guard current.captureID == captureID else {
                throw HolosError.unavailable("This screen capture generation ended.")
            }
            if let newImage {
                try AtomicFile.ensurePrivateDirectory(ScreenContextStore.directory(session))
                try AtomicFile.create(newImage.data, at: ScreenContextStore.image(newImage.id, session: session))
            }
            current = record
        }
    }
}
