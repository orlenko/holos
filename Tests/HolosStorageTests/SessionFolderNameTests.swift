import Foundation
import Testing
import HolosCore
import HolosStorage
import HolosTestSupport
import HolosSessionTestSupport

private let uuid = "3F2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10"

@Test func aSessionFolderIsNamedAfterItsID() {
    #expect(SessionPaths.folderName(for: uuid) == "\(uuid).holos")
    let root = URL(fileURLWithPath: "/data/Sessions", isDirectory: true)
    let folder = SessionPaths.folder(for: uuid, in: root)
    #expect(folder.path == "/data/Sessions/\(uuid).holos")
    #expect(folder.hasDirectoryPath)
    #expect(SessionPaths.parse(folderName: folder.lastPathComponent) == uuid)
}

@Test func onlyAnUppercaseUUIDFolderNameParses() {
    #expect(SessionPaths.parse(folderName: "\(uuid).holos") == uuid)
    let rejected = [
        "\(uuid.lowercased()).holos",                 // UUID() never writes lowercase; readManifest refuses it
        "3f2A9C1E-7B4D-4E21-9A55-0C8D1B6F2E10.holos", // mixed case
        "{\(uuid)}.holos", "\(uuid.replacingOccurrences(of: "-", with: "")).holos",
        uuid, "\(uuid).HOLOS", "\(uuid).holos/", "\(uuid).holos.holos", "\(uuid).json",
        ".\(uuid).holos", "\(uuid) .holos", " \(uuid).holos", "\(uuid).holos ", "x.\(uuid).holos",
        "\(uuid).\(uuid).holos", "Budget review.holos", "a.holos", "..holos", ".holos", "holos", "",
        "\(uuid.dropLast()).holos", "\(uuid)0.holos", "\(uuid.dropLast())G.holos",
    ]
    for name in rejected {
        #expect(SessionPaths.parse(folderName: name) == nil, "\(name)")
    }
}

@Test func anyNameEndingInHolosIsASessionFolderButListingsSkipHiddenOnes() {
    let sessionFolders = ["\(uuid).holos", "Budget review.holos", "a.holos", "a.b.holos", "..holos", ".a.holos",
                          "\(uuid).holos.holos"]
    for name in sessionFolders {
        #expect(SessionPaths.isSessionFolderName(name), "\(name)")
    }
    for name in [".holos", "holos", "", "a.HOLOS", "a.holos ", "a.holosx", uuid] {
        #expect(!SessionPaths.isSessionFolderName(name), "\(name)")
        #expect(!SessionPaths.isListedSessionFolderName(name), "\(name)")
    }
    #expect(SessionPaths.isListedSessionFolderName("Budget review.holos"))
    #expect(!SessionPaths.isListedSessionFolderName(".a.holos"))
    #expect(!SessionPaths.isListedSessionFolderName("..holos"))
}

@Test func aFolderStemIsItsNameWithoutHolos() {
    #expect(SessionPaths.stem(ofFolderName: "\(uuid).holos") == uuid)
    #expect(SessionPaths.stem(ofFolderName: "Budget review.holos") == "Budget review")
    #expect(SessionPaths.stem(ofFolderName: "a.b.holos") == "a.b")
    #expect(SessionPaths.stem(ofFolderName: ".holos") == "")
    #expect(SessionPaths.stem(ofFolderName: "folder") == "folder")
}

/// Every folder Holos makes parses back to its session's ID: a new recording's, one with a given ID, and the
/// manifest check accepts exactly that name.
@Test func everyCreatedSessionFolderParsesToItsID() async throws {
    let temp = try TemporaryDirectory("folder-names")
    defer { temp.remove() }
    for _ in 0..<3 {
        let (session, id) = try await SessionFixtureBuilder().finished(in: temp.url)
        #expect(SessionPaths.parse(folderName: session.lastPathComponent) == id)
        #expect(try SessionArchive.readManifest(at: session).id == id)
    }
    let given = UUID().uuidString
    let archive = try SessionArchive.create(root: temp.url, name: "Given", source: .microphone, locale: "en-CA",
                                            backend: .speech, id: given)
    #expect(SessionPaths.parse(folderName: archive.directory.lastPathComponent) == given)
    #expect(throws: HolosError.self) {
        try SessionArchive.create(root: temp.url, name: "Lower", source: .microphone, locale: "en-CA",
                                  backend: .speech, id: UUID().uuidString.lowercased())
    }
}
