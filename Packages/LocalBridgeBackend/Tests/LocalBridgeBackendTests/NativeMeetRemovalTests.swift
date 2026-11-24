import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetRemovalTests {
    private let own = "spaces/demo/devices/one"
    private let peer = "spaces/demo/devices/two"
    private let third = "spaces/demo/devices/three"

    @Test(arguments: [true, false])
    func aGrantedDeviceRemovesTheSelectedParticipantAndKeepsTheOthers(managed: Bool) async throws {
        let grant = managed ? NativeMeetFixture.number(13, 1) : NativeMeetFixture.bytes(13, Data([2, 1]))
        let local = device(own, role: managed ? 5 : 3) + grant
        let start = snapshot(1, local: local, peers: [device(peer), device(third)], managed: managed)
        let receipt = NativeMeetFixture.ok(device(peer, state: 7))
        let after = snapshot(
            2,
            local: local,
            peers: [device(peer, state: 7), device(third)],
            managed: managed
        )
        let media = NativeFakeMedia()
        let (session, transport) = try await connect([start, start, receipt, after], media: media)
        await session.refreshState()
        let id = try #require(await session.participantHandles[peer])
        #expect(await session.activities.availableActions.contains("removeParticipant"))
        try await session.performActivity(CallActivity("removeParticipant", resourceID: id))
        let request = try #require(await transport.sent.last)
        #expect(request.url.lastPathComponent == "UpdateMeetingDevice")
        #expect(request.headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        #expect(request.body == NativeMeetFixture.bytes(
            1,
            NativeMeetFixture.string(1, peer) + NativeMeetFixture
                .number(
                    4,
                    7
                )
        )
            + NativeMeetFixture.bytes(2, NativeMeetFixture.string(1, "join_state")))
        #expect(await session.publishedParticipants?.contains { $0.id == id } == true)
        await session.refreshState()
        #expect(await session.participantHandles[peer] == nil)
        #expect(await session.publishedParticipants?.count == 2)
        #expect(media.isConnected)
        await session.close()
    }

    @Test(arguments: ["lost-authority", "malformed-grant", "departed", "presenter", "self", "unknown"])
    func preflightWithholdsRemovalForInvalidAuthorityOrTargets(_ scenario: String) async throws {
        let grant = NativeMeetFixture.number(13, 1)
        let start = snapshot(1, local: device(own, role: 1) + grant)
        let refreshedGrant = switch scenario {
        case "lost-authority": Data()
        case "malformed-grant": NativeMeetFixture.bytes(13, Data([1, 0x80]))
        default: grant
        }
        let checked = snapshot(2, local: device(own, role: 1) + refreshedGrant, peers: [
            device(peer, state: scenario == "departed" ? 6 : 1)
                + (scenario == "presenter" ? NativeMeetFixture.number(25, 2) : Data())
        ])
        let (session, transport) = try await connect([start, checked])
        await session.refreshState()
        let handle = scenario == "self" ? own : peer
        let id = try #require(await session.participantHandles[handle])
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity(
                "removeParticipant", resourceID: scenario == "unknown" ? UUID() : id
            ))
        }
        #expect(await transport.sent.dropFirst(4)
            .allSatisfy { $0.url.lastPathComponent != "UpdateMeetingDevice" })
        await session.close()
    }

    @Test(arguments: ["wrong-target", "waiting-room", "still-joined"])
    func removalNeedsAnExactOrdinaryEjectionReceipt(_ scenario: String) async throws {
        let start = snapshot(1, local: device(own, role: 1) + NativeMeetFixture.number(13, 1))
        let echo = device(
            scenario == "wrong-target" ? third : peer,
            state: scenario == "still-joined" ? 1 : 7,
            reason: scenario == "waiting-room" ? 9 : nil
        )
        let media = NativeFakeMedia()
        let (session, transport) = try await connect([start, start, NativeMeetFixture.ok(echo)], media: media)
        await session.refreshState()
        let id = try #require(await session.participantHandles[peer])
        await #expect(throws: MeetCallWire.WireError.malformedResponse) {
            try await session.performActivity(CallActivity("removeParticipant", resourceID: id))
        }
        #expect(await session.publishedParticipants?.contains { $0.id == id } == true)
        #expect(await transport.sent.dropFirst(4).filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
            .count == 1)
        #expect(media.isConnected)
        await session.close()
    }

    @Test(arguments: [true, false], [UInt64(0), 9])
    func transportFailureConfirmsAnEjectionOnlyFromANewerOwnDevice(newer: Bool, reason: UInt64) async throws {
        let start = snapshot(1, local: device(own))
        let ejected = snapshot(newer ? 2 : 1, local: device(own, state: 7, reason: reason))
        let media = NativeFakeMedia()
        let (session, transport) = try await connect([start, ejected], media: media)
        await session.refreshState()
        await session.mediaEvent(.failed)
        let outcome: MeetNativeCallEndReason = reason == 9 ? .sentToWaitingRoom : .removedFromMeeting
        #expect(await session.state == .ended(newer ? outcome : .transportFailed))
        #expect(await session.device.localDeviceName == nil)
        #expect(!media.isConnected)
        let probe = try #require(await transport.sent
            .last { $0.url.lastPathComponent == "SyncMeetingSpaceCollections" })
        #expect(probe.timeout == .seconds(2))
        #expect(probe.url.lastPathComponent == "SyncMeetingSpaceCollections")
        #expect(await transport.sent.dropFirst(4).filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
            .count == (newer ? 0 : 1))
    }

    @Test(arguments: [UInt64(6), 11])
    func otherProviderExitReasonsAreDistinctFromRemoval(_ reason: UInt64) async throws {
        let (session, transport) = try await connect([snapshot(
            1,
            local: device(own, state: 7, reason: reason)
        )])
        await session.refreshState()
        #expect(await session.state == .ended(.deviceEnded))
        #expect(await session.cleanupStatus.isConfirmed)
        #expect(await transport.sent.last?.url.lastPathComponent == "UpdateMeetingDevice")
    }

    @Test func observingOwnMoveSettlesTheOldRegistrationWithoutALeave() async throws {
        let changed = snapshot(1, local: device(own, state: 7, reason: 9))
        let (session, transport) = try await connect([changed])
        await session.refreshState()
        #expect(await session.state == .ended(.sentToWaitingRoom))
        #expect(await session.cleanupStatus.isConfirmed)
        #expect(await transport.sent.last?.url.lastPathComponent == "SyncMeetingSpaceCollections")
    }

    @Test(arguments: [true, false])
    func movingUsesTheExactTwoMasksAndWaitsForTheRoster(_ packedCapability: Bool) async throws {
        let local = device(own, role: 1) + NativeMeetFixture.number(13, 1)
        let compatible = device(peer) + (packedCapability ? NativeMeetFixture.bytes(39, Data([22]))
            : NativeMeetFixture.number(39, 22))
        let remaining = device("spaces/demo/devices/another")
        let start = snapshot(1, local: local, peers: [compatible, remaining, device(third, state: 13)])
        let moved = device(peer, state: 7, reason: 9)
        let replacement = device("spaces/demo/devices/guest-waiting", state: 13)
        let after = snapshot(
            2,
            local: local,
            peers: [moved, remaining, replacement, device(third, state: 13)]
        )
        let media = NativeFakeMedia()
        let (session, transport) = try await connect(
            [start, start, NativeMeetFixture.ok(moved), after],
            media: media
        )
        await session.refreshState()
        let id = try #require(await session.participantHandles[peer])
        #expect(await session.publishedParticipants?.first { $0.id == id }?.canSendToWaitingRoom == true)
        try await session.performActivity(CallActivity("sendParticipantToWaitingRoom", resourceID: id))
        let request = try #require(await transport.sent.last)
        #expect(request.url.lastPathComponent == "UpdateMeetingDevice")
        #expect(request.headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        let patch = NativeMeetFixture.string(1, peer) + NativeMeetFixture.number(4, 7)
            + NativeMeetFixture.number(28, 9)
        let mask = NativeMeetFixture.string(1, "join_state") + NativeMeetFixture.string(
            1,
            "final_state_reason"
        )
        #expect(request.body == NativeMeetFixture.bytes(1, patch) + NativeMeetFixture.bytes(2, mask))
        #expect(await session.publishedParticipants?.contains { $0.id == id } == true)
        await session.refreshState()
        #expect(await session.participantHandles[peer] == nil)
        #expect(await session.activities.waitingParticipants.count == 2)
        #expect(await session.state == .active)
        #expect(media.isConnected)
        await session.close()
    }

    @Test(arguments: [
        "cohost",
        "revoked",
        "empty-room",
        "knocking",
        "malformed",
        "stale",
        "ordinary-receipt"
    ])
    func waitingRoomMoveRequiresFreshHostTargetRoomAndReceipt(_ scenario: String) async throws {
        let grant = NativeMeetFixture.number(13, 1)
        let capability = NativeMeetFixture.number(39, 22)
        let start = snapshot(2, local: device(own, role: 1) + grant, peers: [
            device(peer) + capability, device(third, state: 13)
        ])
        let local = device(own, role: scenario == "cohost" ? 5 : 1)
            + (scenario == "revoked" ? Data() : grant)
        let target = device(peer) + (scenario == "malformed" ? NativeMeetFixture.bytes(39, Data([22, 128]))
            : capability)
        let waiting = device(third, state: scenario == "knocking" ? 3 : 13)
        let refreshed = snapshot(
            scenario == "stale" ? 1 : 3, local: local,
            peers: scenario == "empty-room" ? [target] : [target, waiting]
        )
        let replies = scenario == "ordinary-receipt" ? [NativeMeetFixture.ok(device(peer, state: 7))] : []
        let (session, transport) = try await connect([start, refreshed] + replies)
        await session.refreshState()
        let id = try #require(await session.participantHandles[peer])
        let action = CallActivity("sendParticipantToWaitingRoom", resourceID: id)
        if scenario == "ordinary-receipt" {
            await #expect(throws: MeetCallWire.WireError.malformedResponse) {
                try await session.performActivity(action)
            }
        } else {
            await #expect(throws: ChatError.self) { try await session.performActivity(action) }
        }
        let writes = await transport.sent.dropFirst(4)
            .filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
        #expect(writes.count == (scenario == "ordinary-receipt" ? 1 : 0))
        await session.close()
    }

    @Test(arguments: ["enabled", "disabled", "missing", "malformed", "stale"])
    func aRoomSettingCanAuthorizeTheFirstMoveAndIsRecheckedBeforeWriting(_ scenario: String) async throws {
        let local = device(own, role: 1) + NativeMeetFixture.number(13, 1)
        let target = device(peer) + NativeMeetFixture.number(39, 22)
        let enabled = NativeMeetFixture.number(22, 1)
        let start = snapshot(2, local: local, peers: [target], waitingRoom: enabled)
        let setting: Data? = switch scenario {
        case "disabled": NativeMeetFixture.number(22, 0)
        case "malformed": NativeMeetFixture.number(22, 2)
        case "missing": nil
        default: enabled
        }
        let current = snapshot(
            3, local: local,
            peers: scenario == "disabled" ? [target, device(third, state: 13)] : [target],
            waitingRoom: setting, spaceVersion: scenario == "stale" ? 1 : nil
        )
        let succeeds = scenario == "enabled"
        let replies = succeeds ? [NativeMeetFixture.ok(device(peer, state: 7, reason: 9))] : []
        let (session, transport) = try await connect([start, current] + replies)
        await session.refreshState()
        let id = try #require(await session.participantHandles[peer])
        let row = await session.publishedParticipants?.first { $0.id == id }
        #expect(row?.canSendToWaitingRoom == true)
        #expect(await session.activities.waitingParticipants.isEmpty)
        let action = CallActivity("sendParticipantToWaitingRoom", resourceID: id)
        if succeeds {
            try await session.performActivity(action)
        } else {
            await #expect(throws: ChatError.self) { try await session.performActivity(action) }
        }
        let writes = await transport.sent.dropFirst(4)
            .filter { $0.url.lastPathComponent == "UpdateMeetingDevice" }
        #expect(writes.count == (succeeds ? 1 : 0))
        await session.close()
    }

    private func connect(
        _ responses: [Result<HTTPResponse, any Error>], media: NativeFakeMedia = NativeFakeMedia()
    ) async throws -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + responses + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        return (session, transport)
    }

    private func snapshot(
        _ version: UInt64, local: Data, peers: [Data]? = nil, managed: Bool = true,
        waitingRoom: Data? = nil, spaceVersion: UInt64? = nil
    )
        -> Result<HTTPResponse, any Error> {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let spaceMetadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, spaceVersion ?? version))
        let settings = NativeMeetFixture.bytes(
            11,
            NativeMeetFixture.number(7, managed ? 1 : 0) + (waitingRoom ?? Data())
        )
        let space = NativeMeetFixture.string(1, "spaces/demo") + NativeMeetFixture.bytes(6, settings)
        let devices = ([local] + (peers ?? [device(peer)])).reduce(into: metadata) {
            $0 += NativeMeetFixture.bytes(2, $1)
        }
        return NativeMeetFixture.ok(
            NativeMeetFixture.bytes(
                1,
                NativeMeetFixture.bytes(2, spaceMetadata + NativeMeetFixture.bytes(2, space))
            )
                + NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, devices))
        )
    }

    private func device(_ name: String, role: UInt64 = 3, state: UInt64 = 1, reason: UInt64? = nil) -> Data {
        NativeMeetFixture.string(1, name) + NativeMeetFixture.number(4, state)
            + NativeMeetFixture.number(46, role) + (reason.map { NativeMeetFixture.number(28, $0) } ?? Data())
    }
}
