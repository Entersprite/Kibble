import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetWaitingTests {
    private let first = "spaces/demo/devices/guest-a"
    private let second = "spaces/demo/devices/guest-b"
    private let third = "spaces/demo/devices/guest-c"

    @Test(arguments: [UInt64(3), 13])
    func admitsEitherWaitingStateAndPublishesJoinedRosterAfterReadback(_ initialState: UInt64) async throws {
        let start = snapshot(1, guests: [guest(first, initialState), guest(second, 5)])
        let joined = guest(first, 1)
        let after = snapshot(2, guests: [joined])
        let (session, transport) = try await connect([start, start, NativeMeetFixture.ok(joined), after])
        await session.refreshState()
        let waiting = await session.activities.waitingParticipants
        let row = try #require(waiting.first)
        #expect(waiting.count == 1 && row.name == "guest-a" && row.canDeny == (initialState == 3))
        #expect(await session.publishedParticipants?.count == 1)
        try await session.performActivity(CallActivity("respondToAdmission", resourceID: row.id))
        let request = try #require(await transport.sent.last)
        #expect(request.url.lastPathComponent == "UpdateMeetingDevice")
        #expect(request.headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        #expect(request.body == singleBody(first, state: 1))
        #expect(await session.activities.waitingParticipants == [row])
        await session.refreshState()
        #expect(await session.activities.waitingParticipants.isEmpty)
        #expect(await session.publishedParticipants?.contains { $0.displayName == row.name } == true)
        await session.close()
    }

    @Test(arguments: [true, false])
    func denyNeedsAnExactDenialReceipt(_ valid: Bool) async throws {
        let start = snapshot(1, guests: [guest(first, 3)])
        let receipt = NativeMeetFixture.ok(guest(valid ? first : second, 4))
        let (session, transport) = try await connect([start, start, receipt])
        await session.refreshState()
        let row = try #require(await session.activities.waitingParticipants.first)
        let action = CallActivity("respondToAdmission", resourceID: row.id, enabled: false)
        if valid {
            try await session.performActivity(action)
        } else {
            await #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try await session.performActivity(action)
            }
        }
        #expect(await transport.sent.last?.body == singleBody(first, state: 4))
        #expect(await transport.sent.dropFirst(4).filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
            .count == 1)
        await session.close()
    }

    @Test(arguments: [true, false])
    func bulkReportsPartialAcknowledgementAndDoesNotAddressNewArrivals(_ admit: Bool) async throws {
        let old = [guest(first, 3), guest(second, admit ? 13 : 3)]
        let start = snapshot(1, guests: old)
        let fresh = snapshot(2, guests: old + [guest(third, 3)])
        let desired: UInt64 = admit ? 1 : 4
        let success = NativeMeetFixture.bytes(3, guest(first, desired))
        let failure = NativeMeetFixture.string(1, second)
            + NativeMeetFixture.bytes(2, NativeMeetFixture.number(1, 7))
        let receipt = NativeMeetFixture.ok(NativeMeetFixture.bytes(1, success) + NativeMeetFixture.bytes(
            1,
            failure
        ))
        let (session, transport) = try await connect([start, fresh, receipt])
        await session.refreshState()
        var action = CallActivity("respondToAdmissions", enabled: admit)
        action.participantIDs = await session.activities.waitingParticipants.map(\.id)
        await #expect(throws: ChatError.transport("Some waiting requests could not be confirmed.")) {
            try await session.performActivity(action)
        }
        let request = try #require(await transport.sent.last)
        #expect(request.url.lastPathComponent == "BulkUpdateMeetingDevices")
        #expect(request.body == bulkBody([first, second], state: desired))
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "BulkUpdateMeetingDevices" }
            .count == 1)
        await session.close()
    }

    @Test func aNewWarningRequiresTheUpdatedWaitingRowBeforeAdmit() async throws {
        let start = snapshot(1, guests: [guest(first, 3)])
        let flagged = snapshot(2, guests: [guest(first, 3) + NativeMeetFixture.number(36, 2)])
        let receipt = NativeMeetFixture.ok(guest(first, 1))
        let (session, transport) = try await connect([start, flagged, flagged, flagged, receipt])
        await session.refreshState()
        let oldRow = try #require(await session.activities.waitingParticipants.first)
        #expect(oldRow.warning == nil)
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("respondToAdmission", resourceID: oldRow.id))
        }
        #expect(await transport.sent.dropFirst(4)
            .allSatisfy { $0.url.lastPathComponent != "UpdateMeetingDevice" })
        await session.refreshState()
        let updated = try #require(await session.activities.waitingParticipants.first)
        #expect(updated.id != oldRow.id && updated.warning == .suspectedBot)
        try await session.performActivity(CallActivity("respondToAdmission", resourceID: updated.id))
        #expect(await transport.sent.last?.body == singleBody(first, state: 1))
        await session.close()
    }

    @Test(arguments: ["cohost", "withdrawn", "waiting-room", "other-id", "duplicate"])
    func preflightRejectsIneligibleDevicesRolesAndHandles(_ scenario: String) async throws {
        let start = snapshot(1, guests: [guest(first, 3)])
        let state: UInt64 = scenario == "waiting-room" ? 13 : 3
        let checked = snapshot(
            2, role: scenario == "cohost" ? 5 : 1,
            guests: scenario == "withdrawn" ? [] : [guest(first, state)]
        )
        let (session, transport) = try await connect([start, checked])
        await session.refreshState()
        let row = try #require(await session.activities.waitingParticipants.first)
        let bulk = scenario == "duplicate"
        var action = CallActivity(
            bulk ? "respondToAdmissions" : "respondToAdmission",
            resourceID: bulk ? nil : (scenario == "other-id" ? UUID() : row.id),
            enabled: false
        )
        if bulk {
            action.participantIDs = [row.id, row.id]
        }
        await #expect(throws: ChatError.self) {
            try await session.performActivity(action)
        }
        if scenario == "cohost" {
            #expect(await session.activities.waitingParticipants.isEmpty)
            #expect(await session.activities.availableActions.contains("respondToAdmission") == false)
        }
        #expect(await transport.sent.dropFirst(4).allSatisfy {
            !["UpdateMeetingDevice", "BulkUpdateMeetingDevices"].contains($0.url.lastPathComponent)
        })
        await session.close()
    }

    @Test func aCohostCanAdmitAnIndividualJoinRequest() async throws {
        let start = snapshot(1, role: 5, management: true, guests: [guest(first, 3), guest(second, 13)])
        let joined = guest(first, 1)
        let after = snapshot(2, role: 5, management: true, guests: [joined, guest(second, 13)])
        let (session, transport) = try await connect([
            start,
            start,
            start,
            NativeMeetFixture.ok(joined),
            after
        ])
        await session.refreshState()
        let waiting = await session.activities.waitingParticipants
        let row = try #require(waiting.first)
        #expect(waiting.count == 1 && row.name == "guest-a" && !row.isInWaitingRoom && !row.canDeny)
        #expect(await session.activities.availableActions.contains("respondToAdmission"))
        #expect(await !session.activities.availableActions.contains("respondToAdmissions"))
        await #expect(throws: ChatError.unsupported(capability: "callAdmission")) {
            try await session.performActivity(CallActivity(
                "respondToAdmission",
                resourceID: row.id,
                enabled: false
            ))
        }
        try await session.performActivity(CallActivity("respondToAdmission", resourceID: row.id))
        #expect(await transport.sent.last?.body == singleBody(first, state: 1))
        let writes = await transport.sent.dropFirst(4)
            .filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
        #expect(writes.count == 1)
        await session.refreshState()
        #expect(await session.activities.waitingParticipants.isEmpty)
        #expect(await session.publishedParticipants?.contains { $0.displayName == row.name } == true)
        await session.close()
    }

    @Test(arguments: ["demoted", "management-off", "management-missing", "waiting-room"])
    func aStaleCohostAdmissionCannotChangeTheTarget(_ change: String) async throws {
        let start = snapshot(1, role: 5, management: true, guests: [guest(first, 3)])
        let current = snapshot(
            2, role: change == "demoted" ? 3 : 5,
            management: change == "management-missing" ? nil : change != "management-off",
            guests: [guest(first, change == "waiting-room" ? 13 : 3)]
        )
        let (session, transport) = try await connect([start, current])
        await session.refreshState()
        let row = try #require(await session.activities.waitingParticipants.first)
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("respondToAdmission", resourceID: row.id))
        }
        if change != "management-missing" {
            #expect(await session.activities.waitingParticipants.isEmpty)
        }
        #expect(await transport.sent.dropFirst(4)
            .allSatisfy { $0.url.lastPathComponent != "UpdateMeetingDevice" })
        await session.close()
    }

    @Test func aNewManagementSettingUpdatesTheQueueWithoutANewRosterRevision() async throws {
        let guests = [guest(first, 3)]
        let start = snapshot(1, role: 5, management: false, guests: guests)
        let enabled = snapshot(1, role: 5, management: true, spaceVersion: 2, guests: guests)
        let disabled = snapshot(1, role: 5, management: false, spaceVersion: 3, guests: guests)
        let (session, _) = try await connect([start, enabled, disabled])
        await session.refreshState()
        #expect(await session.activities.waitingParticipants.isEmpty)
        await session.refreshState()
        #expect(await session.activities.waitingParticipants.map(\.name) == ["guest-a"])
        await session.refreshState()
        #expect(await session.activities.waitingParticipants.isEmpty)
        await session.close()
    }

    private func connect(
        _ responses: [Result<HTTPResponse, any Error>]
    ) async throws -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + responses + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(
            transport,
            media: NativeFakeMedia(),
            staysWhenAlone: true
        )
        try await session.connect()
        return (session, transport)
    }

    private func snapshot(
        _ version: UInt64, role: UInt64 = 1, management: Bool? = nil,
        spaceVersion: UInt64? = nil, guests: [Data]
    ) -> Result<HTTPResponse, any Error> {
        let own = NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
            + NativeMeetFixture.number(46, role)
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let devices = ([own] + guests).reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
        let space = management.map { enabled in
            let revision = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, spaceVersion ?? version))
            let settings = NativeMeetFixture.number(7, enabled ? 1 : 0)
            let row = NativeMeetFixture.string(1, "spaces/demo")
                + NativeMeetFixture.bytes(6, NativeMeetFixture.bytes(11, settings))
            return NativeMeetFixture.bytes(
                1,
                NativeMeetFixture.bytes(2, revision + NativeMeetFixture.bytes(2, row))
            )
        } ?? Data()
        return NativeMeetFixture.ok(space + NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, devices)))
    }

    private func guest(_ name: String, _ state: UInt64) -> Data {
        NativeMeetFixture.string(1, name)
            + NativeMeetFixture.string(2, String(name.split(separator: "/").last ?? "Guest"))
            + NativeMeetFixture.number(4, state) + NativeMeetFixture.number(46, 3)
    }

    private func singleBody(_ target: String, state: UInt64) -> Data {
        let device = NativeMeetFixture.string(1, target) + NativeMeetFixture.number(4, state)
        return NativeMeetFixture.bytes(1, device) + NativeMeetFixture.bytes(
            2,
            NativeMeetFixture.string(1, "join_state")
        )
    }

    private func bulkBody(_ targets: [String], state: UInt64) -> Data {
        let addresses = targets.reduce(into: NativeMeetFixture.string(1, "spaces/demo")) {
            $0 += NativeMeetFixture.string(2, $1)
        }
        return addresses + NativeMeetFixture.bytes(3, NativeMeetFixture.number(4, state))
            + NativeMeetFixture.bytes(4, NativeMeetFixture.string(1, "join_state"))
    }
}
