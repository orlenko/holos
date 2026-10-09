import Foundation

/// A new folder `FileManager.default.temporaryDirectory/holos-<area>-<UUID>`. Remove it with
/// `defer { temp.remove() }`, or remove `url` yourself.
public struct TemporaryDirectory: Sendable {
    public let url: URL

    /// `permissions` nil makes the folder as any new folder is made (the process's umask), so a test of code that
    /// makes its folders private is not passed by the fixture; pass 0o700 for a private one.
    public init(_ area: String = "test", permissions: Int? = nil) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("holos-\(area)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: permissions.map { [.posixPermissions: $0] })
    }

    public func remove() { try? FileManager.default.removeItem(at: url) }
}
