import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetJoinLinkTests {
    @Test(arguments: [
        "authuser=2&hs=122", "utm_source=calendar&utm_campaign=invite",
        "companion=1&present=1&hl=en", "future_parameter=value&token=discarded",
        "authuser=2&authuser=3&redirect=https%3A%2F%2Fexample.test"
    ])
    func canonicalizesThePublicLinkWithoutAdoptingAnyQueryParameters(_ query: String) throws {
        let url = try #require(URL(string: "https://meet.google.com/abc-defg-hij?" + query))
        let link = try MeetJoinLink(url)
        #expect(link.code == "abc-defg-hij")
        #expect(link.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test(arguments: [
        "/meet/abc-defg-hij", "/meet/abc-defg-hij/", "/abc-defg-hij/",
        "/meet/abc-defg-hij?authuser=2&utm_source=calendar"
    ])
    func canonicalizesMeetingRoutesBeforeResolution(_ path: String) throws {
        let link = try MeetJoinLink(#require(URL(string: "https://meet.google.com" + path)))
        #expect(link.code == "abc-defg-hij")
        #expect(link.url.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test(arguments: [
        "http://meet.google.com/abc-defg-hij", "https://meet.google.com.attacker.test/abc-defg-hij",
        "https://user:password@meet.google.com/abc-defg-hij", "https://meet.google.com:444/abc-defg-hij",
        "https://meet.google.com/%61bc-defg-hij", "https://meet.google.com/abc-defg-hij/extra",
        "https://meet.google.com/meet/%61bc-defg-hij", "https://meet.google.com/meet/abc-defg-hij/extra",
        "https://meet.google.com/abcd/abc-defg-hij", "https://meet.google.com/meet//abc-defg-hij",
        "https://meet.google.com/meet/abc-defg-hij//", "https://meet.google.com/%6deet/abc-defg-hij",
        "https://meet.google.com/abc-defg-hij#token",
        "https://meet.google.com/call", "https://meet.google.com/abc-defg-hi", "file:///abc-defg-hij"
    ])
    func refusesUnrelatedEndpointsCredentialsAndMalformedCodes(_ value: String) throws {
        #expect(throws: MeetCallWire.WireError.self) { try MeetJoinLink(#require(URL(string: value))) }
    }

    @Test func fullHandsAreVersionedAndBoundToTheMeeting() throws {
        let hand = MeetProto.string(1, "spaces/demo/hands/one")
            + MeetProto.string(4, "spaces/demo/devices/peer")
        let full = MeetProto.bytes(1, MeetProto.number(1, 7)) + MeetProto.bytes(2, hand)
        let result = try MeetCallCollectionsWire.snapshot(
            from: Data(MeetProto.bytes(10, MeetProto.bytes(
                2,
                full
            )).base64EncodedString().utf8), in: "spaces/demo"
        )
        #expect(result.hands?.version == 7)
        #expect(result.hands?.values.first?.device == "spaces/demo/devices/peer")
        #expect(try MeetProto.payload(11, MeetCallCollectionsWire.sync(space: "spaces/demo")).isEmpty)
        let foreign = MeetProto.string(1, "spaces/other/hands/one")
            + MeetProto.string(4, "spaces/demo/devices/peer")
        let foreignFull = MeetProto.bytes(1, MeetProto.number(1, 8)) + MeetProto.bytes(2, foreign)
        let foreignReply = MeetProto.bytes(10, MeetProto.bytes(2, foreignFull))
        #expect(throws: MeetCallWire.WireError.self) {
            try MeetCallCollectionsWire.snapshot(
                from: Data(foreignReply.base64EncodedString().utf8),
                in: "spaces/demo"
            )
        }
        let absent = try MeetCallCollectionsWire.snapshot(from: Data(), in: "spaces/demo")
        #expect(absent.hands == nil)
    }
}
