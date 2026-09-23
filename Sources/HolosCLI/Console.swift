import Foundation
import HolosCore
import Synchronization

enum Console {
    private static let lock = Mutex(())
    static func output(_ text: String) { write(text + "\n", to: .standardOutput) }
    static func error(_ text: String) { write(text + "\n", to: .standardError) }
    private static func write(_ text: String, to handle: FileHandle) {
        lock.withLock { _ in try? handle.write(contentsOf: Data(text.utf8)) }
    }
    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        output(String(decoding: try encoder.encode(value), as: UTF8.self))
    }
    static func segment(_ segment: TranscriptSegment, track: String? = nil) {
        let seconds = Int(max(0, segment.start))
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        let source = track ?? segment.track
        output("[\(time)\(source.map { " \($0)" } ?? "")] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

func fileURL(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: [.withoutOverwriting])
}

func readText(arguments: [String]) throws -> String {
    if !arguments.isEmpty { return arguments.joined(separator: " ") }
    guard isatty(STDIN_FILENO) == 0 else { throw HolosError.invalidInput("Provide text as arguments or pipe it on stdin.") }
    let data = try FileHandle.standardInput.readToEnd() ?? Data()
    guard let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw HolosError.invalidInput("Input is empty or is not UTF-8 text.")
    }
    return text
}
