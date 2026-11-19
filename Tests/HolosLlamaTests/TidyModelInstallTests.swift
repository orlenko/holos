import CryptoKit
import Foundation
@testable import HolosCore
@testable import HolosLlama
import Testing

/// The offsets a fake fetch was asked for.
final class Offsets: @unchecked Sendable {
    // @unchecked Sendable: only touched under `lock`.
    private let lock = NSLock()
    private var list: [Int64] = []
    func append(_ offset: Int64) { lock.withLock { list.append(offset) } }
    var all: [Int64] { lock.withLock { list } }
}

/// Installs a small stand-in model file into a temporary folder; nothing touches the network or the real folder.
struct TidyModelInstallTests {
    let content = Data((0 ..< 10_000).map { UInt8($0 % 251) })
    var pin: TidyModelInstall.Pin {
        .init(size: Int64(content.count), sha256: SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined())
    }

    func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidy-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A fetch that serves `content` from the asked offset (refusing any offset but 0, having written nothing, when
    /// `honoursRange` is false, as the real one does), and stops after `limit` bytes when given (a dropped connection).
    func fetch(_ content: Data, honoursRange: Bool = true, limit: Int? = nil,
               offsets: Offsets? = nil) -> TidyModelInstall.Fetch {
        { offset, write in
            offsets?.append(offset)
            guard honoursRange || offset == 0 else { return false }
            var body = content.dropFirst(Int(offset))
            if let limit { body = body.prefix(limit) }
            try write(Data(body))
            return true
        }
    }

    @Test func aDownloadThatStopsResumesFromWhereItStopped() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: HolosError.self) {
            try await TidyModelInstall.setUp(force: false, source: nil, root: root, pin: pin,
                                             fetch: fetch(content, limit: 4000), notice: { _ in }, progress: { _ in })
        }
        #expect(TidyModel.status(root: root) == .notInstalled)
        let offsets = Offsets()
        try await TidyModelInstall.setUp(force: false, source: nil, root: root, pin: pin,
                                         fetch: fetch(content, offsets: offsets), notice: { _ in }, progress: { _ in })
        #expect(offsets.all == [4000])
        #expect(try Data(contentsOf: TidyModel.file(root: root)) == content)
        #expect(!FileManager.default.fileExists(atPath: TidyModel.partialFile(root: root).path))
    }

    @Test func aDamagedDownloadIsDeletedAndNotInstalled() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var damaged = content
        damaged[5] ^= 0xFF
        await #expect(throws: HolosError.self) {
            try await TidyModelInstall.setUp(force: false, source: nil, root: root, pin: pin, fetch: fetch(damaged),
                                             notice: { _ in }, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: TidyModel.file(root: root).path))
        #expect(!FileManager.default.fileExists(atPath: TidyModel.partialFile(root: root).path))
    }

    @Test func aServerThatCannotResumeStartsAgainFromTheFirstByte() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try content.prefix(3000).write(to: TidyModel.partialFile(root: root))
        let offsets = Offsets()
        try await TidyModelInstall.setUp(force: false, source: nil, root: root, pin: pin,
                                         fetch: fetch(content, honoursRange: false, offsets: offsets),
                                         notice: { _ in }, progress: { _ in })
        #expect(offsets.all == [3000, 0])
        #expect(try Data(contentsOf: TidyModel.file(root: root)) == content)
    }

    @Test func aDownloadStoppedWhileCheckingIsCheckedWithoutFetchingAgain() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try content.write(to: TidyModel.partialFile(root: root))
        try await TidyModelInstall.setUp(force: false, source: nil, root: root, pin: pin,
                                         fetch: { _, _ in Issue.record("no download"); return true },
                                         notice: { _ in }, progress: { _ in })
        #expect(try Data(contentsOf: TidyModel.file(root: root)) == content)
    }

    @Test func aFileAlreadyOnTheMacIsCopiedOnlyWhenItIsTheModel() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("elsewhere.gguf")
        var other = content
        other[0] ^= 0xFF
        try other.write(to: source)
        try content.prefix(10).write(to: TidyModel.partialFile(root: root))
        await #expect(throws: HolosError.self) {
            try await TidyModelInstall.setUp(force: false, source: source, root: root, pin: pin,
                                             fetch: { _, _ in Issue.record("no download"); return true },
                                             notice: { _ in }, progress: { _ in })
        }
        #expect(TidyModel.status(root: root) == .notInstalled)
        #expect(FileManager.default.fileExists(atPath: source.path), "the person's own file is never deleted")
        #expect(FileManager.default.fileExists(atPath: TidyModel.partialFile(root: root).path),
                "an unfinished download is kept")

        try content.write(to: source)
        let link = root.appendingPathComponent("link.gguf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        try await TidyModelInstall.setUp(force: false, source: link, root: root, pin: pin,
                                         fetch: { _, _ in Issue.record("no download"); return true },
                                         notice: { _ in }, progress: { _ in })
        #expect(try Data(contentsOf: TidyModel.file(root: root)) == content)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func removeDeletesTheModelAndAnUnfinishedDownload() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try content.write(to: TidyModel.file(root: root))
        try content.prefix(10).write(to: TidyModel.partialFile(root: root))
        try TidyModelInstall.remove(root: root)
        #expect(!FileManager.default.fileExists(atPath: TidyModel.file(root: root).path))
        #expect(!FileManager.default.fileExists(atPath: TidyModel.partialFile(root: root).path))
    }

    @Test func theChatTurnsThinkingOff() {
        let chat = QwenTidy.chat(instructions: "Edit.", prompt: "Text:\nhi")
        #expect(chat.before + chat.content + chat.after
            == "<|im_start|>system\nEdit.<|im_end|>\n<|im_start|>user\nText:\nhi<|im_end|>\n"
            + "<|im_start|>assistant\n<think>\n\n</think>\n\n")
        #expect(chat.content == "Text:\nhi")
    }

    /// The real model on a short text; runs only with HOLOS_TIDY_GGUF set to its file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_TIDY_GGUF"] != nil))
    func qwenTidiesAPauseSplitSentence() async throws {
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOLOS_TIDY_GGUF"]!)
        let result = try await QwenTidy.tidier(model: LlamaModel(file: file))
            .tidy("I went to the store. And bought some. Milk and eggs.")
        #expect(result.parts.allSatisfy { $0.kept == nil })
        #expect(result.text.contains("milk") || result.text.contains("Milk"))
    }

    @Test func aFileInTheModelsOwnFolderIsNotCopiedOverItself() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try content.write(to: TidyModel.partialFile(root: root))
        await #expect(throws: HolosError.self) {
            try await TidyModelInstall.setUp(force: false, source: TidyModel.partialFile(root: root), root: root,
                                             pin: pin, fetch: { _, _ in true }, notice: { _ in }, progress: { _ in })
        }
        #expect(try Data(contentsOf: TidyModel.partialFile(root: root)) == content)
    }

    /// Hugging Face honours a resume through its redirect; runs only with HOLOS_TIDY_NETWORK=1 and HOLOS_TIDY_GGUF
    /// (the model file, whose last bytes the fetched ones must match).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HOLOS_TIDY_NETWORK"] == "1"
        && ProcessInfo.processInfo.environment["HOLOS_TIDY_GGUF"] != nil))
    func huggingFaceSendsTheRestOfTheFileFromAnOffset() async throws {
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOLOS_TIDY_GGUF"]!)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(TidyModel.size - 1000))
        let expected = try handle.readToEnd()
        nonisolated(unsafe) var bytes = Data()
        let resumed = try await TidyModelInstall.huggingFace(TidyModel.size - 1000) { bytes.append($0) }
        #expect(resumed)
        #expect(bytes == expected)
    }
}
