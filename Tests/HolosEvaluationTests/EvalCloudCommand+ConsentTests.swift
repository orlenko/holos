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

/// Answers every request with `status` (a transcript for 200) and counts them.
final class EvalCommandTransport: CloudHTTPTransport {
    let status: Int
    let requests = Mutex(0)

    init(status: Int = 200) { self.status = status }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0 += 1 }
        let body = status == 200
            ? #"{"text":"Hello team, we deploy on Kubernetes today.","usage":{"type":"duration","seconds":5}}"#
            : #"{"error":{"message":"The audio is not usable."}}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: [:])!)
    }

    var count: Int { requests.withLock { $0 } }
}

/// Stops the `stopAt`-th step it runs (from 1) with `CancellationError`, as Ctrl-C does; runs the others.
struct EvalCommandStopping: EvalInterruption {
    let stopAt: Int
    let calls = SharedValue(0)

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let call = calls.update { count -> Int in
            count += 1
            return count
        }
        if call == stopAt { throw CancellationError() }
        return try await operation()
    }
}

/// Collects what a command reports.
final class EvalCommandMessages: Sendable {
    let messages = SharedValue<[EvalCommandMessage]>([])
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
    FileManager.default.fileExists(atPath: session.appendingPathComponent("derived/eval-cloud").path)
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

@Test func evalCloudStoppedDuringTheUploadSaysSoAndKeepsTheRun() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let transport = EvalCommandTransport()
    let collected = EvalCommandMessages()
    let outcome = try await EvalCloudCommand.run(
        evalCommandCloudRequest(session, transport: transport), interruption: EvalCommandStopping(stopAt: 2),
        consent: { .proceed }, report: collected.report)
    #expect(outcome == .cancelled)
    #expect(transport.count == 0)
    guard case .note(let said)? = collected.all.last else {
        Issue.record("Expected a note, got \(collected.all)")
        return
    }
    #expect(said.hasPrefix("Cancelled. 0 of 3 segments are saved; run the same command again to resume run "
        + "gpt-transcribe-"))
}

@Test func evalCloudStoppedWhilePreparingAsksNothingAndLeavesNoWork() async throws {
    let temp = try TemporaryDirectory("eval-command")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let transport = EvalCommandTransport()
    let asked = SharedValue(false)
    await #expect(throws: CancellationError.self) {
        _ = try await EvalCloudCommand.run(
            evalCommandCloudRequest(session, transport: transport), interruption: EvalCommandStopping(stopAt: 1),
            consent: {
                asked.set(true)
                return .proceed
            }, report: EvalCommandMessages().report)
    }
    #expect(!asked.value)
    #expect(transport.count == 0)
    #expect(!evalCommandWorkExists(session))
}
