import Foundation
import HolosCore
import HolosSynthesis
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
            while !gate.open.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            return count
        }
        async let first = loads.value(for: .english, load: load)
        async let second = loads.value(for: .english, load: load)
        for _ in 0..<1_000 where gate.loads.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
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
