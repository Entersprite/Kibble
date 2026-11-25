import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

extension NativeMeetHostControlsTests {
    struct JoinRequestPolicy {
        let active: UInt64?
        let saved: UInt64?
        let scaling: UInt64?
    }

    @Test(arguments: [true, false], [true, false])
    func joinRequestsNeedNewerActiveAndSavedReadback(_ enabled: Bool, _ savedMatches: Bool) async throws {
        let requested: UInt64 = enabled ? 2 : 1
        let previous: UInt64 = enabled ? 1 : 2
        let before = snapshot(
            version: 1, management: false, accessPreset: 2,
            joinPolicy: .init(active: previous, saved: previous, scaling: 1)
        )
        let after = snapshot(
            version: 2, management: false, accessPreset: 2,
            joinPolicy: .init(active: requested, saved: savedMatches ? requested : previous, scaling: 1)
        )
        let (session, transport) = try await connect([before, NativeMeetFixture.ok(Data()), after])
        let change = CallActivity("allowJoinRequests", enabled: enabled)
        if savedMatches {
            try await session.performActivity(change)
        } else {
            await #expect(throws: ChatError.transport("The host setting change could not be confirmed.")) {
                try await session.performActivity(change)
            }
        }
        #expect(await session.activities.hostSettings?.meetingAccess?.joinRequestsAllowed == enabled)
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "UpdateMeetingSpace" }.count == 1)
        await session.close()
    }

    @Test(arguments: ["open", "cohost", "adaptive", "unknown"])
    func freshMeetingStateCanWithholdAJoinRequestWrite(_ newPolicy: String) async throws {
        let before = snapshot(
            version: 1, management: true, accessPreset: 3,
            joinPolicy: .init(active: 2, saved: 2, scaling: 1)
        )
        let after = snapshot(
            version: 2, role: newPolicy == "cohost" ? 5 : 1, management: true,
            accessPreset: newPolicy == "open" ? 1 : 3,
            joinPolicy: .init(
                active: newPolicy == "unknown" ? nil : 2, saved: 2, scaling: newPolicy == "adaptive" ? 2 : 1
            )
        )
        let (session, transport) = try await connect([before, after])
        await session.refreshState()
        #expect(await session.activities.availableActions.contains("allowJoinRequests"))
        await #expect(throws: ChatError.unsupported(capability: "meetingHostControls")) {
            try await session.performActivity(CallActivity("allowJoinRequests", enabled: false))
        }
        #expect(await !session.activities.availableActions.contains("allowJoinRequests"))
        #expect(await transport.sent.allSatisfy { $0.url.lastPathComponent != "UpdateMeetingSpace" })
        await session.close()
    }

    @Test func hostFirstRefusalSurvivesAnArtifactPolicyRefresh() async throws {
        let before = snapshot(version: 1, management: false, joining: true, savedJoining: true)
        let refreshed = snapshot(version: 2, management: false, joining: true, savedJoining: true)
        let refusal = HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data())
        let (session, transport) = try await connect([
            before, before, .success(refusal),
            NativeMeetFixture.ok(NativeMeetFixture.number(48, 2)),
            NativeMeetFixture.ok(NativeMeetFixture.number(1, 2)), refreshed, NativeMeetFixture.ok(Data())
        ])
        let setting = CallActivity("allowJoiningBeforeHost", enabled: false)
        await session.refreshState()
        #expect(await session.activities.availableActions.contains(setting.action))
        await #expect(throws: MeetCallClientError.self) { try await session.performActivity(setting) }
        #expect(await !session.activities.availableActions.contains(setting.action))

        try await session.performActivity(CallActivity("refresh", enabled: true))
        await session.agendaArtifactRead?.value
        #expect(await !session.activities.availableActions.contains("transcription"))
        #expect(await !session.activities.availableActions.contains(setting.action))
        await #expect(throws: ChatError.unsupported(capability: "meetingHostControls")) {
            try await session.performActivity(setting)
        }
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "UpdateMeetingSpace" }.count == 1)
        await session.close()
        #expect(await session.cleanupStatus.isConfirmed)
    }
}
