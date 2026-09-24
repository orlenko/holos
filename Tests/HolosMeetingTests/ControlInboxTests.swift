import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import Testing

// The recorder's side of control/ (docs/meeting-design.md §4.1).

private struct InboxFolder {
    let temp: TemporaryDirectory
    let sessionID = UUID().uuidString
    let session: URL
    let control: URL

    init() throws {
        temp = try TemporaryDirectory("inbox")
        session = temp.url.appendingPathComponent("\(sessionID).holos", isDirectory: true)
        control = session.appendingPathComponent("control", isDirectory: true)
        try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    func write(_ request: ControlRequest, as name: String? = nil) throws {
        try write(try HolosJSON.encoder().encode(request), as: name ?? "\(request.id).json")
    }

    func write(_ data: Data, as name: String) throws {
        try data.write(to: control.appendingPathComponent(name))
    }

    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: control.path)) ?? []).sorted()
    }
}

@Test func inboxRejectsForeignSessionUnknownCommandSymlinkAndOversize() throws {
    let folder = try InboxFolder()
    defer { folder.temp.remove() }
    let good = recorderRequest(.marker, sessionID: folder.sessionID, label: "Vote")
    try folder.write(good)
    let foreign = recorderRequest(.pause, sessionID: UUID().uuidString)
    try folder.write(foreign)
    let unknownID = UUID().uuidString
    let unknown = """
        {"command":"explode","createdAt":"2026-09-24T10:00:00Z","id":"\(unknownID)","schemaVersion":1,\
        "sender":"cli","sessionID":"\(folder.sessionID)"}
        """
    try folder.write(Data(unknown.utf8), as: "\(unknownID).json")
    // A link to a real request elsewhere: it is removed itself, and its target is never read or touched.
    let outside = folder.temp.url.appendingPathComponent("outside.json")
    try HolosJSON.encoder().encode(recorderRequest(.stop, sessionID: folder.sessionID)).write(to: outside)
    let linkName = "\(UUID().uuidString).json"
    try FileManager.default.createSymbolicLink(at: folder.control.appendingPathComponent(linkName),
                                               withDestinationURL: outside)
    let large = recorderRequest(.marker, sessionID: folder.sessionID, label: String(repeating: "x", count: 5_000))
    try folder.write(large)

    var inbox = ControlInbox(session: folder.session, sessionID: folder.sessionID)
    let items = inbox.poll()
    #expect(items.filter { if case .request = $0 { true } else { false } } == [.request(good)])
    let rejected = items.compactMap { item -> String? in
        if case .rejected(let file, _) = item { return file }
        return nil
    }
    #expect(Set(rejected) == ["\(foreign.id).json", "\(unknownID).json", linkName, "\(large.id).json"])
    #expect(folder.files.isEmpty, "All five files are removed.")
    #expect(FileManager.default.fileExists(atPath: outside.path), "The link's target is left alone.")
    #expect(inbox.poll().isEmpty)
}

@Test func inboxOrdersBySentAtNotCreatedAt() throws {
    let folder = try InboxFolder()
    defer { folder.temp.remove() }
    let sameSecond = Date(timeIntervalSince1970: 1_790_000_000)
    // resume's ID sorts first, but pause was sent first.
    let pause = recorderRequest(.pause, id: "FFFFFFFF-0000-4000-8000-000000000000", sessionID: folder.sessionID,
                                sentAtNanos: 100, createdAt: sameSecond)
    let resume = recorderRequest(.resume, id: "00000000-0000-4000-8000-000000000000", sessionID: folder.sessionID,
                                 sentAtNanos: 200, createdAt: sameSecond)
    try folder.write(resume)
    try folder.write(pause)
    var inbox = ControlInbox(session: folder.session, sessionID: folder.sessionID)
    let items = inbox.poll()
    #expect(items == [.request(pause), .request(resume)])
    // Applied in that order: pause, then resume.
    var machine = recorderRunningMachine()
    var results: [ControlResult] = []
    for case .request(let request) in items {
        for case .acknowledge(let ack) in machine.handle(.control(request, at: 1)) { results.append(ack.result) }
    }
    #expect(results == [.applied, .applied])
    #expect(machine.phase == .recording)
    #expect(machine.epoch == 1)
}

@Test func inboxIgnoresTemporaryFiles() throws {
    let folder = try InboxFolder()
    defer { folder.temp.remove() }
    let pending = recorderRequest(.stop, sessionID: folder.sessionID)
    let temporary = ".\(pending.id).tmp"
    try folder.write(try HolosJSON.encoder().encode(pending), as: temporary)
    let request = recorderRequest(.marker, sessionID: folder.sessionID)
    try folder.write(request)
    var inbox = ControlInbox(session: folder.session, sessionID: folder.sessionID)
    #expect(inbox.poll() == [.request(request)])
    #expect(folder.files == [temporary], "The temporary file is untouched.")
}

@Test func inboxCutsLabelsAndChecksTheFileName() throws {
    let folder = try InboxFolder()
    defer { folder.temp.remove() }
    let long = recorderRequest(.marker, sessionID: folder.sessionID, label: String(repeating: "é", count: 300))
    try folder.write(long)
    let renamed = recorderRequest(.marker, sessionID: folder.sessionID)
    let otherName = "\(UUID().uuidString).json"
    try folder.write(renamed, as: otherName)
    var inbox = ControlInbox(session: folder.session, sessionID: folder.sessionID)
    let items = inbox.poll()
    #expect(items.count == 2)
    #expect(items.contains { if case .rejected(otherName, _) = $0 { true } else { false } })
    let cut = items.compactMap { item -> ControlRequest? in
        if case .request(let request) = item { return request }
        return nil
    }.first
    #expect(cut?.label?.count == 200)
}

@Test func inboxWithoutAControlFolderIsEmpty() throws {
    let temp = try TemporaryDirectory("inbox")
    defer { temp.remove() }
    let id = UUID().uuidString
    var inbox = ControlInbox(session: temp.url.appendingPathComponent("\(id).holos"), sessionID: id)
    #expect(inbox.poll().isEmpty)
    #expect(ControlInbox.removeLeftovers(session: temp.url.appendingPathComponent("\(id).holos")) == 0)
}

/// A request that arrives while the recorder is stopping is acknowledged `ignored`, its file is deleted, and nothing
/// is left in control/ at exit (§4.6).
@Test(.timeLimit(.minutes(1))) @MainActor
func commandsAfterStopAreIgnored() async throws {
    let temp = try TemporaryDirectory()
    defer { temp.remove() }
    let answer = SharedValue<ControlAck?>(nil)
    let leftAfterAck = SharedValue<[String]?>(nil)
    let hook: PostProcessHook = { session, _, _ in
        answer.set(try? await recorderSend(.pause, to: session))
        let control = SessionPaths.controlDirectory(session)
        leftAfterAck.set((try? FileManager.default.contentsOfDirectory(atPath: control.path)) ?? [])
        return PostProcessingRecord(sessionID: session.deletingPathExtension().lastPathComponent, state: .succeeded,
                                    pid: getpid(), startedAt: Date(), updatedAt: Date())
    }
    let captures = FakeCaptureFactory([FakeCaptureScript(frames: FakeFrame.run(count: 2))])
    let stop = ManualStopSource()
    let run = Task {
        try await RecordingWorkflow.run(.testing(root: temp.url, recordOnly: true),
            dependencies: recorderDependencies(captures: captures, postProcess: hook, stop: stop))
    }
    #expect(await eventually { (captures.captures.first?.consumedFrames ?? 0) >= 2 })
    stop.requestStop()
    let outcome = try await run.value
    let ack = try #require(answer.value)
    #expect(ack.command == .pause)
    #expect(ack.result == .ignored)
    #expect(ack.message?.contains("already stopping") == true)
    #expect(leftAfterAck.value == [], "The request file is deleted when it is answered.")
    let control = SessionPaths.controlDirectory(outcome.directory)
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: control.path)) ?? []).isEmpty)
    let status = try #require(try RecorderChannel.readStatus(session: outcome.directory))
    #expect(status.phase == .exited)
    #expect(status.handledRequests.map(\.id) == [ack.id])
}
