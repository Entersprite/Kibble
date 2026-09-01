import Foundation
import Testing
@testable import GChatBridgeCore

/// What is inside a framed chunk.
///
/// `findings.md` §4: chunks are `[[aid, data], ...]`, and `data == ["noop"]` is
/// a keepalive. The `aid` is the acknowledgement counter the steady-state
/// reopen sends back, so misreading one costs replayed or skipped events rather
/// than a visible failure.
struct ChannelChunkTests {
    // MARK: - Arrays

    @Test func oneArrayCarriesItsAidAndData() throws {
        let arrays = try ChannelChunk.arrays(in: #"[[1,["a"]]]"#)
        #expect(arrays.count == 1)
        #expect(arrays.first?.aid == 1)
        #expect(arrays.first?.data == .array([.string("a")]))
    }

    @Test func severalArraysArriveInOneChunk() throws {
        let arrays = try ChannelChunk.arrays(in: #"[[1,["a"]],[2,["b"]],[3,["c"]]]"#)
        #expect(arrays.map(\.aid) == [1, 2, 3])
    }

    @Test func anEmptyChunkHasNoArrays() throws {
        #expect(try ChannelChunk.arrays(in: "[]").isEmpty)
    }

    /// `aid` is used as an integer for the reopen's `AID` parameter, so a value
    /// that is not one has to be refused rather than coerced - an `AID` the
    /// server does not recognise is how a client silently loses events.
    @Test func aNonIntegerAidIsRefused() {
        #expect(throws: ChannelChunkError.self) {
            try ChannelChunk.arrays(in: #"[["one",["a"]]]"#)
        }
    }

    @Test func anEntryThatIsNotAPairIsRefused() {
        #expect(throws: ChannelChunkError.self) {
            try ChannelChunk.arrays(in: "[[1]]")
        }
    }

    @Test func aTopLevelValueThatIsNotAnArrayIsRefused() {
        #expect(throws: ChannelChunkError.self) {
            try ChannelChunk.arrays(in: #"{"a":1}"#)
        }
    }

    @Test func unparseableJSONIsRefused() {
        #expect(throws: (any Error).self) {
            try ChannelChunk.arrays(in: "not json")
        }
    }

    // MARK: - Keepalives

    @Test func theNoopArrayIsAKeepalive() throws {
        let arrays = try ChannelChunk.arrays(in: #"[[1,["noop"]]]"#)
        #expect(arrays.first?.isKeepalive == true)
    }

    /// A keepalive is exactly `["noop"]`. Anything that merely contains the word
    /// is a real event, and treating it as a keepalive would drop it.
    @Test func aPayloadThatMerelyMentionsNoopIsNotAKeepalive() throws {
        #expect(try ChannelChunk.arrays(in: #"[[1,["noop","x"]]]"#).first?.isKeepalive == false)
        #expect(try ChannelChunk.arrays(in: #"[[1,[["noop"]]]]"#).first?.isKeepalive == false)
        #expect(try ChannelChunk.arrays(in: #"[[1,"noop"]]"#).first?.isKeepalive == false)
    }

    /// A keepalive still carries an `aid` and still advances the watermark;
    /// dropping it would make the client re-request everything after it.
    @Test func aKeepaliveStillCarriesItsAid() throws {
        #expect(try ChannelChunk.arrays(in: #"[[7,["noop"]]]"#).first?.aid == 7)
    }

    // MARK: - The SID handshake

    /// `res[0][1][1]`, the exact expression the reference uses
    /// (`channel.py:124-134`). The SID observed live was 22 characters.
    @Test func theSIDComesOutOfTheInitialResponse() throws {
        let initial = #"[[0,["c","S0meS3ss10nId0123456789","",8,12,30000]]]"#
        #expect(try ChannelChunk.sid(inInitialResponse: initial) == "S0meS3ss10nId0123456789")
    }

    @Test func anInitialResponseWithoutASIDIsRefused() {
        #expect(throws: ChannelChunkError.self) {
            try ChannelChunk.sid(inInitialResponse: #"[[0,["c"]]]"#)
        }
    }

    @Test func anInitialResponseOfTheWrongShapeIsRefused() {
        #expect(throws: ChannelChunkError.self) {
            try ChannelChunk.sid(inInitialResponse: "[]")
        }
    }

    /// A non-string SID would be interpolated into a URL as something else
    /// entirely, so it is refused rather than described.
    @Test func aNonStringSIDIsRefused() {
        #expect(throws: ChannelChunkError.self) {
            try ChannelChunk.sid(inInitialResponse: #"[[0,["c",12345]]]"#)
        }
    }
}
