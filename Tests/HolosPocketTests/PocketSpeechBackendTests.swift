import Foundation
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosPocket

// A pack's models load once, even when two first uses come together (offline: the load is a fake).

@Suite(.timeLimit(.minutes(1))) struct PackLoadsTests {
    private final class Gate: Sendable {
        let loads = Mutex(0)
        let open = Mutex(false)
    }

    @Test func twoCallersDuringOneLoadShareIt() async throws {
        let loads = PackLoads<Int>()
        let gate = Gate()
        let load: @Sendable () async throws -> Int = {
            let count = gate.loads.withLock { value -> Int in
                value += 1
                return value
            }
            // Held until the test opens it (once the load has started; the suite's time limit bounds it).
            while !gate.open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            return count
        }
        async let first = loads.value(for: .english, load: load)
        async let second = loads.value(for: .english, load: load)
        #expect(await eventually { gate.loads.withLock { $0 } == 1 })
        gate.open.withLock { $0 = true }
        let values = try await [first, second]
        #expect(values == [1, 1])
        #expect(gate.loads.withLock { $0 } == 1)
        // Kept once loaded.
        #expect(try await loads.value(for: .english, load: load) == 1)
        // Another pack loads on its own.
        #expect(try await loads.value(for: .french, load: load) == 2)
    }

    @Test func aFailedLoadIsTriedAgain() async throws {
        let loads = PackLoads<Int>()
        let calls = Mutex(0)
        let load: @Sendable () async throws -> Int = {
            let call = calls.withLock { value -> Int in
                value += 1
                return value
            }
            if call == 1 { throw CancellationError() }
            return call
        }
        await #expect(throws: CancellationError.self) { _ = try await loads.value(for: .english, load: load) }
        #expect(try await loads.value(for: .english, load: load) == 2)
    }
}

// The pinned listing is read to its end, or fails: a partial one would let missing files pass.

@Suite struct PocketListingTests {
    private func page(_ url: URL, next: URL?) -> (Data, URLResponse) {
        let body = Data(#"[{"type":"file","oid":"a","size":1,"path":"v2.1/english/a.bin"}]"#.utf8)
        let headers = next.map { ["Link": "<\($0.absoluteString)>; rel=\"next\""] } ?? [:]
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
    }

    @Test func aListingThatEndsIsRead() async throws {
        let second = URL(string: "https://example.invalid/page2")!
        let files = try await PocketSpeechBackend.listing("v2.1/english") { url in
            page(url, next: url == second ? nil : second)
        }
        #expect(files.count == 2)
    }

    @Test func aListingThatLinksInACircleOrPastTheCapFails() async throws {
        let loop = URL(string: "https://example.invalid/loop")!
        await #expect(throws: HolosError.self) {
            _ = try await PocketSpeechBackend.listing("v2.1/english") { url in page(url, next: loop) }
        }
        let count = Mutex(0)
        await #expect(throws: HolosError.self) {
            _ = try await PocketSpeechBackend.listing("v2.1/english") { url in
                let n = count.withLock { value -> Int in
                    value += 1
                    return value
                }
                return page(url, next: URL(string: "https://example.invalid/page\(n)")!)
            }
        }
        #expect(count.withLock { $0 } == PocketSpeechBackend.maximumPages)
    }
}

// FluidAudio's quiet lines, which carry the text it speaks, never reach stderr; everything else does.

@Suite struct FluidAudioLogFilterTests {
    @Test func quietFluidAudioLinesAreDroppedAndTheRestKept() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("holos-log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        let filter = try #require(FluidAudioLogFilter.install(on: descriptor))
        let lines = [
            "[19:20:09.487] [INFO] [FluidAudio.PocketTtsSession] Session chunk 0: 'The keeper hid the key.'\n",
            "Paragraph 2 is read by Ava: it was heard wrong.\n",
            "[19:20:09.500] [DEBUG] [FluidAudio.PocketTtsSynthesizer] synthesizing 'The keeper hid the key.'\n",
            "[19:20:09.600] [WARN] [FluidAudio.PocketTtsModelStore] A model was compiled again.\n",
            "Error: The voice broke.",
        ]
        for line in lines { _ = line.withCString { write(descriptor, $0, strlen($0)) } }
        filter.finish()
        filter.finish()
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(!written.contains("The keeper hid the key."))
        #expect(written == lines[1] + lines[3] + lines[4])
        // The descriptor writes to the file again.
        _ = "after\n".withCString { write(descriptor, $0, strlen($0)) }
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("after\n"))
    }
}

