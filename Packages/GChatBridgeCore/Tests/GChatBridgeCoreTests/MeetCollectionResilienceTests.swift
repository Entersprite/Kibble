import Foundation
import Testing
@testable import GChatBridgeCore

struct MeetCollectionResilienceTests {
    @Test func emptyActivityAndHandCollectionsUseAnOmittedZeroVersion() throws {
        let empty = MeetProto.bytes(1, Data())
        let body = [3, 4, 5, 6, 7, 8, 9, 10].reduce(Data()) {
            $0 + collection($1, empty)
        }
        let snapshot = try MeetCallCollectionsWire.snapshot(from: encoded(body), in: "spaces/demo")
        let activities = try #require(snapshot.activities)
        #expect(activities.versions[8] == 0 && activities.breakout == Data())
        #expect(activities.messages == [] && activities.polls == [] && activities.users == [])
        #expect(snapshot.hands?.version == 0 && snapshot.hands?.values.isEmpty == true)
    }

    @Test func uninitializedBreakoutStateMayContainOnlySyncMetadata() throws {
        let body = collection(8, MeetProto.bytes(1, MeetProto.number(1, 12)))
        let activities = try MeetActivityCollections.decode(encoded(body), space: "spaces/demo")
        #expect(activities.versions[8] == 12 && activities.breakout == Data())
        let absent = try MeetActivityCollections.decode(Data(), space: "spaces/demo")
        #expect(absent.breakout == nil && absent.versions[8] == nil)
    }

    @Test func badOptionalActivitiesCannotDiscardGoodDevicesAndInvitations() throws {
        let device = MeetProto.string(1, "spaces/demo/devices/peer") + MeetProto.number(4, 1)
        let invitation = MeetProto.string(1, "opaque-invite") + MeetProto.number(6, 2)
        let badPoll = MeetProto.string(1, "spaces/foreign/polls/one")
        let body = collection(2, full(8, device)) + collection(11, full(9, invitation))
            + collection(4, full(2, badPoll)) + collection(8, MeetProto.bytes(1, Data()))
        let snapshot = try MeetCallCollectionsWire.snapshot(from: encoded(body), in: "spaces/demo")
        #expect(snapshot.devices?.values.first?.joinState == 1)
        #expect(snapshot.invitations?.values.first?.status == 2)
        #expect(snapshot.activities?.unavailableFields == [4])
        #expect(snapshot.activities?.polls == nil && snapshot.activities?.versions[4] == nil)
        #expect(snapshot.activities?.breakout == Data())
        #expect(throws: MeetCallWire.WireError.self) {
            try MeetActivityCollections.decode(encoded(body), space: "spaces/demo")
        }
    }

    @Test func malformedAndNegativeVersionsNeverBecomeAnEmptyConfirmedCollection() throws {
        for metadata in [
            MeetProto.string(1, "bad"),
            MeetProto.number(1, UInt64.max),
            MeetProto.number(1, 1) + MeetProto.number(1, 2)
        ] {
            let body = collection(4, MeetProto.bytes(1, metadata))
            #expect(throws: MeetCallWire.WireError.self) {
                try MeetActivityCollections.decode(encoded(body), space: "spaces/demo")
            }
        }
    }

    private func full(_ version: UInt64, _ value: Data) -> Data {
        MeetProto.bytes(1, MeetProto.number(1, version)) + MeetProto.bytes(2, value)
    }

    private func collection(_ field: Int, _ value: Data) -> Data {
        MeetProto.bytes(UInt64(field), MeetProto.bytes(2, value))
    }

    private func encoded(_ data: Data) -> Data {
        Data(data.base64EncodedString().utf8)
    }
}
