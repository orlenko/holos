import Foundation
import Synchronization
import Testing
import HolosCore
import HolosStorage
@testable import HolosMeeting

// `voiceislocal eval` against real session folders, with the HTTP layer faked: nothing here reaches the network.

/// Answers each request with `reply(callIndex, request)` and records the requests.
private final class EvalFakeTransport: CloudHTTPTransport {
    struct Reply: Sendable {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    let requests = Mutex<[URLRequest]>([])
    let reply: @Sendable (Int, URLRequest) -> Reply

    init(reply: @escaping @Sendable (Int, URLRequest) -> Reply) { self.reply = reply }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.withLock { list in
            list.append(request)
            return list.count - 1
        }
        let answer = reply(index, request)
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                       headerFields: answer.headers)!
        return (Data(answer.body.utf8), response)
    }

    var count: Int { requests.withLock { $0.count } }
}

private final class EvalSleeps: Sendable {
    let waits = Mutex<[Duration]>([])
    var sleep: @Sendable (Duration) async throws -> Void {
        { duration in self.waits.withLock { $0.append(duration) } }
    }
}

private func evalOK(_ text: String) -> EvalFakeTransport.Reply {
    .init(status: 200, body: #"{"text":"\#(text)","languages":[{"code":"en"}],"usage":{"type":"duration","seconds":5}}"#)
}

private let evalKey = "sk-test-secret-key-1234"

private func bodyText(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
}

// MARK: - HTTP layer

@Test func evalRequestIsAMultipartUploadWithTheKeyOnlyInTheHeader() async throws {
    let transport = EvalFakeTransport { _, _ in evalOK("hello") }
    let client = CloudTranscriptionClient(apiKey: evalKey, transport: transport, sleep: EvalSleeps().sleep)
    let fields = CloudRequestFields(model: "gpt-transcribe", languages: ["en", "fr"], prompt: "A meeting.",
                                    keywords: ["Kubernetes"])
    let answer = try await client.transcribe(fields: fields, audio: Data([1, 2, 3]), fileName: "mic-000.m4a")
    #expect(answer.result == CloudTranscriptionResult(text: "hello", languages: ["en"], usageSeconds: 5))
    #expect(answer.attempts == 1)
    let request = try #require(transport.requests.withLock { $0.first })
    #expect(request.url == CloudTranscriptionClient.endpoint)
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(evalKey)")
    let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
    #expect(contentType.hasPrefix("multipart/form-data; boundary="))
    let body = bodyText(request)
    #expect(body.contains("name=\"model\"\r\n\r\ngpt-transcribe\r\n"))
    #expect(body.contains("name=\"response_format\"\r\n\r\njson\r\n"))
    #expect(body.components(separatedBy: "name=\"languages[]\"").count == 3)
    #expect(body.contains("name=\"keywords[]\"\r\n\r\nKubernetes\r\n"))
    #expect(body.contains("name=\"prompt\"\r\n\r\nA meeting.\r\n"))
    #expect(body.contains("name=\"file\"; filename=\"mic-000.m4a\"\r\nContent-Type: audio/mp4"))
    #expect(!body.contains(evalKey))
}

@Test func evalRetriesRateLimitsAndServerErrorsWithBackoff() async throws {
    let transport = EvalFakeTransport { index, _ in
        switch index {
        case 0: .init(status: 429, body: #"{"error":{"message":"slow down","code":"rate_limit_exceeded"}}"#,
                      headers: ["Retry-After": "7"])
        case 1: .init(status: 503, body: "")
        default: evalOK("done")
        }
    }
    let sleeps = EvalSleeps()
    let retries = Mutex<[String]>([])
    let client = CloudTranscriptionClient(apiKey: evalKey, transport: transport, sleep: sleeps.sleep)
    let answer = try await client.transcribe(fields: CloudRequestFields(model: "gpt-transcribe"), audio: Data([0]),
                                             fileName: "a.m4a") { _, _, reason in retries.withLock { $0.append(reason) } }
    #expect(answer.attempts == 3)
    #expect(transport.count == 3)
    #expect(sleeps.waits.withLock { $0 } == [.seconds(7), .seconds(4)])
    #expect(retries.withLock { $0 }.first?.contains("slow down") == true)
}

@Test func evalDoesNotRetryRefusalsAndGivesUpAfterTheLastAttempt() async throws {
    for (status, body) in [(400, #"{"error":{"message":"bad audio"}}"#),
                           (401, #"{"error":{"message":"Incorrect API key provided: sk-test***1234"}}"#),
                           (429, #"{"error":{"message":"quota","code":"insufficient_quota"}}"#)] {
        let transport = EvalFakeTransport { _, _ in .init(status: status, body: body) }
        let client = CloudTranscriptionClient(apiKey: evalKey, transport: transport, sleep: EvalSleeps().sleep)
        let error = await #expect(throws: CloudTranscriptionError.self) {
            _ = try await client.transcribe(fields: CloudRequestFields(model: "gpt-transcribe"), audio: Data([0]),
                                            fileName: "a.m4a")
        }
        #expect(transport.count == 1)
        #expect(error?.status == status)
        #expect(error?.message.contains("sk-test") == false)
    }
    let transport = EvalFakeTransport { _, _ in .init(status: 502, body: "") }
    let sleeps = EvalSleeps()
    let client = CloudTranscriptionClient(apiKey: evalKey, transport: transport, sleep: sleeps.sleep)
    await #expect(throws: CloudTranscriptionError.self) {
        _ = try await client.transcribe(fields: CloudRequestFields(model: "gpt-transcribe"), audio: Data([0]),
                                        fileName: "a.m4a")
    }
    #expect(transport.count == CloudTranscriptionClient.maxAttempts)
    #expect(sleeps.waits.withLock { $0.count } == CloudTranscriptionClient.maxAttempts - 1)
}

@Test func evalCancellationDuringABackoffStops() async throws {
    let transport = EvalFakeTransport { _, _ in .init(status: 500, body: "") }
    let client = CloudTranscriptionClient(apiKey: evalKey, transport: transport, sleep: { _ in throw CancellationError() })
    await #expect(throws: CancellationError.self) {
        _ = try await client.transcribe(fields: CloudRequestFields(model: "gpt-transcribe"), audio: Data([0]),
                                        fileName: "a.m4a")
    }
    #expect(transport.count == 1)
}

// MARK: - Runs in a session

private let evalNoVocabulary = CloudEvaluation.VocabularySource(wordList: { [] }, names: { [] }, terms: { _ in [] })

private func evalOptions(maxSeconds: Double = 5) -> CloudEvaluation.Options {
    var settings = CloudSegmentation.Settings()
    settings.maxSeconds = maxSeconds
    settings.searchSeconds = 1
    return CloudEvaluation.Options(model: "gpt-transcribe", segmentation: settings)
}

/// Every file under `folder`, as text, for "the key is nowhere" checks.
private func evalAllText(_ folder: URL) -> String {
    SessionFixtures.files(in: folder).values.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
}

@Test func evalPrepareSavesNothingAndDiscardLeavesNoAudio() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    let prepared = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
    #expect(prepared.record.tracks.map(\.track) == ["mic"])
    #expect(prepared.record.tracks[0].segments.count == 3)
    #expect(prepared.pendingCount == 3)
    #expect(!SessionFixtures.exists(EvalPaths.cloudRoot(session)))
    #expect(SessionFixtures.exists(EvalPaths.work(prepared.record.id, in: session)))
    CloudEvaluation.discard(prepared)
    #expect(!SessionFixtures.exists(EvalPaths.work(prepared.record.id, in: session)))
    #expect(throws: HolosError.self) {
        _ = try CloudEvaluation.prepare(session: session, options: CloudEvaluation.Options(tracks: ["system"]),
                                        vocabulary: evalNoVocabulary)
    }
}

@Test func evalCorrectionsAndTheWordListShareTheSupportFolder() {
    // HOLOS_SUPPORT_DIR (the test run's scratch folder) moves both, so eval never touches the user's real lists.
    #expect(CorrectionList.defaultURL.deletingLastPathComponent().standardizedFileURL
        == HolosPaths.supportRoot.standardizedFileURL)
    #expect(CorrectionList.defaultURL.deletingLastPathComponent().standardizedFileURL
        == WordListStore.defaultURL.deletingLastPathComponent().standardizedFileURL)
}

@Test func evalVocabularyTakesTheWordListFirstAndRefusesAnUnreadableSource() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    var options = evalOptions()
    options.vocabulary = true
    let source = CloudEvaluation.VocabularySource(wordList: { ["Keycloak"] }, names: { ["Maria Chen"] },
                                                  terms: { _ in ["Kubernetes", "keycloak"] })
    let prepared = try CloudEvaluation.prepare(session: session, options: options, vocabulary: source)
    #expect(prepared.record.request.keywords == ["Keycloak", "Maria Chen", "Kubernetes"])
    #expect(prepared.record.request.prompt?.contains("Terms: Keycloak. People: Maria Chen. Other words: Kubernetes.")
        == true)
    CloudEvaluation.discard(prepared)

    struct Damaged: Error {}
    let damaged = CloudEvaluation.VocabularySource(wordList: { throw Damaged() }, names: { [] }, terms: { _ in [] })
    #expect(throws: Damaged.self) {
        _ = try CloudEvaluation.prepare(session: session, options: options, vocabulary: damaged)
    }
}

@Test func evalUploadSavesEachAnswerAndResumesAfterAFailure() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, name: "Private standup",
                                                        audioSeconds: ["mic": 12], transcript: nil)
    let first = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary,
                                            now: Date(timeIntervalSince1970: 1_790_000_000))
    let failing = EvalFakeTransport { index, _ in
        index == 0 ? evalOK("one two three") : .init(status: 400, body: #"{"error":{"message":"bad"}}"#)
    }
    await #expect(throws: CloudTranscriptionError.self) {
        _ = try await CloudEvaluation.upload(first, client: CloudTranscriptionClient(
            apiKey: evalKey, transport: failing, sleep: EvalSleeps().sleep))
    }
    let id = first.record.id
    #expect(SessionFixtures.exists(EvalPaths.segmentResult(id, track: "mic", index: 0, in: session)))
    #expect(SessionFixtures.exists(EvalPaths.rawResponse(id, track: "mic", index: 0, in: session)))
    #expect(!SessionFixtures.exists(EvalPaths.segmentResult(id, track: "mic", index: 1, in: session)))
    #expect(try EvalStore.runRecord(id, in: session)?.completedAt == nil)
    #expect(!SessionFixtures.exists(EvalPaths.work(id, in: session)))
    #expect(throws: HolosError.self) { _ = try EvalStore.resolveRun(nil, in: session) }

    // An explicit --run with other options than the run's is refused before anything is prepared.
    var conflicting = evalOptions()
    conflicting.runID = id
    conflicting.vocabulary = true
    #expect(throws: HolosError.self) {
        _ = try CloudEvaluation.prepare(session: session, options: conflicting, vocabulary: evalNoVocabulary)
    }
    // A run record that names another run is never trusted (its names become paths).
    var forged = try #require(try EvalStore.runRecord(id, in: session))
    forged.id = "../../exports"
    let forgedID = "gpt-transcribe-20260101T000000Z"
    try EvalStore.write(forged, to: EvalPaths.runRecord(forgedID, in: session))
    #expect(throws: HolosError.self) { _ = try EvalStore.runRecord(forgedID, in: session) }
    try EvalStore.deleteRun(forgedID, in: session)

    let second = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
    #expect(second.resumed)
    #expect(second.record.id == id)
    #expect(second.pending == ["mic": [1, 2]])
    let working = EvalFakeTransport { index, _ in evalOK(index == 0 ? "three four five" : "five six") }
    let outcome = try await CloudEvaluation.upload(second, client: CloudTranscriptionClient(
        apiKey: evalKey, transport: working, sleep: EvalSleeps().sleep))
    #expect(outcome.uploaded == 2)
    #expect(working.count == 2)
    let record = try EvalStore.resolveRun(nil, in: session)
    #expect(record.id == id && record.completedAt != nil)
    let track = try #require(try EvalStore.read(CloudTrackResult.self,
                                                from: EvalPaths.trackResult(id, track: "mic", in: session)))
    // Each segment overlaps the one before by 1 s (no pause in the fixture's tone), so repeated words go.
    #expect(track.text == "one two three four five six")
    #expect(EvalStore.savedSegments(record, in: session) == 3)
    let everything = evalAllText(EvalPaths.root(session))
    #expect(!everything.contains(evalKey))
    for request in working.requests.withLock({ $0 }) + failing.requests.withLock({ $0 }) {
        #expect(!bodyText(request).contains("Private standup"))
    }
    // A finished run is not resumed: the same command starts a new one.
    let third = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
    #expect(!third.resumed)
    CloudEvaluation.discard(third)
}

@Test func evalCompareReviewApplyAndDeleteAudio() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let words = ["hello", "team", "we", "deploy", "on", "cube", "control", "today"]
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(words, track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 6],
                                                        transcript: transcript)
    let prepared = try CloudEvaluation.prepare(session: session, options: evalOptions(maxSeconds: 300),
                                               vocabulary: evalNoVocabulary)
    let transport = EvalFakeTransport { _, _ in evalOK("Hello team, we deploy on Kubernetes today.") }
    _ = try await CloudEvaluation.upload(prepared, client: CloudTranscriptionClient(
        apiKey: evalKey, transport: transport, sleep: EvalSleeps().sleep))
    let run = try EvalStore.resolveRun(nil, in: session)

    let report = try EvalCompare.compare(session: session, run: run, now: SessionFixtures.date)
    #expect(report.transcriptID == transcript.id)
    #expect(report.total.localWords == 8 && report.total.cloudWords == 7)
    let wordPassages = report.passages.filter { $0.group != .caseOrPunctuation }
    #expect(wordPassages.map(\.local) == ["cube control"])
    #expect(wordPassages.map(\.cloud) == ["Kubernetes"])
    #expect(wordPassages.first?.group == .namesAndTerms)
    let written = try EvalCompare.write(report, session: session)
    #expect(SessionFixtures.text(written.markdown).contains("## Names and terms (1)"))
    #expect(try EvalCompare.readReport(run: run.id, session: session) == report)
    // Nothing of the evaluation reaches the exports.
    let exports = SessionFixtures.files(in: SessionPaths.exports(session))
    #expect(!exports.values.contains { String(decoding: $0, as: UTF8.self).contains("Kubernetes") })

    let lease = try SessionArchive.acquireProcessingLease(at: session)
    let page = try EvalReview.build(session: session, run: run, report: report)
    lease.release()
    #expect(SessionFixtures.text(page).contains("cube control"))
    let audio = EvalPaths.reviewAudio(run.id, in: session).appendingPathComponent("mic.m4a")
    #expect(SessionFixtures.exists(audio))

    let passageID = try #require(wordPassages.first?.id)
    let decisions = ReviewDecisions(sessionID: report.sessionID, run: run.id, transcriptID: report.transcriptID,
                                    decisions: [.init(id: passageID, choice: .edited, text: "Kubernetes")],
                                    terms: ["Kubernetes", " Grafana  Loki ", "kubernetes"])
    let result = try EvalApply.build(session: session, report: report, decisions: decisions)
    #expect(result.gold.tracks.first?.text == "hello team we deploy on Kubernetes today")
    #expect(result.corrections == [Correction(heard: "cube control", meant: "Kubernetes")])
    #expect(result.terms == ["Kubernetes", "Grafana Loki"])
    var stale = decisions
    stale.transcriptID = "other"
    #expect(throws: HolosError.self) { _ = try EvalApply.build(session: session, report: report, decisions: stale) }
    var unknown = decisions
    unknown.decisions = [.init(id: "mic-99", choice: .cloud, text: "x")]
    #expect(throws: HolosError.self) { _ = try EvalApply.build(session: session, report: report, decisions: unknown) }

    let corrections = temp.url.appendingPathComponent("corrections.json")
    #expect(try EvalApply.addToCorrections(result.corrections, at: corrections) == result.corrections)
    #expect(try CorrectionList.load(from: corrections).entries == result.corrections)
    #expect(try EvalApply.addToCorrections(result.corrections, at: corrections).isEmpty)

    // --add-vocabulary: the marked terms go to the word list, marked as from a review; a listed term stays as it is.
    let store = WordListStore(url: temp.url.appendingPathComponent("words.json"))
    _ = try WordListCommand.add(["grafana loki"], store: store)
    let added = try EvalApply.addToWordList(result.terms, store: store, at: SessionFixtures.date)
    #expect(added.output.first == "Added: Kubernetes.")
    #expect(added.errors == ["Already in the word list: grafana loki"])
    #expect(added.exitCode == 0)
    let listed = try store.load().entries
    #expect(listed.map(\.text) == ["grafana loki", "Kubernetes"])
    #expect(listed.map(\.source) == [.user, .review])

    // Delete Audio removes the review page's audio copy; the text results stay.
    let deleting = try SessionArchive.acquireProcessingLease(at: session)
    try SessionDeletion.deleteAudio(session: session, lease: deleting)
    deleting.release()
    #expect(!SessionFixtures.exists(audio))
    #expect(SessionFixtures.exists(page))
    #expect(SessionFixtures.exists(EvalPaths.trackResult(run.id, track: "mic", in: session)))

    #expect(try EvalStore.deleteRun(run.id, in: session))
    #expect(!SessionFixtures.exists(EvalPaths.cloudRun(run.id, in: session)))
    #expect(!SessionFixtures.exists(EvalPaths.compare(run.id, in: session)))
    #expect(!SessionFixtures.exists(EvalPaths.review(run.id, in: session)))
    #expect(try !EvalStore.deleteRun(run.id, in: session))
    #expect(throws: HolosError.self) { try EvalStore.deleteRun("../x", in: session) }
}

@Test func evalResumeRefusesAudioReplacedWithTheSameShape() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("a"),
                                                        audioSeconds: ["mic": 12], transcript: nil)
    let other = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("b"),
                                                      audioSeconds: ["mic": 12], transcript: nil, tone: 0.09)
    let first = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
    #expect(first.record.tracks[0].segments.allSatisfy { $0.audioSHA256?.count == 64 })
    let failing = EvalFakeTransport { index, _ in
        index == 0 ? evalOK("one two three") : .init(status: 400, body: #"{"error":{"message":"bad"}}"#)
    }
    await #expect(throws: CloudTranscriptionError.self) {
        _ = try await CloudEvaluation.upload(first, client: CloudTranscriptionClient(
            apiKey: evalKey, transport: failing, sleep: EvalSleeps().sleep))
    }
    // Other audio of the same format and length in the same chunk files: the manifest (and its fingerprint) and
    // the render's shape are unchanged, the samples are not.
    let chunks = try SessionArchive.readManifest(at: session).chunks
    let replacements = try SessionArchive.readManifest(at: other).chunks
    #expect(chunks.count == replacements.count)
    for (chunk, replacement) in zip(chunks, replacements) {
        let target = session.appendingPathComponent(chunk.relativePath)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: other.appendingPathComponent(replacement.relativePath), to: target)
    }
    let error = #expect(throws: HolosError.self) {
        _ = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
    }
    #expect(error?.localizedDescription.contains("renders differently") == true)
    #expect(failing.count == 2)
}

@Test func evalReviewRefusesAudioReplacedSinceTheRun() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(["hello", "team"], track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("a"),
                                                        audioSeconds: ["mic": 6], transcript: transcript)
    let other = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("b"),
                                                      audioSeconds: ["mic": 6], transcript: nil, tone: 0.09)
    let prepared = try CloudEvaluation.prepare(session: session, options: evalOptions(maxSeconds: 300),
                                               vocabulary: evalNoVocabulary)
    _ = try await CloudEvaluation.upload(prepared, client: CloudTranscriptionClient(
        apiKey: evalKey, transport: EvalFakeTransport { _, _ in evalOK("hello team") }, sleep: EvalSleeps().sleep))
    let run = try EvalStore.resolveRun(nil, in: session)
    let report = try EvalCompare.compare(session: session, run: run)
    let chunks = try SessionArchive.readManifest(at: session).chunks
    let replacements = try SessionArchive.readManifest(at: other).chunks
    for (chunk, replacement) in zip(chunks, replacements) {
        let target = session.appendingPathComponent(chunk.relativePath)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: other.appendingPathComponent(replacement.relativePath), to: target)
    }
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    #expect(throws: HolosError.self) { _ = try EvalReview.build(session: session, run: run, report: report) }
    #expect(!SessionFixtures.exists(EvalPaths.reviewAudio(run.id, in: session).appendingPathComponent("mic.m4a")))
}

@Test func evalResumeChecksATrackWhoseAnswersAreAllIn() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("a"),
                                                        audioSeconds: ["mic": 4, "system": 12], transcript: nil)
    let other = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("b"),
                                                      audioSeconds: ["mic": 4], transcript: nil, tone: 0.09)
    let first = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
    #expect(first.record.tracks.map(\.track) == ["mic", "system"])
    #expect(first.record.tracks[0].segments.count == 1)
    // The microphone's one segment is answered; the system track fails.
    let failing = EvalFakeTransport { index, _ in
        index == 0 ? evalOK("hello") : .init(status: 400, body: #"{"error":{"message":"bad"}}"#)
    }
    await #expect(throws: CloudTranscriptionError.self) {
        _ = try await CloudEvaluation.upload(first, client: CloudTranscriptionClient(
            apiKey: evalKey, transport: failing, sleep: EvalSleeps().sleep))
    }
    let mic = try #require(try SessionArchive.readManifest(at: session).chunks.first { $0.track == "mic" })
    let replacement = try #require(try SessionArchive.readManifest(at: other).chunks.first { $0.track == "mic" })
    let target = session.appendingPathComponent(mic.relativePath)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.copyItem(at: other.appendingPathComponent(replacement.relativePath), to: target)
    let error = #expect(throws: HolosError.self) {
        _ = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
    }
    #expect(error?.localizedDescription.contains("mic audio renders differently") == true)
}

@Test func evalConcurrentAppliesKeepEveryCorrection() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let url = temp.url.appendingPathComponent("corrections.json")
    try CorrectionList(entries: [Correction(heard: "seed", meant: "Seed")]).save(to: url)
    DispatchQueue.concurrentPerform(iterations: 24) { index in
        _ = try? EvalApply.addToCorrections([Correction(heard: "heard \(index)", meant: "meant \(index)")], at: url)
    }
    let entries = try CorrectionList.load(from: url).entries
    #expect(entries.count == 25)
    #expect(Set(entries.map(\.heard)) == Set(["seed"] + (0..<24).map { "heard \($0)" }))
    // A writer holding a list loaded before another's addition (the app) changes the saved list, not its copy.
    let (list, _) = try CorrectionList.update(at: url) { $0.remove(Correction(heard: "seed", meant: "Seed")) }
    #expect(list.entries.count == 24)
    #expect(try CorrectionList.load(from: url) == list)
}

@MainActor
@Test func evalCorrectionsFolderWatcherSeesAnAtomicSave() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let url = temp.url.appendingPathComponent("corrections.json")
    final class Seen: Sendable { let count = Mutex(0) }
    let seen = Seen()
    let watcher = try #require(FolderWatcher(folder: temp.url, queue: DispatchQueue(label: "eval-watch")) {
        seen.count.withLock { $0 += 1 }
    })
    _ = try EvalApply.addToCorrections([Correction(heard: "cube control", meant: "kubectl")], at: url)
    #expect(await eventually { seen.count.withLock { $0 } > 0 })
    withExtendedLifetime(watcher) {}
}

// MARK: - Fair comparison and local candidates

/// A session with `words` as its current microphone transcript and one finished cloud run answering `cloud`.
private func evalSessionWithCloudRun(in root: URL, words: [String], cloud: String,
                                     audioSeconds: [String: Double] = ["mic": 6]) async throws
    -> (session: URL, run: CloudRunRecord, transcript: Transcript) {
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(words, track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: root, audioSeconds: audioSeconds, transcript: transcript)
    let prepared = try CloudEvaluation.prepare(session: session, options: evalOptions(maxSeconds: 300),
                                               vocabulary: evalNoVocabulary)
    _ = try await CloudEvaluation.upload(prepared, client: CloudTranscriptionClient(
        apiKey: evalKey, transport: EvalFakeTransport { _, _ in evalOK(cloud) }, sleep: EvalSleeps().sleep))
    return (session, try EvalStore.resolveRun(nil, in: session), transcript)
}

/// Speech-model and merge dependencies for `eval local` with scripted speech.
private func evalLocalDependencies(_ speech: FakeSpeechFactory, status: String = "installed")
    -> LanguageDetectionDependencies {
    LanguageDetectionDependencies(
        makeSpeech: speech.factory, modelStatus: { _, _ in status },
        makeScorer: { { _, languages in Dictionary(uniqueKeysWithValues: languages.map { ($0, 0.5) }) } },
        timeouts: nil)
}

@Test func evalApplyIgnoresFormattingOnlyPassages() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let (session, run, _) = try await evalSessionWithCloudRun(
        in: temp.url, words: ["um", "we", "ship", "three", "builds", "to", "the", "cat"],
        cloud: "We ship 3 builds to the bat.")
    let report = try EvalCompare.compare(session: session, run: run)
    #expect(report.isNormalized && report.schemaVersion == CompareReport.currentSchemaVersion)
    let words = report.passages.filter { $0.group != .caseOrPunctuation }
    #expect(words.map(\.local) == ["um", "three", "cat"])
    #expect(words.map(\.formattingOnly) == [true, true, false])
    let raw = try EvalCompare.compare(session: session, run: run, normalize: false)
    #expect(!raw.isNormalized && raw.passages.allSatisfy { !$0.formattingOnly })
    #expect(raw.passages.map(\.id) == report.passages.map(\.id))
    #expect(raw.total == report.total)
    #expect(raw.normalizedTotal == nil && report.normalizedTotal?.edits == 1)

    let decisions = ReviewDecisions(sessionID: report.sessionID, run: run.id, transcriptID: report.transcriptID,
                                    decisions: [.init(id: words[1].id, choice: .cloud, text: "3"),
                                                .init(id: words[2].id, choice: .cloud, text: "bat")])
    let result = try EvalApply.build(session: session, report: report, decisions: decisions)
    #expect(result.ignoredFormatting == 1)
    #expect(result.gold.reviewedPassages == 1)
    #expect(result.gold.tracks.first?.text == "um we ship three builds to the bat")
    #expect(result.corrections.allSatisfy { !$0.heard.contains("three") })
}

@Test func evalLocalTranscribesEveryTrackIntoACandidateAndResumes() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(["hello", "team"], track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 4, "system": 4], transcript: transcript)
    let before = SessionFixtures.files(in: session).filter { !$0.key.contains("eval/") }
    let heard = SessionFixtures.segment(["we", "ship", "on", "Kubernetes"], track: nil, start: 0.5)
    let vocabulary = ["Kubernetes", "Maria Chen"]

    // Not installed: refused before anything is transcribed or saved.
    let none = FakeSpeechFactory()
    await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: .init(), vocabulary: vocabulary,
                                    dependencies: evalLocalDependencies(none, status: "supported"))
    }
    #expect(none.calls.isEmpty)
    #expect(EvalLocal.runIDs(in: session).isEmpty)

    // The microphone is transcribed and saved; the system track fails.
    let failing = FakeSpeechFactory([FakeSpeechScript(segments: [heard]),
                                     FakeSpeechScript(makeError: .unavailable("The speech service is busy."))])
    await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: .init(), vocabulary: vocabulary,
                                    dependencies: evalLocalDependencies(failing),
                                    now: Date(timeIntervalSince1970: 1_790_000_000))
    }
    let id = try #require(EvalLocal.runIDs(in: session).first)
    let unfinished = try #require(try EvalLocal.record(id, in: session))
    #expect(unfinished.completedAt == nil)
    #expect(unfinished.vocabulary == vocabulary && unfinished.vocabularySource == "current")
    #expect(unfinished.languages == ["en-CA"] && unfinished.tracks.map(\.track) == ["mic", "system"])
    #expect(EvalLocal.savedParts(unfinished, in: session) == 1)
    #expect(failing.calls.map(\.contextualStrings) == [vocabulary, vocabulary])
    #expect(throws: HolosError.self) { _ = try EvalLocal.resolve("latest", in: session) }

    // The same command resumes: only the system track is transcribed.
    let resuming = FakeSpeechFactory([FakeSpeechScript(segments: [heard])])
    let record = try await EvalLocal.run(session: session, options: .init(), vocabulary: vocabulary,
                                         dependencies: evalLocalDependencies(resuming))
    #expect(record.id == id && record.completedAt != nil)
    #expect(resuming.calls.count == 1)
    let candidate = try EvalLocal.transcript(of: try EvalLocal.resolve("latest", in: session), in: session)
    #expect(candidate.id == record.transcriptID)
    #expect(Set(candidate.segments.compactMap(\.track)) == ["mic", "system"])
    #expect(candidate.segments.map(\.text) == ["we ship on Kubernetes", "we ship on Kubernetes"])

    // The meeting itself is untouched: transcript, exports, speaker labels, vocabulary.json.
    let after = SessionFixtures.files(in: session).filter { !$0.key.contains("eval/") }
    #expect(after == before)
    #expect(try SessionArchive.currentTranscriptID(at: session) == transcript.id)

    // Without vocabulary, a new run; deleting one removes it.
    let bare = FakeSpeechFactory([FakeSpeechScript(segments: [heard]), FakeSpeechScript(segments: [heard])])
    let second = try await EvalLocal.run(session: session, options: .init(), vocabulary: nil,
                                         dependencies: evalLocalDependencies(bare),
                                         now: Date(timeIntervalSince1970: 1_790_000_100))
    #expect(second.id != id && second.vocabulary.isEmpty && second.vocabularySource == "none")
    #expect(bare.calls.map(\.contextualStrings) == [[], []])
    #expect(try EvalStore.deleteRun(second.id, in: session))
    #expect(EvalLocal.runIDs(in: session) == [id])
    #expect(throws: HolosError.self) { _ = try EvalLocal.record("../x", in: session) }
}

@Test func evalLocalNeverResumesOverAudioWhoseBytesChanged() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("a"),
                                                        source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 4, "system": 4], transcript: nil)
    let other = try await SessionFixtures.makeSession(in: temp.url.appendingPathComponent("b"),
                                                      source: .microphoneAndSystem,
                                                      audioSeconds: ["mic": 4, "system": 4], transcript: nil,
                                                      tone: 0.09)
    let heard = SessionFixtures.segment(["hello"], track: nil, start: 0.5)
    let failing = FakeSpeechFactory([FakeSpeechScript(segments: [heard]),
                                     FakeSpeechScript(makeError: .unavailable("busy"))])
    await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: .init(), vocabulary: nil,
                                    dependencies: evalLocalDependencies(failing),
                                    now: Date(timeIntervalSince1970: 1_790_000_000))
    }
    let id = try #require(EvalLocal.runIDs(in: session).first)
    // Other samples in the same chunk files: the manifest and its fingerprint are unchanged, the bytes are not.
    let chunks = try SessionArchive.readManifest(at: session).chunks
    let replacements = try SessionArchive.readManifest(at: other).chunks
    for (chunk, replacement) in zip(chunks, replacements) {
        let target = session.appendingPathComponent(chunk.relativePath)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: other.appendingPathComponent(replacement.relativePath), to: target)
    }
    let error = await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: .init(runID: id), vocabulary: nil,
                                    dependencies: evalLocalDependencies(FakeSpeechFactory()))
    }
    #expect(error?.localizedDescription.contains("audio changed") == true)
    // Without --run, a new run is started rather than the old one resumed.
    let fresh = FakeSpeechFactory([FakeSpeechScript(segments: [heard]), FakeSpeechScript(segments: [heard])])
    let record = try await EvalLocal.run(session: session, options: .init(), vocabulary: nil,
                                         dependencies: evalLocalDependencies(fresh),
                                         now: Date(timeIntervalSince1970: 1_790_000_100))
    #expect(record.id != id && fresh.calls.count == 2)
}

@Test func evalCompareWithALocalCandidateCountsTermsAndLeavesTheCurrentReport() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let (session, run, transcript) = try await evalSessionWithCloudRun(
        in: temp.url, words: ["hello", "team", "we", "deploy", "on", "cube", "control", "today"],
        cloud: "Hello team, we deploy on Kubernetes today.")
    let terms = EvalTerms.terms(wordList: ["Kubernetes"], corrections: ["Grafana"])
    let current = try EvalCompare.compare(session: session, run: run, terms: terms, now: SessionFixtures.date)
    #expect(current.terms?.map { "\($0.term) \($0.hits)/\($0.cloud)" } == ["Kubernetes 0/1"])
    #expect(current.termsNotHeard == 1)
    #expect(current.local?.source == "current" && current.local?.vocabulary == "vocabulary.json")
    let currentFiles = try EvalCompare.write(current, session: session)

    let heard = SessionFixtures.segment(["hello", "team", "we", "deploy", "on", "Kubernetes", "today"], track: nil,
                                        start: 0.5)
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [heard])])
    let record = try await EvalLocal.run(session: session, options: .init(), vocabulary: ["Kubernetes"],
                                         dependencies: evalLocalDependencies(speech))
    let candidate = try EvalCompare.compare(session: session, run: run, local: .candidate(record), terms: terms)
    #expect(candidate.local?.source == record.id)
    #expect(candidate.local?.vocabulary == "current" && candidate.local?.vocabularyCount == 1)
    #expect(candidate.transcriptID == record.transcriptID && candidate.transcriptID != transcript.id)
    #expect(candidate.terms?.map { "\($0.term) \($0.hits)/\($0.cloud)" } == ["Kubernetes 1/1"])
    #expect(candidate.passages.filter(\.needsReview).isEmpty)
    // A local run of other audio is never compared with the cloud run.
    var other = record
    other.tracks[0].audioFingerprint = "other"
    let mismatch = #expect(throws: HolosError.self) {
        _ = try EvalCompare.compare(session: session, run: run, local: .candidate(other), terms: terms)
    }
    #expect(mismatch?.localizedDescription.contains("different mic audio") == true)
    let written = try EvalCompare.write(candidate, session: session)
    #expect(written.markdown.deletingLastPathComponent().lastPathComponent == record.id)
    #expect(SessionFixtures.text(written.markdown).contains("local run \(record.id)"))
    // The comparison of the current transcript is still the one review and apply read.
    #expect(try EvalCompare.readReport(run: run.id, session: session) == current)
    #expect(SessionFixtures.exists(currentFiles.markdown))
    let decisions = ReviewDecisions(sessionID: candidate.sessionID, run: run.id, transcriptID: candidate.transcriptID,
                                    decisions: [])
    #expect(throws: HolosError.self) { _ = try EvalApply.build(session: session, report: candidate, decisions: decisions) }

    // Deleting the local run removes its comparisons too.
    #expect(try EvalStore.deleteRun(record.id, in: session))
    #expect(!SessionFixtures.exists(written.markdown))
    #expect(SessionFixtures.exists(currentFiles.markdown))
}

@Test func evalLocalKeepsASilentTrackButRefusesALanguageThatHeardNothing() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let transcript = SessionFixtures.transcript([SessionFixtures.segment(["hello", "team"], track: "mic", start: 0.5)])
    let session = try await SessionFixtures.makeSession(in: temp.url, source: .microphoneAndSystem,
                                                        audioSeconds: ["mic": 4, "system": 4], transcript: transcript)
    let heard = SessionFixtures.segment(["hello", "team"], track: nil, start: 0.5)

    // Nothing heard on any track, while the meeting's transcript has words: refused, and nothing saved.
    let deaf = FakeSpeechFactory([FakeSpeechScript(segments: []), FakeSpeechScript(segments: [])])
    let error = await #expect(throws: HolosError.self) {
        _ = try await EvalLocal.run(session: session, options: .init(), vocabulary: nil,
                                    dependencies: evalLocalDependencies(deaf),
                                    now: Date(timeIntervalSince1970: 1_790_000_000))
    }
    #expect(error?.localizedDescription.contains("No words were recognized") == true)
    let id = try #require(EvalLocal.runIDs(in: session).first)
    #expect(EvalLocal.savedParts(try #require(try EvalLocal.record(id, in: session)), in: session) == 0)

    // The same command tries both tracks again; a silent system track is a finished part.
    let speech = FakeSpeechFactory([FakeSpeechScript(segments: [heard]), FakeSpeechScript(segments: [])])
    let record = try await EvalLocal.run(session: session, options: .init(), vocabulary: nil,
                                         dependencies: evalLocalDependencies(speech))
    #expect(record.id == id && record.completedAt != nil && speech.calls.count == 2)
    #expect(EvalLocal.savedParts(record, in: session) == 2)
    let candidate = try EvalLocal.transcript(of: record, in: session)
    #expect(candidate.segments.map(\.text) == ["hello team"])
}

@Test func evalRefusesASessionThatWasNotFinishedProperly() async throws {
    let temp = try TemporaryDirectory("eval")
    defer { temp.remove() }
    let session = try await SessionFixtures.makeSession(in: temp.url, audioSeconds: ["mic": 12], transcript: nil)
    // A crashed recorder leaves the manifest as "recording" or "interrupted"; recovery may add unlisted audio.
    let url = SessionPaths.manifest(session)
    var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    for status in [ArchiveStatus.recording, ArchiveStatus.interrupted] {
        object["status"] = status
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        #expect(throws: HolosError.self) {
            _ = try CloudEvaluation.prepare(session: session, options: evalOptions(), vocabulary: evalNoVocabulary)
        }
        await #expect(throws: HolosError.self) {
            _ = try await EvalLocal.run(session: session, options: .init(), vocabulary: nil)
        }
    }
}
