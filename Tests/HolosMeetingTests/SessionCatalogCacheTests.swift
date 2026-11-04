import Foundation
import HolosCore
@testable import HolosMeeting
import HolosStorage
import HolosTestSupport
import Testing

// SessionCatalogCache: a meeting whose folder did not change is not read again, and anything that changed is.

private func quietMeeting(in root: URL, name: String = "Council") throws -> URL {
    let archive = try SessionArchive.create(root: root, name: name, source: .microphone, locale: "en-CA",
                                            backend: .speech)
    return archive.directory
}

private func renamed(_ session: URL, to name: String) throws {
    var manifest = try SessionArchive.readManifest(at: session)
    manifest.name = name
    try AtomicFile.writeJSON(manifest, to: SessionPaths.manifest(session))
}

private func summary(status liveness: RecorderLiveness, state: SessionState = .complete,
                     speakers: SpeakerLabelState = .labelled, transcriptProblem: String? = nil,
                     metadataProblem: String? = nil, exportsProblem: String? = nil,
                     summaryProblem: String? = nil) -> SessionSummary {
    SessionSummary(id: "a", directory: URL(fileURLWithPath: "/nowhere/a.holos"), name: "a", createdAt: Date(),
                   source: .microphone, state: state, manifestStatus: "complete", transcriptProblem: transcriptProblem,
                   speakerState: speakers, liveness: liveness, metadataProblem: metadataProblem,
                   exportsProblem: exportsProblem, summaryProblem: summaryProblem)
}

@Test func anUnchangedMeetingIsNotReadAgain() throws {
    let temp = try TemporaryDirectory("catalog-cache", permissions: 0o700)
    defer { temp.remove() }
    let session = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    let first = SessionCatalog.list(root: temp.url, cache: cache)
    #expect(cache.reusedCount == 0)
    let second = SessionCatalog.list(root: temp.url, cache: cache)
    #expect(cache.reusedCount == 1)
    #expect(second.map(\.id) == first.map(\.id))
    #expect(second.first?.directory == session)
    #expect(second.first?.bytes == first.first?.bytes)
}

@Test func aChangedFileIsSeenByTheNextListing() throws {
    let temp = try TemporaryDirectory("catalog-cache-changed", permissions: 0o700)
    defer { temp.remove() }
    let session = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    _ = SessionCatalog.list(root: temp.url, cache: cache)
    try renamed(session, to: "Budget")
    #expect(SessionCatalog.list(root: temp.url, cache: cache).first?.name == "Budget")
    #expect(cache.reusedCount == 0)
}

@Test func aFileReplacedByTheSameBytesReadsAgain() throws {
    let temp = try TemporaryDirectory("catalog-cache-same", permissions: 0o700)
    defer { temp.remove() }
    let session = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    _ = SessionCatalog.list(root: temp.url, cache: cache)
    try renamed(session, to: "Council")
    _ = SessionCatalog.list(root: temp.url, cache: cache)
    #expect(cache.reusedCount == 0, "An atomic write is a new file, whatever it holds.")
}

@Test func aFileAddedOrRemovedReadsAgainAndCountsInTheSize() throws {
    let temp = try TemporaryDirectory("catalog-cache-added", permissions: 0o700)
    defer { temp.remove() }
    let session = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    let before = try #require(SessionCatalog.list(root: temp.url, cache: cache).first)
    let added = session.appendingPathComponent("derived", isDirectory: true)
    try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
    let file = added.appendingPathComponent("note.bin")
    try Data(repeating: 1, count: 500).write(to: file)
    let grown = try #require(SessionCatalog.list(root: temp.url, cache: cache).first)
    #expect(grown.bytes == before.bytes + 500)
    #expect(grown.derivedBytes == 500)
    try FileManager.default.removeItem(at: file)
    let shrunk = try #require(SessionCatalog.list(root: temp.url, cache: cache).first)
    #expect(shrunk.bytes == before.bytes)
    #expect(cache.reusedCount == 0)
}

@Test func aSummaryIsReusedForAtMostItsMaximumAge() throws {
    let temp = try TemporaryDirectory("catalog-cache-age", permissions: 0o700)
    defer { temp.remove() }
    _ = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    let start = Date()
    _ = SessionCatalog.list(root: temp.url, now: start, cache: cache)
    _ = SessionCatalog.list(root: temp.url, now: start.addingTimeInterval(SessionCatalogCache.maxAge - 1), cache: cache)
    #expect(cache.reusedCount == 1)
    _ = SessionCatalog.list(root: temp.url, now: start.addingTimeInterval(SessionCatalogCache.maxAge + 1), cache: cache)
    #expect(cache.reusedCount == 1, "Too old: read again, and kept from then.")
    _ = SessionCatalog.list(root: temp.url, now: start, cache: cache)
    #expect(cache.reusedCount == 1, "A clock moved back says nothing about its age.")
}

@Test func theBackgroundJobLockIsReadForEachListing() throws {
    let temp = try TemporaryDirectory("catalog-cache-job", permissions: 0o700)
    defer { temp.remove() }
    let session = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    _ = SessionCatalog.summary(session: session, jobState: .free, cache: cache)
    let held = SessionCatalog.summary(session: session, jobState: .held(nil), cache: cache)
    #expect(cache.reusedCount == 1)
    #expect(held.jobInProgress != nil)
    #expect(SessionCatalog.summary(session: session, jobState: .free, cache: cache).jobInProgress == nil)
}

@Test func aFolderNoLongerListedIsForgotten() throws {
    let temp = try TemporaryDirectory("catalog-cache-gone", permissions: 0o700)
    defer { temp.remove() }
    let session = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    _ = SessionCatalog.list(root: temp.url, cache: cache)
    try FileManager.default.removeItem(at: session)
    #expect(SessionCatalog.list(root: temp.url, cache: cache).isEmpty)
    #expect(cache.reusedCount == 0)
}

@Test func onlyASettledMeetingIsKept() {
    #expect(SessionCatalogCache.isSettled(summary(status: .exited)))
    #expect(SessionCatalogCache.isSettled(summary(status: .dead, state: .interrupted)))
    for live in [RecorderLiveness.capturing, .processing, .maintenance] {
        #expect(!SessionCatalogCache.isSettled(summary(status: live)), "A recorder is at work on it.")
    }
    #expect(!SessionCatalogCache.isSettled(summary(status: .exited, state: .damaged)))
    #expect(!SessionCatalogCache.isSettled(summary(status: .exited, speakers: .unreadable)))
    #expect(!SessionCatalogCache.isSettled(summary(status: .exited, transcriptProblem: "busy")))
    #expect(!SessionCatalogCache.isSettled(summary(status: .exited, metadataProblem: "busy")))
    #expect(!SessionCatalogCache.isSettled(summary(status: .exited, exportsProblem: "busy")))
    #expect(!SessionCatalogCache.isSettled(summary(status: .exited, summaryProblem: "busy")))
}

@Test func anUnsettledMeetingForgetsWhatWasKept() throws {
    let temp = try TemporaryDirectory("catalog-cache-unsettled", permissions: 0o700)
    defer { temp.remove() }
    let session = try quietMeeting(in: temp.url)
    let cache = SessionCatalogCache()
    let now = Date()
    cache.remember(summary(status: .exited), session: session, stamp: 1, now: now)
    #expect(cache.summary(of: session, stamp: 1, liveness: .exited, now: now) != nil)
    #expect(cache.summary(of: session, stamp: 2, liveness: .exited, now: now) == nil, "The folder changed.")
    #expect(cache.summary(of: session, stamp: 1, liveness: .dead, now: now) == nil, "The recorder's state changed.")
    cache.remember(summary(status: .capturing), session: session, stamp: 1, now: now)
    #expect(cache.summary(of: session, stamp: 1, liveness: .capturing, now: now) == nil)
    #expect(cache.summary(of: session, stamp: 1, liveness: .exited, now: now) == nil)
}
