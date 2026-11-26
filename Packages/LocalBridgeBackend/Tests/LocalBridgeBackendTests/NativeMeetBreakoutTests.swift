import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetBreakoutTests {
    @Test func assignmentsSurviveRoomOnlyUpdatesWithoutTreatingCurrentLocationAsAssignment() async throws {
        let transport = ScriptedTransport(Array(NativeMeetFixture.responses().prefix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        let name = "spaces/demo/rooms/one", person = "spaces/demo/people/taylor"
        let room = NativeMeetFixture.string(1, name) + NativeMeetFixture.string(3, "One")
        let breakout = NativeMeetFixture.number(2, 2) + NativeMeetFixture.bytes(4, room)
        let currentOnly = NativeMeetFixture.string(1, person) + NativeMeetFixture.string(5, name)
        await session.reconcileRooms(breakout)
        await session.reconcileRoomPeople([currentOnly])
        #expect(await session.activities.rooms.first?.participants.isEmpty == true)
        let invited = NativeMeetFixture.string(1, person) + NativeMeetFixture.string(4, name)
        await session.reconcileRoomPeople([invited])
        let assigned = await session.activities.rooms.first?.participants
        #expect(assigned?.count == 1)
        await session.reconcileRooms(breakout)
        #expect(await session.activities.rooms.first?.participants == assigned)
        let handle = try #require(await session.activities.people.first?.id)
        await session.reconcileRoomPeople([])
        await #expect(throws: ChatError.self) { try await session.activityResource(handle, kind: "person") }
    }

    @Test(arguments: [true, false])
    func creatingRoomsRequiresCurrentBreakoutStateDespiteBadPollSeries(validRoom: Bool) async throws {
        let room = NativeMeetFixture.string(1, "b703b92e-de6d-42c0-84ed-a61360252026")
            + NativeMeetFixture.string(3, "Design")
        let before = breakoutSnapshot(version: 4, breakout: validRoom ? NativeMeetFixture.number(2, 1) : nil)
        let after = breakoutSnapshot(
            version: 5,
            breakout: NativeMeetFixture.number(2, 2) + NativeMeetFixture.bytes(4, room)
        )
        let start = Array(NativeMeetFixture.responses().prefix(4))
        let actions = validRoom ? [before, NativeMeetFixture.ok(Data()), before, after] : [before]
        let transport = ScriptedTransport(start + actions + Array(NativeMeetFixture.responses().suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        let activity = CallActivity("createAndOpenRooms", options: ["Design"])
        if validRoom {
            try await session.performActivity(activity)
            #expect(await session.activities.rooms.map(\.name) == ["Design"])
            #expect(await session.activities.rooms.first?.isOpen == true)
        } else {
            await #expect(throws: (any Error).self) { try await session.performActivity(activity) }
            #expect(await session.activities.rooms.isEmpty)
        }
        let requests = await transport.sent.suffix(actions.count).map(\.url.lastPathComponent)
        #expect(requests == (validRoom ? [
            "SyncMeetingSpaceCollections", "ConfigureBreakoutSessions",
            "SyncMeetingSpaceCollections", "SyncMeetingSpaceCollections"
        ] : ["SyncMeetingSpaceCollections"]))
        await session.close()
    }

    @Test func reopeningIsWithheldUntilTheProviderFinishesClosingRooms() async throws {
        let room = NativeMeetFixture.bytes(
            4,
            NativeMeetFixture.string(1, "spaces/demo/rooms/one")
                + NativeMeetFixture.string(3, "Design")
        )
        let closing = breakoutSnapshot(version: 4, breakout: NativeMeetFixture.number(2, 3) + room)
        let start = Array(NativeMeetFixture.responses().prefix(4))
        let transport = ScriptedTransport(start + [closing] + Array(NativeMeetFixture.responses().suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        await #expect(throws: ChatError.self) { try await session.performActivity(CallActivity("openRooms")) }
        let state = await session.activities
        #expect(state.breakoutClosing == true)
        #expect(state.breakoutClosed == nil)
        #expect(state.rooms.first?.isOpen == false)
        #expect(Set(state.availableActions).isDisjoint(with: [
            "assignRoom",
            "openRooms",
            "createAndOpenRooms"
        ]))
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("ConfigureBreakoutSessions") })

        await session.reconcileRooms(NativeMeetFixture.number(2, 1) + room)
        await session.updateActivityAvailability()
        #expect(await session.activities.breakoutClosing == nil)
        #expect(await session.activities.breakoutClosed == true)
        #expect(await session.activities.availableActions.contains("openRooms"))
        await session.updateActivityCollectionFailures([8], confirmed: [])
        #expect(await session.activities.breakoutClosed == nil)
        await session.close()
    }

    @Test func removingTheLastRoomAssignmentExplicitlyUnassignsThatPerson() async throws {
        let roomID = "b703b92e-de6d-42c0-84ed-a61360252026"
        let person = "spaces/demo/people/participant"
        let room = NativeMeetFixture.string(1, roomID) + NativeMeetFixture.string(3, "Design")
        let breakout = NativeMeetFixture.number(2, 2) + NativeMeetFixture.bytes(4, room)
        let personName = NativeMeetFixture.string(1, person)
        let assigned = personName + NativeMeetFixture.string(4, roomID)
        let before = breakoutSnapshot(version: 4, breakout: breakout, person: assigned)
        let after = breakoutSnapshot(version: 5, breakout: breakout, person: personName)
        let start = Array(NativeMeetFixture.responses().prefix(4))
        let transport = ScriptedTransport(start + [before, NativeMeetFixture.ok(Data()), after]
            + Array(NativeMeetFixture.responses().suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        await session.reconcileRooms(breakout)
        await session.reconcileRoomPeople([assigned])
        let assignedRoom = try #require(await session.activities.rooms.first)
        #expect(assignedRoom.participants.count == 1)
        try await session.performActivity(CallActivity("assignRoom", resourceID: assignedRoom.id))
        #expect(await session.activities.rooms.first?.participants.isEmpty == true)
        let writes = await transport.sent.filter { $0.url.lastPathComponent == "ConfigureBreakoutSessions" }
        let body = try #require(writes.first?.body)
        #expect(writes.count == 1)
        #expect(MeetActivityCollections.repeated(3, body) == [Data(person.utf8)])
        #expect(!MeetActivityCollections.has(5, body))
        await session.close()
    }

    private func breakoutSnapshot(version: UInt64, breakout: Data?, person: Data? = nil)
        -> Result<HTTPResponse, any Error> {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let badSeries = NativeMeetFixture.string(1, "spaces/foreign/pollSeries/one")
        let series = NativeMeetFixture.bytes(5, NativeMeetFixture.bytes(
            2, metadata + NativeMeetFixture.bytes(2, badSeries)
        ))
        let rooms = breakout.map { NativeMeetFixture.bytes(
            8, NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, $0))
        ) } ?? Data()
        let people = person.map { NativeMeetFixture.bytes(
            9, NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, $0))
        ) } ?? Data()
        return NativeMeetFixture.ok(series + rooms + people)
    }
}
