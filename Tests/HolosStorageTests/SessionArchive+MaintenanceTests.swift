import Foundation
import Testing
import HolosCore
@testable import HolosStorage
import HolosTestSupport
import HolosSessionTestSupport

private let maintenanceSession = SessionFixtureBuilder(name: "Maintenance")

private struct BodyFailure: Error, Equatable {}

@Test func maintenanceArchiveIsReleasedAfterTheBodyReturns() async throws {
    let root = try TemporaryDirectory("maintenance").url
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await maintenanceSession.finished(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let value = try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { archive in
        #expect(try SessionArchive.isActive(at: session))
        try await archive.recordEvent(kind: "maintenance.test", details: [:])
        return 7
    }
    #expect(value == 7)
    #expect(try !SessionArchive.isActive(at: session))
    #expect(try SessionArchive.readEvents(at: session).events.last?.kind == "maintenance.test")
}

@Test func maintenanceArchiveIsReleasedWhenTheBodyThrows() async throws {
    let root = try TemporaryDirectory("maintenance").url
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await maintenanceSession.finished(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    await #expect(throws: BodyFailure.self) {
        try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { _ in
            #expect(try SessionArchive.isActive(at: session))
            throw BodyFailure()
        }
    }
    #expect(try !SessionArchive.isActive(at: session))
}

@Test(.timeLimit(.minutes(1))) func maintenanceArchiveIsReleasedWhenTheBodyIsCancelled() async throws {
    let root = try TemporaryDirectory("maintenance").url
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await maintenanceSession.finished(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
    // Never yields: the body's iteration ends when its task is cancelled.
    let (gate, gateContinuation) = AsyncStream<Void>.makeStream()
    defer { gateContinuation.finish() }
    let task = Task {
        try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { _ in
            enteredContinuation.yield()
            for await _ in gate {}
            try Task.checkCancellation()
        }
    }
    for await _ in entered { break }
    #expect(try SessionArchive.isActive(at: session))
    task.cancel()
    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(try !SessionArchive.isActive(at: session))
}

/// The release at the end of the scope does nothing to a lock the archive no longer holds: a body that let it go and
/// opened the archive again leaves the second holder's lock held past the end of the scope.
@Test func maintenanceArchiveScopeEndLeavesAnotherHoldersLock() async throws {
    let root = try TemporaryDirectory("maintenance").url
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await maintenanceSession.finished(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    defer { lease.release() }
    let second = try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { archive in
        await archive.releaseLock()
        #expect(try !SessionArchive.isActive(at: session))
        return try SessionArchive.openForMaintenance(at: session, lease: lease)
    }
    #expect(try SessionArchive.isActive(at: session))
    await second.releaseLock()
    #expect(try !SessionArchive.isActive(at: session))
}

@Test func maintenanceArchiveRunsNothingWhenItCannotOpen() async throws {
    let root = try TemporaryDirectory("maintenance").url
    defer { try? FileManager.default.removeItem(at: root) }
    let session = try await maintenanceSession.finished(in: root).session
    let lease = try SessionArchive.acquireProcessingLease(at: session)
    lease.release()
    let error = await #expect(throws: HolosError.self) {
        try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { _ in
            Issue.record("The body ran without the archive open.")
        }
    }
    #expect(isInvalidInput(error))
    #expect(try !SessionArchive.isActive(at: session))
}
