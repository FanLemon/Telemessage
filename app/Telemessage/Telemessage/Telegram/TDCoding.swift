import Foundation

/// JSON conventions of the TDLib JSON interface.
///
/// - Keys are snake_case; Swift properties use camelCase with `ID`/`IDs` acronyms (`chat_id` ↔ `chatID`).
/// - Polymorphic objects carry their constructor name in `@type`; requests are correlated through `@extra`.
/// - `int53` values are JSON numbers, `int64` values are JSON strings (see `TDInt64`), `bytes` are base64.
nonisolated enum TDCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            AnyCodingKey(swiftKey(forJSONKey: path[path.count - 1].stringValue))
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            AnyCodingKey(jsonKey(forSwiftKey: path[path.count - 1].stringValue))
        }
        return encoder
    }()

    /// `last_read_inbox_message_id` → `lastReadInboxMessageID`; `@type` is left alone.
    static func swiftKey(forJSONKey key: String) -> String {
        guard !key.hasPrefix("@"), key.contains("_") else { return key }
        let parts = key.split(separator: "_", omittingEmptySubsequences: false)
        var result = String(parts[0])
        for part in parts.dropFirst() {
            switch part {
            case "id": result += "ID"
            case "ids": result += "IDs"
            default: result += part.prefix(1).uppercased() + part.dropFirst()
            }
        }
        return result
    }

    /// `messageIDs` → `message_ids`; `@type` is left alone.
    static func jsonKey(forSwiftKey key: String) -> String {
        guard !key.hasPrefix("@") else { return key }
        let normalized = key.replacingOccurrences(of: "IDs", with: "Ids").replacingOccurrences(of: "ID", with: "Id")
        var result = ""
        for character in normalized {
            if character.isUppercase {
                result += "_" + character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }
}

nonisolated struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// TDLib `int64`, transported as a JSON string to survive JavaScript-style number parsing.
nonisolated struct TDInt64: Codable, Hashable, Comparable, Sendable, ExpressibleByIntegerLiteral {
    var value: Int64

    init(_ value: Int64) { self.value = value }
    init(integerLiteral value: Int64) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self), let value = Int64(string) {
            self.value = value
        } else {
            value = try container.decode(Int64.self)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(value))
    }

    static func < (lhs: TDInt64, rhs: TDInt64) -> Bool { lhs.value < rhs.value }
}

/// Reads only the `@type` constructor name; used to dispatch polymorphic decoding.
nonisolated struct TDTypeTag: Decodable {
    let type: String

    enum CodingKeys: String, CodingKey {
        case type = "@type"
    }

    static func read(_ decoder: any Decoder) throws -> String {
        try TDTypeTag(from: decoder).type
    }
}

/// Encodes a payload with its `@type` constructor name, for polymorphic request arguments.
nonisolated struct TDTyped<Payload: Encodable & Sendable>: Encodable, Sendable {
    let type: String
    let payload: Payload

    init(_ type: String, _ payload: Payload) {
        self.type = type
        self.payload = payload
    }

    func encode(to encoder: any Encoder) throws {
        try payload.encode(to: encoder)
        var container = encoder.container(keyedBy: TDTypeTag.CodingKeys.self)
        try container.encode(type, forKey: .type)
    }
}

/// Payload for constructors without fields, e.g. `chatListMain`.
nonisolated struct TDEmpty: Codable, Sendable {}

nonisolated extension TDTyped where Payload == TDEmpty {
    init(_ type: String) { self.init(type, TDEmpty()) }
}
