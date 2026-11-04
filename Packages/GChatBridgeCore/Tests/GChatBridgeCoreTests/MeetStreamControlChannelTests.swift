import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetStreamControlChannelTests {
    @Test(arguments: [(UInt64(5), UInt64(0)), (5, 1), (5, 65535), (6, 0), (6, 1), (6, 65535)])
    func acceptsNativeLifetimeAndRetransmissionLimits(_ field: UInt64, _ limit: UInt64) throws {
        let raw = MeetProto.string(1, "dcrpc") + MeetProto.number(2, 1) + MeetProto.number(3, 42)
            + MeetProto.number(field, limit) + MeetProto.number(7, 1)
        let decoded = try MeetMediaSessionWire.streamControlChannel(
            serverConfiguration: MeetProto.bytes(12, raw)
        )
        #expect(decoded?.id == 42 && decoded?.ordered == true)
        #expect(decoded?.maxPacketLifeTime == (field == 5 ? UInt16(limit) : nil))
        #expect(decoded?.maxRetransmits == (field == 6 ? UInt16(limit) : nil))
    }

    @Test func reliabilityOneofUsesTheLastWireMemberIncludingZero() throws {
        let base = MeetProto.string(1, "dcrpc") + MeetProto.number(3, 42)
        let members = MeetProto.number(4, 1) + MeetProto.number(5, 50) + MeetProto.number(6, 0)
        let limited = try MeetMediaSessionWire.streamControlChannel(
            serverConfiguration: MeetProto.bytes(12, base + members)
        )
        #expect(limited?.maxRetransmits == 0 && limited?.maxPacketLifeTime == nil)
        let reliable = try MeetMediaSessionWire.streamControlChannel(
            serverConfiguration: MeetProto.bytes(12, base + members + MeetProto.number(4, 0))
        )
        #expect(reliable?.maxRetransmits == nil && reliable?.maxPacketLifeTime == nil)
        let repeated = try MeetMediaSessionWire.streamControlChannel(
            serverConfiguration: MeetProto.bytes(12, base + MeetProto.number(5, 10) + MeetProto.number(5, 0))
        )
        #expect(repeated?.maxPacketLifeTime == 0 && repeated?.maxRetransmits == nil)
    }

    @Test(arguments: [UInt64(0), 42, 65534])
    func readsTheAssignedChannelWithoutInventingAnIdentifier(_ id: UInt64) throws {
        let configuration = MeetProto.bytes(12, channel(id: id))
        let decoded = try MeetMediaSessionWire.streamControlChannel(serverConfiguration: configuration)
        let value = try #require(decoded)
        #expect(value.id == id && value.ordered)
        #expect(try MeetMediaSessionWire.streamControlChannel(serverConfiguration: Data()) == nil)
    }

    @Test func packedPreferencesAndDefaultFlagsFollowTheNativeConverter() throws {
        let raw = MeetProto.string(1, "dcrpc") + MeetProto.number(3, 42)
            + MeetProto.bytes(7, Data([1, 2]))
        let decoded = try MeetMediaSessionWire.streamControlChannel(
            serverConfiguration: MeetProto.bytes(12, raw)
        )
        let value = try #require(decoded)
        #expect(!value.ordered)
        let defaultCompression = MeetProto.string(1, "dcrpc") + MeetProto.number(3, 42)
        #expect(try MeetMediaSessionWire.streamControlChannel(
            serverConfiguration: MeetProto.bytes(12, defaultCompression)
        )?.id == 42)
    }

    @Test(arguments: [(UInt64(0), UInt64(0)), (0, 1), (1, 0), (1, 1)])
    func acceptsNativeReliableDefaultsAndUnspecifiedCompression(
        _ reliable: UInt64,
        _ compression: UInt64
    ) throws {
        let raw = MeetProto.string(1, "dcrpc") + MeetProto.number(2, 1) + MeetProto.number(3, 42)
            + MeetProto.number(4, reliable) + MeetProto.bytes(7, Data([UInt8(compression), 1]))
        let decoded = try MeetMediaSessionWire.streamControlChannel(
            serverConfiguration: MeetProto.bytes(12, raw)
        )
        #expect(decoded?.id == 42 && decoded?.ordered == true)
    }

    @Test func unusedChannelsCannotRejectTheSelectedControlChannel() throws {
        let selected = MeetProto.bytes(12, channel(id: 42))
        for other in [
            channel(id: 42, label: "other"), channel(id: UInt64.max, label: "other"),
            Data(), MeetProto.string(1, "other") + MeetProto.number(7, 99)
        ] {
            let decoded = try MeetMediaSessionWire.streamControlChannel(
                serverConfiguration: selected + MeetProto.bytes(12, other)
            )
            #expect(decoded?.id == 42)
        }
    }

    @Test func failuresNameOnlyTheSelectedConfigurationCheck() throws {
        typealias Failure = MeetMediaSessionWire.StreamControlFailure
        let label = MeetProto.string(1, "dcrpc")
        let cases: [(Data, Failure)] = [
            (label, .missingIdentifier),
            (channel(id: 65535), .identifier),
            (channel(id: 42) + MeetProto.number(2, 0), .ordering),
            (channel(id: 42) + MeetProto.number(4, 2), .reliability),
            (channel(id: 42) + MeetProto.bytes(6, Data()), .reliabilityEncoding),
            (channel(id: 42) + MeetProto.number(6, 65536), .reliabilityLimit),
            (channel(id: 42, compression: 2), .compression),
            (label + MeetProto.number(3, 42) + MeetProto.bytes(7, Data([99])), .compression)
        ]
        for (raw, failure) in cases {
            #expect(throws: failure) {
                try MeetMediaSessionWire.streamControlChannel(serverConfiguration: MeetProto.bytes(12, raw))
            }
        }
        #expect(throws: Failure.configuration) {
            try MeetMediaSessionWire.streamControlChannel(serverConfiguration: Data([128]))
        }
    }

    @Test func refusesMissingDuplicateForeignOrUnsupportedChannelSettings() throws {
        let good = channel(id: 42)
        let bad: [Data] = [
            MeetProto.string(1, "dcrpc"), channel(id: 65535),
            good + MeetProto.number(3, 43),
            channel(id: 42, compression: 2),
            good + MeetProto.number(5, 65536),
            good + MeetProto.number(6, 65536),
            good + MeetProto.number(2, 0)
        ]
        for raw in bad {
            #expect(throws: MeetMediaSessionWire.StreamControlFailure.self) {
                try MeetMediaSessionWire.streamControlChannel(serverConfiguration: MeetProto.bytes(12, raw))
            }
        }
        for other in [good, channel(id: 43)] {
            #expect(throws: MeetMediaSessionWire.StreamControlFailure.self) {
                try MeetMediaSessionWire.streamControlChannel(
                    serverConfiguration: MeetProto.bytes(12, good) + MeetProto.bytes(12, other)
                )
            }
        }
        #expect(throws: MeetMediaSessionWire.StreamControlFailure.self) {
            try MeetMediaSessionWire.streamControlChannel(serverConfiguration: MeetProto.number(12, 1))
        }
    }

    private func channel(id: UInt64, label: String = "dcrpc", compression: UInt64 = 1) -> Data {
        MeetProto.string(1, label) + MeetProto.number(2, 1) + MeetProto.number(3, id)
            + MeetProto.number(4, 1) + MeetProto.number(7, compression)
    }
}
