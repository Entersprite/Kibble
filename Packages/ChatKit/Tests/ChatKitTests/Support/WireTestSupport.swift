import Foundation
import Testing
@testable import ChatKit

/// The one canonical way this package's JSON is produced in tests.
///
/// `sortedKeys` is what makes byte-comparison meaningful at all: without it,
/// dictionary ordering would make every golden comparison a coin toss.
/// `withoutEscapingSlashes` is for the humans reading the goldens — a URL
/// spelled `https:\/\/example.com` is noise.
///
/// Output is compact rather than pretty-printed on purpose. Pretty printing
/// puts whitespace decisions inside the bytes under test, and Foundation has
/// changed its mind about the space before a colon before now.
enum Wire {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func json(_ value: some Encodable) throws -> String {
        try String(decoding: encoder().encode(value), as: UTF8.self)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from json: String) throws -> Value {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

/// Reads the golden files.
///
/// Files live in `Tests/ChatKitTests/Golden` and are declared as resources, so
/// assertions read them out of the test bundle. Regeneration writes to the
/// source tree instead — run
/// `CHATKIT_UPDATE_GOLDEN=1 swift test`, then run `swift test` again to verify
/// what was written. The second run is not optional: in the updating run the
/// bundle still holds the previous copies, so nothing is being checked.
enum Golden {
    static let sourceDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Golden")

    static var isUpdating: Bool {
        ProcessInfo.processInfo.environment["CHATKIT_UPDATE_GOLDEN"] == "1"
    }

    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String {
            "no golden file named \(name).json — run CHATKIT_UPDATE_GOLDEN=1 swift test"
        }
    }

    static func load(_ name: String) throws -> String {
        guard
            let url = Bundle.module.url(
                forResource: name, withExtension: "json", subdirectory: "Golden"
            )
        else { throw Missing(name: name) }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ json: String, to name: String) throws {
        try FileManager.default.createDirectory(
            at: sourceDirectory, withIntermediateDirectories: true
        )
        try (json + "\n").write(
            to: sourceDirectory.appendingPathComponent("\(name).json"),
            atomically: true,
            encoding: .utf8
        )
    }
}

/// The three properties that make this a wire format rather than a
/// serialisation:
///
/// 1. the encoder's output is exactly what the golden file says, so a renamed
///    case or key shows up as a diff in a file a human reviews;
/// 2. decoding that output reproduces the value, which is what catches a field
///    dropped from a hand-written coder;
/// 3. re-encoding is byte-identical, so a value can cross the wire any number
///    of times without drifting.
func expectWireStable<Value: Codable & Equatable>(
    _ value: Value,
    golden name: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let encoded = try Wire.json(value)
    let decoded = try Wire.decode(Value.self, from: encoded)
    #expect(decoded == value, "\(name): decoding did not reproduce the value", sourceLocation: sourceLocation)
    let reencoded = try Wire.json(decoded)
    #expect(
        reencoded == encoded,
        "\(name): re-encoding is not byte-identical",
        sourceLocation: sourceLocation
    )

    if Golden.isUpdating {
        try Golden.write(encoded, to: name)
    } else {
        let expected = try Golden.load(name)
        #expect(
            encoded == expected,
            "\(name): encoder disagrees with the golden file",
            sourceLocation: sourceLocation
        )
    }
}

/// A named value, so a parameterised test reports which case failed rather than
/// dumping a whole event into the test name.
struct Sample<Value: Sendable>: Sendable, CustomStringConvertible {
    let name: String
    let value: Value

    init(_ name: String, _ value: Value) {
        self.name = name
        self.value = value
    }

    var description: String {
        name
    }
}

/// Wraps a value in an object.
///
/// Every identifier and every open enum in this package encodes as a *bare*
/// JSON string, and a bare string is not reliably a decodable top-level JSON
/// document. Boxing puts it where it actually lives on the wire — as one value
/// inside an object — and keeps the assertion about the string itself.
struct Box<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
