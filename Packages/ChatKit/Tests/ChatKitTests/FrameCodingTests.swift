import Foundation
import Testing
@testable import ChatKit

/// `ChatEvent` and `ChatCommand` are the wire format, not merely types that
/// happen to be `Codable`: a bridge server's protocol is literally these frames
/// encoded down and up. So every case is pinned to a golden file, and the
/// fixtures promise one sample per case. This suite is what makes that promise
/// enforceable — without it, `Fixture.events` is a list nothing reads.
@Suite("Frame coding")
struct FrameCodingTests {
    // MARK: - Goldens

    /// Golden, round-trip and re-encode stability for every event case. See
    /// `expectWireStable` for the three properties being asserted.
    @Test("every event matches its golden file and round-trips unchanged", arguments: Fixture.events)
    func events(_ sample: Sample<ChatEvent>) throws {
        try expectWireStable(sample.value, golden: sample.name)
    }

    @Test(
        "every command matches its golden file and round-trips unchanged",
        arguments: Fixture.commands
    )
    func commands(_ sample: Sample<ChatCommand>) throws {
        try expectWireStable(sample.value, golden: sample.name)
    }

    /// Pinned separately from the events that carry them, because all three are
    /// payloads a backend can produce on their own and a bridge server has to
    /// re-frame verbatim.
    @Test("every error matches its golden file and round-trips unchanged", arguments: Fixture.errors)
    func errors(_ sample: Sample<ChatError>) throws {
        try expectWireStable(sample.value, golden: sample.name)
    }

    @Test(
        "every connection state matches its golden file and round-trips unchanged",
        arguments: Fixture.connectionStates
    )
    func connectionStates(_ sample: Sample<ConnectionState>) throws {
        try expectWireStable(sample.value, golden: sample.name)
    }

    @Test("every gap scope matches its golden file and round-trips unchanged", arguments: Fixture.gapScopes)
    func gapScopes(_ sample: Sample<GapScope>) throws {
        try expectWireStable(sample.value, golden: sample.name)
    }

    // MARK: - Coverage

    /// The guard the fixtures' doc comment claims exists.
    ///
    /// These lists are written out by hand rather than derived from the `Tag`
    /// enums, and that is deliberate: deriving them would make this test pass
    /// automatically the moment a case is added, which is the one moment it
    /// needs to fail. Adding a case to `ChatEvent` means adding its tag here
    /// and a sample to `Fixture`, and the compiler's exhaustive switch in the
    /// encoder means nobody can add one without noticing.
    @Test("the samples cover every event case, so no case ships untested")
    func eventCoverage() throws {
        let expected: Set = [
            "connectionStateChanged",
            "selfIdentified",
            "conversationsChanged",
            "conversationUpdated",
            "messageReceived",
            "messageUpdated",
            "messageDeleted",
            "reactionChanged",
            "typingChanged",
            "readStateChanged",
            "membersChanged",
            "presenceChanged",
            "gap",
            "backendError",
            "somethingNewer" // the `.unknown` sample keeps its own discriminator
        ]
        #expect(try Set(Fixture.events.map { try discriminator(of: $0.value) }) == expected)
        #expect(Fixture.events.count == expected.count, "two samples share a discriminator")
    }

    @Test("the samples cover every command case, so no case ships untested")
    func commandCoverage() throws {
        let expected: Set = [
            "sendMessage",
            "editMessage",
            "deleteMessage",
            "setReaction",
            "setTyping",
            "markRead",
            "setNotificationLevel",
            "somethingNewer"
        ]
        #expect(try Set(Fixture.commands.map { try discriminator(of: $0.value) }) == expected)
    }

    @Test("the samples cover every error case")
    func errorCoverage() throws {
        let expected: Set = [
            "notAuthenticated",
            "sessionExpired",
            "rateLimited",
            "unsupported",
            "transport",
            "decoding",
            "server",
            "unknown"
        ]
        #expect(try Set(Fixture.errors.map { try discriminator(of: $0.value) }) == expected)
    }

    // MARK: - Frame shape

    /// The difference between this protocol and Swift's synthesised enum
    /// encoding, stated as an assertion. Synthesis nests the payload under a key
    /// named after the case and writes no discriminator at all; every frame here
    /// carries `"type"` at the top level with its payload flat beside it, which
    /// is what lets a reader — or a server in another language — dispatch on one
    /// well-known key.
    @Test("every event frame is a flat object with a top-level type", arguments: Fixture.events)
    func eventFrameShape(_ sample: Sample<ChatEvent>) throws {
        let fields = try object(of: sample.value)
        #expect(fields[UnknownFrame.typeKey] != nil, "\(sample.name) has no discriminator")
        if case .string = fields[UnknownFrame.typeKey] {} else {
            Issue.record("\(sample.name): discriminator is not a string")
        }
    }

    @Test("every command frame is a flat object with a top-level type", arguments: Fixture.commands)
    func commandFrameShape(_ sample: Sample<ChatCommand>) throws {
        let fields = try object(of: sample.value)
        #expect(fields[UnknownFrame.typeKey] != nil, "\(sample.name) has no discriminator")
    }

    // MARK: - Helpers

    /// A frame that is not a JSON object, or carries no string discriminator,
    /// is a failure of the format rather than of one assertion — so it throws
    /// and names itself.
    struct MalformedFrame: Error, CustomStringConvertible {
        let reason: String
        var description: String {
            "malformed frame: \(reason)"
        }
    }

    /// Re-reads an encoded frame as plain JSON, so assertions are about the
    /// bytes rather than about the Swift value that produced them.
    private func object(of value: some Encodable) throws -> [String: JSONValue] {
        let parsed = try Wire.decode(JSONValue.self, from: Wire.json(value))
        guard case let .object(fields) = parsed else {
            throw MalformedFrame(reason: "top level is not an object")
        }
        return fields
    }

    private func discriminator(of value: some Encodable) throws -> String {
        guard case let .string(type) = try object(of: value)[UnknownFrame.typeKey] else {
            throw MalformedFrame(reason: "no string discriminator")
        }
        return type
    }
}
