import Foundation
import HolosAudio
import HolosCore
import HolosDictation
import HolosMeeting
import HolosStorage
import os

/// One private capture and one local helper per press.
///
/// Invariants:
/// 1. Only microphone frames accepted before retirement reach the writer.
/// 2. Finalizing the audio and writing settings precede launch. Cleanup follows them on the same queue.
/// 3. Every terminal path retires the worker once. Quit waits a bounded time for pending removals.
@MainActor
final class AccurateDictationWorker: AfterReleaseSpeech {
    private static let folderPrefix = "holos-dictation-"
    private static let files = DispatchQueue(label: "ca.orlenko.holos.accurate-dictation")
    nonisolated let modelName: String
    let folder: URL
    private let writer: DictationAudioWriter
    private let request: AccurateDictationCommand.Request
    private let runner: CommandRunner
    private var retired = false
    private var expectedStart: Double?
    private var capturedSeconds = 0.0

    init(model: AccurateDictationModel, locale: String, vocabulary: [String],
         temporaryRoot: URL = FileManager.default.temporaryDirectory,
         launcher: MaintenanceLauncher = MaintenanceLauncher(executable: ChildProcessLauncher.bundledExecutable)) {
        modelName = model.title
        request = .init(model: model, locale: locale, vocabulary: vocabulary)
        folder = temporaryRoot.appendingPathComponent("\(Self.folderPrefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        writer = DictationAudioWriter(store: DictationHistoryStore(directory: folder), id: UUID())
        runner = CommandRunner(launcher: launcher, callerOwnedFolder: folder)
    }

    func append(_ frame: PCMFrame) async throws {
        guard !retired else { throw CancellationError() }
        guard case .contiguous = FrameContinuity.classify(frameStart: frame.startTime, frameCount: frame.frameCount,
                                                          sampleRate: frame.sampleRate, expected: expectedStart) else {
            throw HolosError.incomplete("Microphone audio was interrupted. Please dictate again.")
        }
        try await writer.appendForRecognition(frame)
        expectedStart = frame.startTime + frame.duration
        capturedSeconds += frame.duration
    }

    func finish() async throws -> [TranscriptSegment] {
        guard !retired else { throw CancellationError() }
        let settings = folder.appendingPathComponent("request.json")
        let audio: URL = try await withCheckedThrowingContinuation { continuation in
            Self.files.async { [writer, request, capturedSeconds] in
                continuation.resume(with: Result {
                    guard let audio = writer.finish() else {
                        throw HolosError.incomplete("No complete microphone audio was available. Try dictating again.")
                    }
                    // AAC packet padding can cover one 1024-sample packet at either end.
                    let seconds = try DictationAudioFile.seconds(of: audio.partial)
                    guard abs(seconds - capturedSeconds) <= 2 * 1024 / HistoryAudio.sampleRate else {
                        throw HolosError.incomplete("The dictation recording was incomplete. Please dictate again.")
                    }
                    try AtomicFile.create(HolosJSON.encoder().encode(request), at: settings)
                    return audio.partial
                })
            }
        }
        try Task.checkCancellation()
        guard !retired else { throw CancellationError() }
        let result = try await runner.run(["accurate-dictation", audio.path, "--request", settings.path],
            output: "json", errors: nil, maxOutputBytes: 8 << 20, as: AccurateDictationCommand.Outcome.self)
        try Task.checkCancellation()
        guard !retired else { throw CancellationError() }
        guard result.code == 0 else {
            throw HolosError.incomplete(AccurateDictationCommand.Failure.message(code: result.code, model: request.model))
        }
        guard let outcome = result.outcome else {
            throw HolosError.incomplete("The recognition helper returned an unreadable or oversized result.")
        }
        return [.init(start: 0, end: 0, text: outcome.text)]
    }

    func discard() {
        guard !retired else { return }
        retired = true
        Self.files.async { [writer, folder] in
            writer.discard()
            do {
                try AtomicFile.removeTree([folder.lastPathComponent], in: folder.deletingLastPathComponent())
            } catch {
                Logger(subsystem: "ca.orlenko.holos.app", category: "dictation")
                    .error("Could not remove accurate dictation temporary folder \(folder.lastPathComponent, privacy: .public)")
            }
        }
    }

    /// Recover an interrupted cleanup after a crash or a bounded quit. Other running instances keep their audio.
    static func removeAbandonedCaptures(in root: URL = FileManager.default.temporaryDirectory) {
        let prefix = folderPrefix
        files.async {
            do {
                for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where name.hasPrefix(prefix) {
                    let parts = name.dropFirst(prefix.count).split(separator: "-", maxSplits: 1)
                    guard parts.count == 2, UUID(uuidString: String(parts[1])) != nil,
                          let pid = pid_t(parts[0]), pid > 0, kill(pid, 0) == -1, errno == ESRCH else { continue }
                    var info = stat()
                    guard lstat(root.appendingPathComponent(name).path, &info) == 0,
                          info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { continue }
                    try AtomicFile.removeTree([name], in: root)
                }
            } catch {
                Logger(subsystem: "ca.orlenko.holos.app", category: "dictation")
                    .error("Could not finish removing abandoned accurate dictation audio")
            }
        }
    }

    /// At quit the optional History writer can have queued frames as well. Drain both recordings off the main actor.
    static func discardHistoryAudioAtQuit(_ historyAudio: DictationAudioWriter?) {
        if let historyAudio { files.async { historyAudio.discard() } }
    }

    static func finishCleanupAtQuit() {
        let done = DispatchSemaphore(value: 0)
        files.async { done.signal() }
        if done.wait(timeout: .now() + 5) == .timedOut {
            Logger(subsystem: "ca.orlenko.holos.app", category: "dictation")
                .error("Quit before accurate dictation temporary files could be removed")
        }
    }
}
