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

@Test func damagedStoreIsRefusedOnLoad() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    try store.update { $0.rememberVoices = true }
    let session = UUID().uuidString
    let repeated = profileSample()
    let damaged: [SpeakerProfileDatabase] = [
        // A repeated person ID, two people marked as you, two samples from one meeting, a repeated sample ID,
        // samples of different dimensions (within one person, and between two people of one model), and a sample
        // without its person's embedding model.
        SpeakerProfileDatabase(profiles: [SpeakerProfile(id: "JIM", displayName: "Jim"),
                                          SpeakerProfile(id: "JIM", displayName: "Jim")]),
        SpeakerProfileDatabase(profiles: [SpeakerProfile(displayName: "Me", isSelf: true),
                                          SpeakerProfile(displayName: "Also me", isSelf: true)]),
        SpeakerProfileDatabase(profiles: [SpeakerProfile(displayName: "Jim", embeddingModel: profileModel,
                                                         samples: [profileSample(session: session),
                                                                   profileSample(session: session)])]),
        SpeakerProfileDatabase(profiles: [
            SpeakerProfile(displayName: "Jim", embeddingModel: profileModel, samples: [repeated]),
            SpeakerProfile(displayName: "Maria", embeddingModel: profileModel, samples: [repeated]),
        ]),
        SpeakerProfileDatabase(profiles: [SpeakerProfile(displayName: "Jim", embeddingModel: profileModel, samples: [
            profileSample(), VoiceprintSample(sessionID: session, sessionName: "Other", speakerIDs: ["mic:S1"],
                                              speechSeconds: 30, embedding: FloatVector([1, 0]), condition: .room,
                                              weak: false, addedAt: profileDate),
        ])]),
        SpeakerProfileDatabase(profiles: [SpeakerProfile(displayName: "Jim", samples: [profileSample()])]),
        // One embedding model, two people, vectors of different sizes: cosineDistance answers 2 for that pair,
        // which would quietly exclude them from every comparison instead of reporting the damage.
        SpeakerProfileDatabase(profiles: [
            SpeakerProfile(displayName: "Jim", embeddingModel: profileModel, samples: [profileSample()]),
            SpeakerProfile(displayName: "Maria", embeddingModel: profileModel, samples: [
                VoiceprintSample(sessionID: UUID().uuidString, sessionName: "Other", speakerIDs: ["mic:S1"],
                                 speechSeconds: 30, embedding: FloatVector([1, 0]), condition: .room, weak: false,
                                 addedAt: profileDate),
            ]),
        ]),
    ]
    for database in damaged {
        let data = try HolosJSON.encoder().encode(database)
        try AtomicFile.write(data, to: store.databaseURL)
        #expect(throws: HolosError.self) { try store.load() }
        // A no-op update reads through `load`, so it is refused too, and nothing is rewritten.
        #expect(throws: HolosError.self) { try store.update { _ in } }
        #expect(throws: HolosError.self) { try store.update { $0.rememberVoices = false } }
        #expect(try Data(contentsOf: store.databaseURL) == data)
    }
}

@Test func damagedCalibrationIsRefusedOnLoad() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    func thresholds(likely: Double = 0.2, margin: Double = 0.1, possible: Double = 0.4,
                    minimum: Double = 20) -> RecognitionThresholds {
        RecognitionThresholds(likelyMaxDistance: likely, likelyMinMargin: margin, possibleMaxDistance: possible,
                              minSampleSeconds: minimum)
    }
    // Valid, including a threshold just below 0 (calibration's "admit nothing"), and thresholds saved without a
    // model by an earlier build (loaded, never applied).
    for valid in [thresholds(), thresholds(likely: -Double.ulpOfOne, possible: -Double.ulpOfOne / 2)] {
        try store.update { $0.calibratedThresholds = valid; $0.calibratedModel = profileModel }
        #expect(try store.load().isCalibrated)
    }
    try store.update { $0.calibratedModel = nil }
    #expect(try !store.load().isCalibrated)

    // Out of range (a distance of 2 would admit zero-norm vectors), likely above possible, a negative margin or
    // minimum length, a margin over 2, and a model without thresholds.
    let damaged: [(RecognitionThresholds?, EmbeddingModelID?)] = [
        (thresholds(possible: 2), profileModel),
        (thresholds(likely: -1.5), profileModel),
        (thresholds(likely: 0.5, possible: 0.4), profileModel),
        (thresholds(margin: -0.1), profileModel),
        (thresholds(margin: 3), profileModel),
        (thresholds(minimum: -1), profileModel),
        (thresholds(likely: 1e300, possible: 1e300), profileModel),
        (nil, profileModel),
        (thresholds(), EmbeddingModelID(id: "", revision: "1")),
    ]
    for (value, model) in damaged {
        let database = SpeakerProfileDatabase(rememberVoices: true, calibratedThresholds: value,
                                              calibratedModel: model)
        let data = try HolosJSON.encoder().encode(database)
        try AtomicFile.write(data, to: store.databaseURL)
        #expect(throws: HolosError.self) { try store.load() }
        #expect(throws: HolosError.self) { try store.update { $0.rememberVoices = false } }
        #expect(try Data(contentsOf: store.databaseURL) == data)
    }
    // Every non-finite value is refused by the same rule (JSON cannot carry one, but a decoder might).
    for bad in [Double.nan, .infinity, -.infinity] {
        #expect(thresholds(likely: bad).problem != nil)
        #expect(thresholds(margin: bad).problem != nil)
        #expect(thresholds(possible: bad).problem != nil)
        #expect(thresholds(minimum: bad).problem != nil)
    }
    // A negative count of dropped turns is damage too.
    var sample = profileSample()
    sample.droppedOutlierTurns = -1
    let negative = SpeakerProfileDatabase(profiles: [SpeakerProfile(displayName: "Jim", embeddingModel: profileModel,
                                                                    samples: [sample])])
    try AtomicFile.write(try HolosJSON.encoder().encode(negative), to: store.databaseURL)
    #expect(throws: HolosError.self) { try store.load() }
}

@Test func calibrationIsResetInTheWriteThatChangesTheSamples() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    let thresholds = RecognitionThresholds(likelyMaxDistance: 0.2, likelyMinMargin: 0.1, possibleMaxDistance: 0.4,
                                           minSampleSeconds: 20)
    let jim = SpeakerProfile(id: "JIM", displayName: "Jim", embeddingModel: profileModel, samples: [profileSample()])
    // Samples and calibration saved together: the calibration is the write's own, so it stays.
    try store.update {
        $0.profiles = [jim]
        $0.calibratedThresholds = thresholds
        $0.calibratedModel = profileModel
    }
    #expect(try store.load().isCalibrated)

    // Names, settings, and people without samples are not part of the population.
    try store.update {
        $0.rememberVoices = true
        $0.profiles[0].displayName = "James"
        $0.profiles[0].recognitionEnabled = false
        $0.profiles.append(SpeakerProfile(id: "MARIA", displayName: "Maria"))
    }
    #expect(try store.load().isCalibrated)
    #expect(try store.load().calibrationResetAt == nil)

    // A sample added, changed, moved to another person, or removed, or a model change: reset in the same write.
    let recalibrate = { try store.update { $0.calibratedThresholds = thresholds; $0.calibratedModel = profileModel } }
    let changes: [(inout SpeakerProfileDatabase) -> Void] = [
        { $0.profiles[1].samples = [profileSample()]; $0.profiles[1].embeddingModel = profileModel },
        { $0.profiles[0].samples[0].embedding = FloatVector([0, 1, 0]) },
        { $0.profiles[0].samples += $0.profiles[1].samples; $0.profiles[1].samples = [] },
        { $0.profiles[0].samples.removeLast() },
        { $0.profiles[0].embeddingModel = EmbeddingModelID(id: "other", revision: "2") },
    ]
    for change in changes {
        try recalibrate()
        let before = try store.load()
        #expect(before.isCalibrated)
        try store.update(change)
        let after = try store.load()
        #expect(after.calibratedThresholds == nil)
        #expect(after.calibratedModel == nil)
        #expect(after.calibrationResetAt != nil)
    }

    // A store saved before `calibrationResetAt` existed still loads.
    let old = Data(#"{"schemaVersion": 1, "rememberVoices": true, "profiles": []}"#.utf8)
    try AtomicFile.write(old, to: store.databaseURL)
    #expect(try store.load().calibrationResetAt == nil)
}

@Test(.timeLimit(.minutes(1)))
func lockedReadHoldsTheLockUntilItsWriteIsDone() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    try store.update { $0.rememberVoices = true }
    let seen = try store.withLockedDatabase { database -> Bool in
        // Any store change waits for the locked read to finish (and gives up after 2 s).
        #expect(throws: HolosError.self) { try store.update { $0.rememberVoices = false } }
        return database.rememberVoices
    }
    #expect(seen)
    #expect(try store.load().rememberVoices, "Nothing is written by a locked read or the refused update.")
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

@Test func compactionKeepsLinesFromANewerHolos() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    let finished = ForgetRecord(kind: .sample, profileID: "JIM", sampleIDs: ["A"], sessionIDs: ["S"])
    try store.appendForgetRecord(finished)
    // A newer Holos's tombstones: a newer schema, and a kind this build does not know (its done line is readable).
    let newerSchema = Data(#"{"schemaVersion":2,"id":"NEWER","kind":"all","state":"pending"}"#.utf8)
    let newerKind = Data(#"{"schemaVersion":1,"id":"KIND","kind":"device","state":"pending"}"#.utf8)
    for line in [newerSchema, newerKind] { try AtomicFile.append(line + Data([0x0A]), to: store.forgetJournalURL) }
    try store.appendForgetRecord(.done(finished.id))
    // A torn tail; the next line starts on a line of its own.
    try AtomicFile.append(Data(#"{"schemaVersion":1,"id":"TORN""#.utf8), to: store.forgetJournalURL)
    let pending = ForgetRecord(kind: .profile, profileID: "SAM", sampleIDs: [], sessionIDs: [])
    try store.appendForgetRecord(pending)
    #expect(try store.pendingForgets() == [pending])

    try store.compactForgetJournal()
    let text = String(decoding: try Data(contentsOf: store.forgetJournalURL), as: UTF8.self)
    let lines = text.split(separator: "\n").map { Data($0.utf8) }
    #expect(lines == [newerSchema, newerKind, try HolosJSON.line(pending).dropLast()])
    #expect(try store.pendingForgets() == [pending])

    // Finishing this build's tombstone keeps the newer lines, and their done line.
    try store.appendForgetRecord(.done(pending.id))
    try store.appendForgetRecord(.done("KIND"))
    try store.compactForgetJournal()
    let after = String(decoding: try Data(contentsOf: store.forgetJournalURL), as: UTF8.self)
        .split(separator: "\n").map { Data($0.utf8) }
    #expect(after == [newerSchema, newerKind, try HolosJSON.line(ForgetRecord.done("KIND")).dropLast()])
}

@Test func supportRootHoldsTheSpeakersFolder() {
    #expect(HolosPaths.speakerProfiles == HolosPaths.supportRoot.appendingPathComponent("Speakers", isDirectory: true))
}


@Test func leftoverTemporaryFilesArePurgedFromTheStore() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    try store.update { $0.profiles = [SpeakerProfile(id: "JIM", displayName: "Jim")] }
    // What a kill between an atomic write's fsync and its rename leaves: a whole copy of the database beside it.
    let leftover = store.directory.appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
    try AtomicFile.write(Data("an older database, voiceprints and all".utf8), to: leftover)
    let unrelated = store.directory.appendingPathComponent("from-a-newer-holos.json", isDirectory: false)
    try AtomicFile.write(Data("{}".utf8), to: unrelated)

    #expect(try store.purgeTemporaryFiles() == 1)

    #expect(!FileManager.default.fileExists(atPath: leftover.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path), "Only atomic-write leftovers are removed.")
    #expect(FileManager.default.fileExists(atPath: store.databaseURL.path))
    #expect(try store.load().profiles.map(\.id) == ["JIM"])
    #expect(try store.purgeTemporaryFiles() == 0, "Nothing to do the second time.")
}

@Test func storedLinesSayWhichForgetsHaveHadTheirStoreWrite() throws {
    let root = try profileRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerProfileStore(directory: root.appendingPathComponent("Speakers"))
    let crashed = ForgetRecord(kind: .all, sampleIDs: ["S1"], turnRememberOff: true)
    let stored = ForgetRecord(kind: .sample, profileID: "JIM", sampleIDs: ["S2"])
    let finished = ForgetRecord(kind: .session, sampleIDs: ["S3"], sessionIDs: ["M1"])
    for record in [crashed, stored, finished] { try store.appendForgetRecord(record) }
    try store.appendForgetRecord(.stored(stored.id, profileID: "MARIA"))
    try store.appendForgetRecord(.stored(finished.id))
    try store.appendForgetRecord(.done(finished.id))

    #expect(try store.pendingForgets().map(\.id) == [crashed.id, stored.id], "A stored forget is still pending.")
    #expect(try store.storedForget(crashed.id) == nil, "Its store write is still owed.")
    #expect(try store.storedForget(stored.id)?.profileID == "MARIA", "The person its store write found.")
    #expect(try store.forgetRecords().first { $0.id == crashed.id }?.turnRememberOff == true)

    try store.compactForgetJournal()
    let kept = try store.forgetRecords()
    #expect(kept.filter { $0.id == finished.id }.isEmpty, "A finished forget and its stored line go together.")
    #expect(kept.filter { $0.id == stored.id && $0.state == ForgetRecord.stored }.count == 1,
            "The stored line of a pending forget is kept: it says its store write is done.")
    #expect(try store.pendingForgets().map(\.id) == [crashed.id, stored.id])
}
