import ChatKit
import Foundation

/// The same serialization is used by embedded transport and remote adapters.
public enum ServiceCodec {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            guard date.timeIntervalSince1970.isFinite else {
                throw EncodingError.invalidValue(date, .init(
                    codingPath: encoder.codingPath, debugDescription: "Invalid timestamp"
                ))
            }
            var container = encoder.singleValueContainer()
            try container.encode(RFC3339.string(from: date))
        }
        return try encoder.encode(value)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = RFC3339.date(from: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid timestamp")
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }

    public static func value(_ value: some Encodable) throws -> JSONValue {
        try decode(JSONValue.self, from: encode(value))
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from value: JSONValue) throws -> Value {
        try decode(type, from: encode(value))
    }
}
