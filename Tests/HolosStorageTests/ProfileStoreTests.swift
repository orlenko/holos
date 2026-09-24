import Darwin
import Foundation
import Testing
import HolosCore
@testable import HolosStorage

// SpeakerProfileStore (docs/meeting-design.md §2.2, §4.10): the people store and its forget journal.

private let profileDate = Date(timeIntervalSince1970: 1_790_000_000)
private let profileModel = EmbeddingModelID(id: "fake", revision: "1")

/// A fresh temporary root; the store folder inside it does not exist yet.
private func profileRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-profiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func profileMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & 0o777
}

private func profileSample(session: String = UUID().uuidString) -> VoiceprintSample {
    VoiceprintSample(sessionID: session, sessionName: "Council meeting", speakerIDs: ["system:S1"], speechSeconds: 30,
                     embedding: FloatVector([1, 0, 0]), condition: .call, weak: false, addedAt: profileDate)
}

@Test func missingStoreLoadsEmptyWithRememberOff() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    let database = try store.load()
    #expect(database == SpeakerProfileDatabase())
    #expect(!database.rememberVoices)
    #expect(!FileManager.default.fileExists(atPath: store.directory.path), "Loading creates nothing.")
}

@Test(.timeLimit(.minutes(1)))
func profileStoreIsPrivateLockedAndNotBackedUp() async throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))

    // Two concurrent read-modify-writes: both apply (profiles.lock serializes them).
    try await withThrowingTaskGroup(of: Void.self) { group in
        for name in ["Jim", "Maria"] {
            group.addTask {
                for index in 0..<10 {
                    try store.update { $0.profiles.append(SpeakerProfile(displayName: "\(name) \(index)")) }
                }
            }
        }
        try await group.waitForAll()
    }
    let database = try store.load()
    #expect(database.profiles.count == 20)
    #expect(Set(database.profiles.map(\.id)).count == 20)

    #expect(profileMode(store.directory) == 0o700)
    #expect(profileMode(store.databaseURL) == 0o600)
    #expect(profileMode(store.directory.appendingPathComponent("profiles.lock")) == 0o600)
    let values = try URL(fileURLWithPath: store.directory.path).resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
}

@Test func existingFolderIsMadePrivate() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Speakers")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o755])
    let store = SpeakerProfileStore(directory: folder)
    try store.update { $0.rememberVoices = true }
    #expect(profileMode(folder) == 0o700)
    #expect(try store.load().rememberVoices)
}

@Test func linkInPlaceOfTheFolderIsRefused() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let elsewhere = root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let folder = root.appendingPathComponent("Speakers")
    try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: elsewhere)
    let store = SpeakerProfileStore(directory: folder)
    #expect(throws: HolosError.self) { try store.update { $0.rememberVoices = true } }
    #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("profiles.json").path))
}

@Test func updateValidatesBeforeWriting() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    try store.update { $0.profiles.append(SpeakerProfile(id: "ME", displayName: "Me", isSelf: true)) }
    let before = try Data(contentsOf: store.databaseURL)

    // A second person marked as you.
    #expect(throws: HolosError.self) {
        try store.update { $0.profiles.append(SpeakerProfile(displayName: "Also me", isSelf: true)) }
    }
    // Two samples from one meeting for one person.
    let session = UUID().uuidString
    #expect(throws: HolosError.self) {
        try store.update { database in
            database.profiles.append(SpeakerProfile(displayName: "Jim", embeddingModel: profileModel,
                                                    samples: [profileSample(session: session),
                                                              profileSample(session: session)]))
        }
    }
    // A sample without the person's embedding model, a blank name, a repeated ID.
    #expect(throws: HolosError.self) {
        try store.update { $0.profiles.append(SpeakerProfile(displayName: "Jim", samples: [profileSample()])) }
    }
    #expect(throws: HolosError.self) { try store.update { $0.profiles.append(SpeakerProfile(displayName: "  ")) } }
    #expect(throws: HolosError.self) {
        try store.update { $0.profiles.append(SpeakerProfile(id: "ME", displayName: "Copy")) }
    }
    #expect(try Data(contentsOf: store.databaseURL) == before, "A refused update writes nothing.")
}

@Test func newerStoreIsRefusedAndNeverOverwritten() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    try store.update { $0.rememberVoices = true }
    let newer = Data(#"{"schemaVersion": 2, "rememberVoices": true, "profiles": [], "future": 1}"#.utf8)
    try AtomicFile.write(newer, to: store.databaseURL)
    #expect(throws: HolosError.self) { try store.load() }
    #expect(throws: HolosError.self) { try store.update { $0.rememberVoices = false } }
    #expect(try Data(contentsOf: store.databaseURL) == newer)
}

@Test func storeRoundTripsSamples() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    let sample = profileSample()
    let profile = SpeakerProfile(id: "JIM", displayName: "Jim", createdAt: profileDate, embeddingModel: profileModel,
                                 samples: [sample])
    try store.update { $0.profiles = [profile]; $0.rememberVoices = true }
    let loaded = try store.load()
    #expect(loaded.profiles == [profile])
    #expect(loaded.sampleCount == 1)
    #expect(loaded.sampleSessionIDs == [sample.sessionID])
    // Printing never shows a name or a vector.
    #expect(!String(describing: profile).contains("Jim"))
    #expect(!String(describing: loaded).contains("Jim"))
}

@Test func forgetJournalTracksPendingAndCompacts() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    let first = ForgetRecord(kind: .profile, profileID: "JIM", sampleIDs: ["A"], sessionIDs: ["S"])
    let second = ForgetRecord(kind: .all, sampleIDs: [])
    try store.appendForgetRecord(first)
    try store.appendForgetRecord(second)
    try store.appendForgetRecord(.done(first.id))
    #expect(try store.pendingForgets() == [second])
    #expect(profileMode(store.forgetJournalURL) == 0o600)

    // A torn tail is skipped.
    try AtomicFile.append(Data(#"{"schemaVersion":1,"id":"TORN""#.utf8), to: store.forgetJournalURL)
    #expect(try store.pendingForgets() == [second])

    try store.compactForgetJournal()
    #expect(try store.forgetRecords() == [second])
    try store.appendForgetRecord(.done(second.id))
    try store.compactForgetJournal()
    #expect(!FileManager.default.fileExists(atPath: store.forgetJournalURL.path))
    #expect(try store.pendingForgets().isEmpty)
}

@Test func supportRootHoldsTheSpeakersFolder() {
    #expect(HolosPaths.speakerProfiles == HolosPaths.supportRoot.appendingPathComponent("Speakers", isDirectory: true))
}
