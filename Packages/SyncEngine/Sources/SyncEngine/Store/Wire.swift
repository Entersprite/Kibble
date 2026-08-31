import ChatKit
import Foundation

/// How a ChatKit value becomes a column and back.
///
/// Two shapes, because ChatKit's types encode as two shapes. `Conversation.Kind`
/// and `Presence` encode as a bare JSON string, and storing `"space"` complete
/// with quotes would make the database miserable to read in `sqlite3`.
/// `ConnectionState` and `ChatError` encode as objects, which are stored as
/// JSON text.
///
/// Both go through the model's own `Codable`, which is what preserves an open
/// enum's `.unknown(raw)` case: a conversation kind this build has never seen
/// comes back out exactly as it went in, rather than being flattened to
/// something this build does understand.
enum Wire {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// For values that encode as a JSON object or array.
    static func json(_ value: some Encodable) throws -> String {
        try String(decoding: encoder.encode(value), as: UTF8.self)
    }

    static func value<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    /// For values that encode as a bare JSON string - stored unquoted.
    static func string(_ value: some Encodable) throws -> String {
        try decoder.decode(String.self, from: encoder.encode(value))
    }

    static func fromString<T: Decodable>(_ type: T.Type, _ raw: String) throws -> T {
        try decoder.decode(type, from: encoder.encode(raw))
    }
}
