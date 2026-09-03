import Foundation
import Testing
@testable import ChatKit

/// The rule this suite defends is the one with the highest cost of being wrong:
///
/// > An unknown discriminator decodes to `.unknown` and never throws, and
/// > re-encodes verbatim.
///
/// Without it, deploying a bridge server that emits one new event type bricks
/// every client built before it — not degrades, bricks, because a frame that
/// throws during decode takes the stream with it. The verbatim half matters
/// because a client may be relaying frames it does not understand.
@Suite("Forward compatibility")
struct ForwardCompatibilityTests {
    /// A frame from a newer backend: an unheard-of type, carrying fields this
    /// build has no properties for, including nested ones.
    static let futureFrame = #"""
    {"type":"quantumEntangled","conversationID":"space:1","depth":3,"nested":{"a":[1,null,true]}}
    """#

    // MARK: - Events

    @Test("an unrecognised event type decodes rather than throwing")
    func unknownEventDoesNotThrow() throws {
        let event = try Wire.decode(ChatEvent.self, from: Self.futureFrame)
        guard case let .unknown(type, _) = event else {
            Issue.record("expected .unknown, got \(event)")
            return
        }
        #expect(type == "quantumEntangled")
    }

    /// Byte-level equality is the wrong assertion here — key order is the
    /// encoder's business — so both sides are compared as parsed JSON, which is
    /// what "verbatim" actually means for a JSON object.
    @Test("an unrecognised event re-encodes with every field it arrived with")
    func unknownEventReEncodesVerbatim() throws {
        let event = try Wire.decode(ChatEvent.self, from: Self.futureFrame)
        let reencoded = try Wire.json(event)

        let before = try Wire.decode(JSONValue.self, from: Self.futureFrame)
        let after = try Wire.decode(JSONValue.self, from: reencoded)
        #expect(after == before, "the frame lost or gained a field on the way through")
    }

    /// The payload keeps the discriminator too, so a relayed frame is complete
    /// on its own rather than needing the enum case to reconstruct it.
    @Test("the captured payload includes the discriminator itself")
    func unknownPayloadKeepsItsType() throws {
        let event = try Wire.decode(ChatEvent.self, from: Self.futureFrame)
        guard case let .unknown(_, payload) = event, case let .object(fields) = payload else {
            Issue.record("expected .unknown carrying an object")
            return
        }
        #expect(fields[UnknownFrame.typeKey] == .string("quantumEntangled"))
    }

    @Test("an unknown event survives any number of trips across the wire")
    func unknownEventIsStableAcrossHops() throws {
        var json = Self.futureFrame
        for _ in 0 ..< 3 {
            json = try Wire.json(Wire.decode(ChatEvent.self, from: json))
        }
        let expected = try Wire.decode(JSONValue.self, from: Self.futureFrame)
        #expect(try Wire.decode(JSONValue.self, from: json) == expected)
    }

    // MARK: - Commands

    /// The same rule in the other direction: an older *server* reading a newer
    /// client's command must be able to parse it, recognise that it cannot
    /// honour it, and say so — rather than drop the connection.
    @Test("an unrecognised command type decodes rather than throwing")
    func unknownCommandDoesNotThrow() throws {
        let command = try Wire.decode(ChatCommand.self, from: Self.futureFrame)
        guard case let .unknown(type, _) = command else {
            Issue.record("expected .unknown, got \(command)")
            return
        }
        #expect(type == "quantumEntangled")
    }

    @Test("an unrecognised command re-encodes with every field it arrived with")
    func unknownCommandReEncodesVerbatim() throws {
        let command = try Wire.decode(ChatCommand.self, from: Self.futureFrame)
        let before = try Wire.decode(JSONValue.self, from: Self.futureFrame)
        let after = try Wire.decode(JSONValue.self, from: Wire.json(command))
        #expect(after == before)
    }

    // MARK: - The limits of the guarantee

    /// A frame with no discriminator at all is malformed rather than futuristic,
    /// and throwing is correct: there is nothing to relay and nothing to
    /// dispatch on.
    @Test("a frame with no type at all is rejected, not treated as unknown")
    func missingDiscriminatorThrows() throws {
        #expect(throws: DecodingError.self) {
            try Wire.decode(ChatEvent.self, from: #"{"conversationID":"space:1"}"#)
        }
        #expect(throws: DecodingError.self) {
            try Wire.decode(ChatCommand.self, from: #"{"text":"hi"}"#)
        }
    }

    /// A documented gap, pinned so it is visible rather than discovered.
    ///
    /// `GapScope` is a *closed* enum, so an unrecognised discriminator nested
    /// inside `gap` throws and takes the whole frame with it — exactly the
    /// failure the outer `.unknown` case exists to prevent. This is a known
    /// asymmetry, not a deliberate design, and the assertion below is here so
    /// that closing the gap shows up as a deliberate test change.
    ///
    /// `ConnectionState` used to share this gap, and a test here used to pin
    /// it (`closedEnumsStillThrow`). The reconnect taxonomy's wire change gave
    /// it its own `.unknown(String)` case, so that assertion is gone and
    /// `anUnrecognisedConnectionStateDecodesRatherThanThrowing` below pins the
    /// closed gap instead — exactly the "deliberate test change" this comment
    /// asked for.
    @Test("an unrecognised gap scope throws, taking the frame with it")
    func unknownGapScopeThrows() throws {
        let frame = #"{"type":"gap","reason":"overflow","scope":{"type":"galaxy"}}"#
        #expect(throws: (any Error).self) {
            try Wire.decode(ChatEvent.self, from: frame)
        }
    }

    /// The gap `closedEnumsStillThrow` used to pin: a `connectionStateChanged`
    /// frame naming an issue this build has never heard of now decodes to
    /// `.unknown` instead of throwing and taking the envelope with it, the
    /// same guarantee `unknownEventDoesNotThrow` makes for the outer frame.
    @Test("an unrecognised connection state decodes rather than throwing")
    func anUnrecognisedConnectionStateDecodesRatherThanThrowing() throws {
        let frame = #"{"type":"connectionStateChanged","state":{"type":"quantumTunnelling"}}"#
        let event = try Wire.decode(ChatEvent.self, from: frame)
        #expect(event == .connectionStateChanged(.unknown("quantumTunnelling")))

        let reencoded = try Wire.json(event)
        let before = try Wire.decode(JSONValue.self, from: frame)
        let after = try Wire.decode(JSONValue.self, from: reencoded)
        #expect(after == before, "the frame lost or gained a field on the way through")
    }

    /// `ChatError` absorbs an unknown type instead of throwing, which is the
    /// right trade — an error frame that fails to decode replaces a useful
    /// diagnostic with a useless one — but it is lossy: the unfamiliar error's
    /// payload is dropped, unlike `ChatEvent.unknown`.
    @Test("an unrecognised error type is absorbed as unknown, losing its payload")
    func unknownErrorIsLossy() throws {
        let json = #"{"type":"quotaExceeded","limit":500,"message":"too many"}"#
        let error = try Wire.decode(ChatError.self, from: json)
        #expect(error == .unknown("quotaExceeded"))

        let fields = try Wire.decode(JSONValue.self, from: Wire.json(error))
        #expect(fields == .object(["type": .string("unknown"), "message": .string("quotaExceeded")]))
    }

    // MARK: - Absence

    /// `nil` is omitted, never written as `null`. A decoder that treats a
    /// present-but-null field as a value is a decoder that will one day read
    /// `null` as a message body.
    @Test("an absent optional is omitted rather than written as null")
    func nilIsOmittedFromFrames() throws {
        let newThread = Fixture.commands.first { $0.name == "command-sendMessage-newThread" }
        let json = try Wire.json(#require(newThread).value)
        #expect(!json.contains("null"))
        #expect(!json.contains("threadID"))
        #expect(!json.contains("localID"))

        let noHint = Fixture.errors.first { $0.name == "error-rateLimited-noHint" }
        #expect(try !(Wire.json(#require(noHint).value)).contains("null"))

        let deliberate = Fixture.connectionStates.first { $0.name == "state-disconnected-deliberate" }
        #expect(try !(Wire.json(#require(deliberate).value)).contains("null"))
    }
}
