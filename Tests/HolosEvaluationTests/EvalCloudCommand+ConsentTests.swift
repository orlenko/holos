import Foundation
import Synchronization
import Testing
import HolosCore
import HolosStorage
@testable import HolosEvaluation
import HolosTestSupport

// EvalCloudCommand (what `voiceislocal eval cloud` does): the lease, the consent question, the upload, and what it
// says, in order, with a fake HTTP transport: nothing here reaches the network. Helpers are prefixed `evalCommand`;
// EvalReviewCommands+FlowsTests.swift uses them too.

/// A fake OpenAI endpoint: answers every request with `status` (a transcript for 200, an error body otherwise).
///
/// Invariants:
/// 1. `count` is the number of `send` calls so far; each is counted before it is answered.
/// 2. `onRequest` runs with the request's 0-based number before the answer; what it throws, `send` throws, so a
///    test can stop the upload in the middle of a request.
/// 3. Nothing leaves the process.
final class EvalCommandTransport: CloudHTTPTransport {
    let status: Int
    let onRequest: (@Sendable (Int) throws -> Void)?
    private let requests = Mutex(0)

    init(status: Int = 200, onRequest: (@Sendable (Int) throws -> Void)? = nil) {
        self.status = status; self.onRequest = onRequest
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.withLock { count -> Int in
            count += 1
            return count - 1
        }
        try onRequest?(index)
        let body = status == 200
            ? #"{"text":"Hello team, we deploy on Kubernetes today.","usage":{"type":"duration","seconds":5}}"#
            : #"{"error":{"message":"The audio is not usable."}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: [:])!)
    }

    var count: Int { requests.withLock { $0 } }
}

/// Stops an eval command's steps as Ctrl-C does through the CLI's `EvalInterrupt`: each step runs in its own task.
///
/// Invariants:
/// 1. `calls` counts the steps it was asked to run, from 1, in order.
/// 2. `stop()` cancels the task of the step running at that moment; with no step running it does nothing, and a
///    step started later is not affected.
/// 3. The step numbered `stopAfter` runs to its end, `afterStep` sees it end, and then it ends with
///    `CancellationError`, its value dropped (a step that returned after a signal is never followed by the next).
final class EvalCommandStopping: EvalInterruption {
    let stopAfter: Int?
    let afterStep: (@Sendable (Int) -> Void)?
    let calls = SharedValue(0)
    private let cancelCurrent = Mutex<(@Sendable () -> Void)?>(nil)

    init(stopAfter: Int? = nil, afterStep: (@Sendable (Int) -> Void)? = nil) {
        self.stopAfter = stopAfter; self.afterStep = afterStep
    }

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let call = calls.update { count -> Int in
            count += 1
            return count
        }
        let task = Task { try await operation() }
        cancelCurrent.withLock { $0 = { task.cancel() } }
        defer { cancelCurrent.withLock { $0 = nil } }
        let value = try await task.value
        afterStep?(call)
        if call == stopAfter { throw CancellationError() }
        return value
    }

    func stop() {
        cancelCurrent.withLock { $0 }?()
    }
}

/// Collects what a command reports.
///
/// Invariants:
/// 1. `all` holds every message reported so far, each once, in the order `report` was called (one lock).
final class EvalCommandMessages: Sendable {
    private let messages = SharedValue<[EvalCommandMessage]>([])
    var all: [EvalCommandMessage] { messages.value }
    var report: @Sendable (EvalCommandMessage) -> Void { { message in self.messages.update { $0.append(message) } } }
}

let evalCommandNoVocabulary = CloudEvaluation.VocabularySource(wordList: { [] }, names: { [] }, terms: { _ in [] })

/// A cloud run request for `session` with 5-second segments, sent through `transport`.
func evalCommandCloudRequest(_ session: URL, transport: EvalCommandTransport) -> EvalCloudCommand.Request {
    var settings = CloudSegmentation.Settings()
    settings.maxSeconds = 5
    settings.searchSeconds = 1
    return EvalCloudCommand.Request(
        session: session, sessionArgument: "the-session",
        options: CloudEvaluation.Options(model: "gpt-transcribe", segmentation: settings),
        vocabulary: evalCommandNoVocabulary,
        client: CloudTranscriptionClient(apiKey: "sk-test-command-key", transport: transport, sleep: { _ in }))
}

private func evalCommandWorkExists(_ session: URL) -> Bool {
    FileManager.default.fileExists(atPath: EvalPaths.workRoot(session).path)
}

private let evalCommandLeavesNote = EvalCommandMessage.note(
    "The audio leaves this Mac: go ahead only if everyone recorded agreed to that.")

@Test func evalCloudAsksAfterSayingWhatLeavesTheMacThenUploads() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let transport = EvalCommandTransport()
    let collected = EvalCommandMessages()
    let askedAfter = SharedValue<[EvalCommandMessage]?>(nil)
    let outcome = try await EvalCloudCommand.run(
        evalCommandCloudRequest(session, transport: transport), interruption: EvalUninterrupted(),
        consent: {
            askedAfter.set(collected.all)
            #expect(transport.count == 0, "Nothing is sent before the answer.")
            return .proceed
        }, report: collected.report)
    #expect(outcome == .uploaded(count: 3))
    #expect(transport.count == 3)
    let asked = try #require(askedAfter.value)
    #expect(asked.last == evalCommandLeavesNote)
    #expect(asked.contains(.note("Model: gpt-transcribe")))
    let id = try #require(EvalStore.runIDs(in: session).first)
    #expect(Array(collected.all.suffix(2)) == [
        .note("Uploaded 3 segments. Next: voiceislocal eval compare the-session"),
        .output(EvalPaths.cloudRun(id, in: session).path),
    ])
    #expect(try EvalStore.resolveRun(nil, in: session).id == id)
}

@Test func evalCloudDeclinedOrWithoutATerminalUploadsNothing() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let cases: [(ConsentGate.Decision, EvalCloudCommand.Outcome, String)] = [
        (.declined, .declined, "Nothing was uploaded."),
        (.noTerminal, .noTerminal,
         "Nothing was uploaded: there is no terminal to confirm at. Pass --yes to upload without asking."),
    ]
    for (answer, expected, said) in cases {
        let transport = EvalCommandTransport()
        let collected = EvalCommandMessages()
        let outcome = try await EvalCloudCommand.run(
            evalCommandCloudRequest(session, transport: transport), interruption: EvalUninterrupted(),
            consent: { answer }, report: collected.report)
        #expect(outcome == expected)
        #expect(transport.count == 0)
        #expect(collected.all.last == .note(said))
        #expect(collected.all.dropLast().last == evalCommandLeavesNote)
        #expect(!evalCommandWorkExists(session), "The prepared renders are discarded.")
        #expect(EvalStore.runIDs(in: session).isEmpty)
    }
}

@Test func evalCloudIsRefusedWhileAnotherProcessHoldsTheSession() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let transport = EvalCommandTransport()
    let collected = EvalCommandMessages()
    let asked = SharedValue(false)
    await #expect(throws: (any Error).self) {
        _ = try await EvalCloudCommand.run(
            evalCommandCloudRequest(session, transport: transport), interruption: EvalUninterrupted(),
            consent: {
                asked.set(true)
                return .proceed
            }, report: collected.report)
    }
    #expect(!asked.value)
    #expect(transport.count == 0)
    #expect(collected.all.isEmpty)
}

@Test func evalCloudSaysWhatIsSavedWhenTheUploadFails() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let transport = EvalCommandTransport(status: 400)
    let collected = EvalCommandMessages()
    let outcome = try await EvalCloudCommand.run(
        evalCommandCloudRequest(session, transport: transport), interruption: EvalUninterrupted(),
        consent: { .proceed }, report: collected.report)
    #expect(outcome == .failed)
    #expect(transport.count == 1)
    let id = try #require(EvalStore.runIDs(in: session).first)
    guard case .note(let said)? = collected.all.last else {
        Issue.record("Expected a note, got \(collected.all)")
        return
    }
    #expect(said.contains("The audio is not usable."))
    #expect(said.hasSuffix(" 0 of 3 segments are saved; run the same command again to resume run \(id)."))
    #expect(!said.contains("sk-test-command-key"))
    #expect(!evalCommandWorkExists(session))
}

@Test func evalCloudStoppedDuringTheUploadKeepsWhatIsSavedAndResumes() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let stopping = EvalCommandStopping()
    // Ctrl-C while the second segment is being sent: the first one's answer is saved by then.
    let transport = EvalCommandTransport(onRequest: { index in
        guard index == 1 else { return }
        stopping.stop()
        try Task.checkCancellation()
    })
    let collected = EvalCommandMessages()
    let outcome = try await EvalCloudCommand.run(
        evalCommandCloudRequest(session, transport: transport), interruption: stopping,
        consent: { .proceed }, report: collected.report)
    #expect(outcome == .cancelled)
    #expect(transport.count == 2, "Nothing is sent after the stop.")
    let id = try #require(EvalStore.runIDs(in: session).first)
    #expect(collected.all.last == .note("Cancelled. 1 of 3 segments are saved; run the same command again to resume "
        + "run \(id)."))
    #expect(SessionFixtures.exists(EvalPaths.segmentResult(id, track: "mic", index: 0, in: session)))
    #expect(!SessionFixtures.exists(EvalPaths.segmentResult(id, track: "mic", index: 1, in: session)))
    #expect(try EvalStore.runRecord(id, in: session)?.completedAt == nil)
    #expect(!evalCommandWorkExists(session), "The renders go; the saved answers stay.")

    // The same command resumes the run and sends only what is left.
    let resuming = EvalCommandTransport()
    let again = EvalCommandMessages()
    let resumed = try await EvalCloudCommand.run(
        evalCommandCloudRequest(session, transport: resuming), interruption: EvalUninterrupted(),
        consent: { .proceed }, report: again.report)
    #expect(again.all.contains(.note("Resuming run \(id)")))
    #expect(resumed == .uploaded(count: 2))
    #expect(resuming.count == 2)
    #expect(try EvalStore.resolveRun(nil, in: session).id == id)
}

@Test func evalCloudStoppedAfterPreparingAsksNothingAndRemovesTheRenders() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let transport = EvalCommandTransport()
    let asked = SharedValue(false)
    let rendered = SharedValue(false)
    // The signal comes as the preparation ends: its renders exist, and the command must remove them.
    let stopping = EvalCommandStopping(stopAfter: 1, afterStep: { _ in
        rendered.set(FileManager.default.fileExists(atPath: EvalPaths.workRoot(session).path))
    })
    await #expect(throws: CancellationError.self) {
        _ = try await EvalCloudCommand.run(
            evalCommandCloudRequest(session, transport: transport), interruption: stopping,
            consent: {
                asked.set(true)
                return .proceed
            }, report: EvalCommandMessages().report)
    }
    #expect(rendered.value)
    #expect(!asked.value)
    #expect(transport.count == 0)
    #expect(!evalCommandWorkExists(session))
    #expect(EvalStore.runIDs(in: session).isEmpty)
}
