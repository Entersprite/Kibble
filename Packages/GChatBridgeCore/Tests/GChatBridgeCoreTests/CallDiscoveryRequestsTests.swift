import GChatBridgeCore
import SwiftProtobuf
import Testing

struct CallDiscoveryRequestsTests {
    @Test func participantsUsesTheExactGroupAndExplicitFetchOption() throws {
        let groups: [GroupId] = [
            .with { $0.spaceID.spaceID = "example" },
            .with { $0.dmID.dmID = "example" }
        ]
        for group in groups {
            let call = try CallDiscoveryRequests.participants(in: group)
            #expect(call.hasRequestHeader && call.groupID == group && call.fetchOptions == [1])
            let fields = try ProtoFieldScan.fields(in: call.serializedData()).fields.map(\.number)
            #expect(fields.sorted() == [1, 2, 100])
        }
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(in: GroupId())
        }
    }

    @Test func rosterPreservesAnonymousPeopleAndAnIncompleteCount() throws {
        var response = GetCallDataResponse()
        response.participantList.totalCount = 5
        response.participantList.users = [.with { $0.id = "first" }, .with { $0.id = "second" }]
        response.participantList.anonymousParticipants = [
            .with { $0.displayName = "Guest" },
            .init()
        ]
        let value = try CallDiscoveryRequests.participants(from: response)
        #expect(value.memberIDs == ["first", "second"])
        #expect(value.anonymousNames == ["Guest", nil])
        #expect(value.totalCount == 5)

        var empty = GetCallDataResponse()
        empty.participantList.totalCount = 0
        let emptyRoster = try CallDiscoveryRequests.participants(from: empty)
        #expect(emptyRoster.totalCount == 0)
        #expect(emptyRoster.memberIDs.isEmpty)
    }

    @Test func binaryResponseCarriesTheParticipantListInFieldOne() throws {
        let raw: [UInt8] = [0x0A, 0x07, 0x0A, 0x03, 0x0A, 0x01, 0x61, 0x10, 0x01]
        let response = try GetCallDataResponse(serializedBytes: raw)
        let roster = try CallDiscoveryRequests.participants(from: response)
        #expect(roster.memberIDs == ["a"] && roster.totalCount == 1)
    }

    @Test func malformedRosterIsNeverAnAuthoritativeEmptyList() {
        var response = GetCallDataResponse()
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(from: response)
        }
        response.participantList.users = [.init()]
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(from: response)
        }
        response.participantList.totalCount = 1
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(from: response)
        }
        response.participantList.users = [.with { $0.id = "same" }, .with { $0.id = "same" }]
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(from: response)
        }
        response.participantList.totalCount = 2
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(from: response)
        }
        response.participantList.users = []
        response.participantList.totalCount = 10001
        #expect(throws: CallDiscoveryRequests.Failure.self) {
            try CallDiscoveryRequests.participants(from: response)
        }
    }
}
