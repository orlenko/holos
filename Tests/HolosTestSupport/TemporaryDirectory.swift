import Foundation

/// A private folder `FileManager.default.temporaryDirectory/holos-<area>-<UUID>`. Remove it with
/// `defer { temp.remove() }`, or remove `url` yourself.
public struct TemporaryDirectory: Sendable {
    public let url: URL

    public init(_ area: String = "test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-\(area)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}
