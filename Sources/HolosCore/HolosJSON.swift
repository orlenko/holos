import Foundation

/// JSON conventions shared by every Holos file: ISO 8601 dates, sorted keys, unescaped slashes.
/// Whole files are pretty-printed; journal lines are compact and end with a newline.
/// Decoders ignore unknown keys, so a newer writer may add optional fields within a schema version.
/// Dates have one-second precision: never order records by a date (use sequence numbers or pointers).
public enum HolosJSON {
    /// Encoder for whole files (`pretty == true`) or single journal lines (`pretty == false`).
    public static func encoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decoder matching `encoder(pretty:)`.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes `value` as one compact JSON object followed by "\n", for append-only journals.
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder(pretty: false).encode(value)
        data.append(0x0A)
        return data
    }
}

/// A string code that tolerates values written by a newer Holos: it is encoded as a bare JSON string,
/// and any string decodes (compare with the type's static constants; unknown values compare unequal).
public protocol OpenStringCode: RawRepresentable, Codable, Sendable, Hashable where RawValue == String {
    init(rawValue: String)
}

extension OpenStringCode {
    public init(_ rawValue: String) { self.init(rawValue: rawValue) }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
