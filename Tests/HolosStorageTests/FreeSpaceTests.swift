import Foundation
import Testing
import HolosCore
@testable import HolosStorage

@Test func fixedFreeSpaceReturnsItsValue() throws {
    let provider: any FreeSpaceProvider = FixedFreeSpace(500_000_000)
    #expect(try provider.availableBytes(at: URL(fileURLWithPath: "/nonexistent")) == 500_000_000)
    #expect(try FixedFreeSpace(.max).availableBytes(at: FileManager.default.temporaryDirectory) == .max)
}

@Test func volumeFreeSpaceMeasuresTheNearestExistingFolder() throws {
    let provider = VolumeFreeSpace()
    let temporary = FileManager.default.temporaryDirectory
    let existing = try provider.availableBytes(at: temporary)
    #expect(existing > 0)
    // A sessions folder that does not exist yet is measured on its volume.
    let missing = temporary.appendingPathComponent("holos-free-\(UUID().uuidString)/Sessions/x.holos")
    #expect(try provider.availableBytes(at: missing) > 0)
    #expect(!FileManager.default.fileExists(atPath: missing.path))
    #expect(throws: HolosError.self) { try provider.availableBytes(at: URL(string: "https://example.com")!) }
}
