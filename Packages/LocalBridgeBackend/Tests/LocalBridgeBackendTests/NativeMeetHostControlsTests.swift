import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetHostControlsTests {
    @Test func participantCaptureLocksMuteLocallyAndUnlockKeepsTheMicrophoneOff() async throws {
        let locked = snapshot(version: 1, role: 2, management: true, microphone: false, camera: false)
        let unlocked = snapshot(version: 2, role: 2, management: true, microphone: true, camera: true)
        let media = NativeFakeMedia()
        let (session, _) = try await connect([locked, unlocked, locked], media: media)
        await session.refreshState()
        #expect(media.isMicrophoneMuted)
        #expect(media.isConnected)
        #expect(await session.activities.microphoneRestricted == true)
        #expect(await !session.localCapturePermissions.camera)
        await #expect(throws: CallMediaError.captureRestricted) { try await session.setMuted(false) }
        await session.refreshState()
        await session.refreshState()
        #expect(media.capturePermissions == [[false, false], [true, true]])
        #expect(media.isMicrophoneMuted)
        #expect(await session.activities.microphoneRestricted == nil)
        #expect(await session.localCapturePermissions.camera)
        await session.close()
    }

    @Test func aHostCanLockParticipantCaptureWithoutRestrictingTheirOwnDevices() async throws {
        let before = snapshot(version: 1, management: true)
        let locked = snapshot(version: 2, management: true, microphone: false, camera: false)
        let media = NativeFakeMedia()
        let (session, transport) = try await connect(
            [before, NativeMeetFixture.ok(Data()), locked],
            media: media
        )
        try await session.performActivity(CallActivity("allowMicrophone", enabled: false))
        #expect(await session.activities.hostSettings?.microphoneAllowed == false)
        #expect(await session.activities.hostSettings?.cameraAllowed == false)
        #expect(await session.activities.microphoneRestricted == nil)
        #expect(media.capturePermissions.isEmpty)
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("UpdateMeetingSpace") }.count == 1)
        await session.close()
    }

    @Test(arguments: [true, false])
    func screenSharingPolicyWriteNeedsBothScopes(savedEchoMatches: Bool) async throws {
        let initial = snapshot(version: 1, management: true, sharing: true, savedSharing: true)
        let locked = snapshot(version: 2, management: true, sharing: false, savedSharing: !savedEchoMatches)
        let media = NativeFakeMedia()
        let (session, transport) = try await connect(
            [initial, NativeMeetFixture.ok(Data()), locked],
            media: media
        )
        let change = CallActivity("allowScreenSharing", enabled: false)
        if savedEchoMatches {
            try await session.performActivity(change)
        } else {
            await #expect(throws: ChatError.self) { try await session.performActivity(change) }
        }
        #expect(await session.activities.hostSettings?.screenSharingAllowed == false)
        #expect(await session.canStartPresentation)
        #expect(media.presentationPermissions.isEmpty)
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("UpdateMeetingSpace") }.count == 1)
        await session.close()
    }

    @Test func aParticipantCannotStartUntilTheActiveLockIsLifted() async throws {
        let locked = snapshot(version: 1, role: 2, management: true, sharing: false, savedSharing: false)
        let unlocked = snapshot(version: 2, role: 2, management: true, sharing: true, savedSharing: false)
        let media = NativeFakeMedia()
        let (session, transport) = try await connect([locked, unlocked, locked], media: media)
        await session.refreshState()
        await #expect(throws: CallMediaError.sharingRestricted) { try await session.startPresentation(media) }
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("CreateTokenForSecondary") })
        #expect(media.isConnected)
        await session.refreshState()
        await session.refreshState()
        #expect(await session.canStartPresentation)
        #expect(media.presentationPermissions == [false, true])
        await session.close()
    }

    @Test(arguments: [true, false])
    func hostChatChangeNeedsBothTheActiveAndSavedPolicies(savedEchoMatches: Bool) async throws {
        let before = snapshot(version: 1, management: true, chat: 2, savedChat: 2)
        let after = snapshot(version: 2, management: true, chat: 3, savedChat: savedEchoMatches ? 3 : 2)
        let (session, transport) = try await connect([before, before, NativeMeetFixture.ok(Data()), after])
        await session.refreshState()
        #expect(await session.activities.availableActions.contains("allowChatMessages"))
        let change = CallActivity("allowChatMessages", enabled: false)
        if savedEchoMatches {
            try await session.performActivity(change)
        } else {
            await #expect(throws: ChatError.self) { try await session.performActivity(change) }
        }
        let state = await session.activities
        #expect(state.hostSettings?.chatMessagesAllowed == false)
        #expect(state.availableActions.contains("chat"))
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("UpdateMeetingSpace") }.count == 1)
        await session.close()
    }

    @Test func chatLockWithholdsParticipantSendingUntilTheNewerActivePolicyAllowsIt() async throws {
        let blocked = snapshot(version: 1, role: 2, management: true, chat: 3, savedChat: 3)
        let allowed = snapshot(version: 2, role: 2, management: true, chat: 2, savedChat: 3)
        let (session, _) = try await connect([blocked, allowed])
        await session.refreshState()
        #expect(await !session.activities.availableActions.contains("chat"))
        #expect(await session.activities.hostSettings == nil)
        await session.refreshState()
        #expect(await session.activities.availableActions.contains("chat"))
        await session.close()
    }

    @Test func acknowledgedConferenceEndClosesMediaAndClearsTheLocalDevice() async throws {
        let host = snapshot(version: 1, management: true)
        let media = NativeFakeMedia()
        let (session, transport) = try await connect([host, host, NativeMeetFixture.ok(Data())], media: media)
        await session.refreshState()
        #expect(await session.activities.availableActions.contains("endConference"))
        try await session.performActivity(CallActivity("endConference"))
        #expect(await session.state == .ended(.localEnded))
        #expect(await session.cleanupStatus.isConfirmed)
        #expect(await session.device.localDeviceName == nil)
        #expect(await session.activities.hostSettings == nil)
        #expect(!media.isConnected)
        let requests = await transport.sent
        #expect(requests.last?.url.lastPathComponent == "EndConference")
        #expect(requests.last?.body == NativeMeetFixture.string(1, "spaces/demo"))
        await session.close()
        #expect(await transport.sent.count == requests.count)
    }

    @Test(arguments: [false, true])
    func staleHostPermissionOrDisabledManagementKeepsTheCall(roleIsHost: Bool) async throws {
        let host = snapshot(version: 1, management: true)
        let revoked = snapshot(version: 2, role: roleIsHost ? 1 : 2, management: !roleIsHost)
        let media = NativeFakeMedia()
        let (session, transport) = try await connect([host, revoked], media: media)
        await session.refreshState()
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("endConference"))
        }
        #expect(media.isConnected)
        #expect(await !session.activities.availableActions.contains("endConference"))
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("EndConference") })
        await session.close()
    }

    @Test(arguments: [false, true])
    func refusalOrUnexpectedResponseLeavesTheConferenceEndUnconfirmed(httpRefusal: Bool) async throws {
        let host = snapshot(version: 1, management: true)
        let reply = httpRefusal
            ? .success(HTTPResponse(status: 403, headers: HTTPHeaders([]), body: Data()))
            : NativeMeetFixture.ok(NativeMeetFixture.number(1, 1))
        let media = NativeFakeMedia()
        let (session, transport) = try await connect([host, reply], media: media)
        await #expect(throws: (any Error).self) {
            try await session.performActivity(CallActivity("endConference"))
        }
        #expect(media.isConnected)
        #expect(await session.device.localDeviceName != nil)
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("EndConference") }.count == 1)
        await session.close()
        #expect(await session.cleanupStatus.isConfirmed)
        #expect(await transport.sent.last?.url.lastPathComponent == "UpdateMeetingDevice")
    }

    @Test func hostCanEnableManagementAndConfirmReactionLockBeforeLosingAccess() async throws {
        let disabled = snapshot(version: 1, management: false)
        let management = snapshot(version: 2, management: true)
        let locked = snapshot(version: 3, management: true, locked: true)
        let demoted = snapshot(version: 4, role: 2, management: true, locked: true)
        let accepted = NativeMeetFixture.ok(Data())
        let (session, transport) = try await connect([
            disabled, disabled, accepted, management, management, accepted, locked, demoted
        ])
        await session.refreshState()
        let initial = await session.activities
        #expect(initial.hostSettings?.managementEnabled == false)
        #expect(initial.availableActions.contains("hostManagement"))
        #expect(!initial.availableActions.contains("allowReactions"))

        try await session.performActivity(CallActivity("hostManagement"))
        #expect(await session.activities.availableActions.contains("allowReactions"))
        try await session.performActivity(CallActivity("allowReactions", enabled: false))
        let confirmed = await session.activities
        #expect(confirmed.hostSettings?.reactionsAllowed == false)
        #expect(!confirmed.availableActions.contains("react"))
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("hostManagement", enabled: false))
        }
        let updated = await session.activities
        #expect(updated.hostSettings == nil)
        #expect(!updated.availableActions.contains("hostManagement"))
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("UpdateMeetingSpace") }.count == 2)
        await session.close()
    }

    @Test(arguments: [false, true])
    func hostWriteNeedsANewerMatchingReadback(newer: Bool) async throws {
        let before = snapshot(version: 4, management: true)
        let after = snapshot(version: newer ? 5 : 4, management: true, locked: !newer)
        let (session, transport) = try await connect([before, NativeMeetFixture.ok(Data()), after])
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("allowReactions", enabled: false))
        }
        #expect(await session.activities.hostSettings?.reactionsAllowed == true)
        #expect(await transport.sent.filter { $0.url.path.hasSuffix("UpdateMeetingSpace") }.count == 1)
        await session.close()
    }

    @Test func missingFreshLocalRoleNeverSubmitsAWrite() async throws {
        let before = snapshot(version: 1, management: true)
        let missing = snapshot(version: 2, role: nil, management: true)
        let (session, transport) = try await connect([before, missing])
        await session.refreshState()
        #expect(await session.activities.hostSettings != nil)
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("allowReactions", enabled: false))
        }
        #expect(await transport.sent.allSatisfy { !$0.url.path.hasSuffix("UpdateMeetingSpace") })
        await session.close()
    }

    func connect(
        _ responses: [Result<HTTPResponse, any Error>], media: NativeFakeMedia = NativeFakeMedia()
    ) async throws
        -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + responses + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: media)
        try await session.connect()
        return (session, transport)
    }

    func snapshot(
        version: UInt64, role: UInt64? = 1, management: Bool, locked: Bool = false,
        chat: UInt64? = nil, savedChat: UInt64? = nil, sharing: Bool? = nil, savedSharing: Bool? = nil,
        microphone: Bool? = nil, camera: Bool? = nil,
        joining: Bool? = nil, savedJoining: Bool? = nil, waitingRoom: Bool? = nil,
        accessPreset: UInt64? = nil, savedAccessPreset: UInt64? = nil, accessChoices: [UInt64] = [],
        joinPolicy: JoinRequestPolicy? = nil
    ) -> Result<HTTPResponse, any Error> {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        var settings = NativeMeetFixture.number(7, management ? 1 : 0)
            + NativeMeetFixture.number(9, locked ? 1 : 0)
            + (chat.map { NativeMeetFixture.number(38, $0) } ?? Data())
            + (sharing.map { NativeMeetFixture.number(3, $0 ? 0 : 1) } ?? Data())
            + (microphone.map { NativeMeetFixture.number(5, $0 ? 0 : 1) } ?? Data())
            + (camera.map { NativeMeetFixture.number(6, $0 ? 0 : 1) } ?? Data())
        if let joining {
            settings += NativeMeetFixture.number(11, joining ? 1 : 0)
        }
        if let waitingRoom {
            settings += NativeMeetFixture.number(22, waitingRoom ? 1 : 0)
        }
        if let accessPreset {
            settings += NativeMeetFixture.number(12, accessPreset)
        }
        settings += joinPolicy?.active.map { NativeMeetFixture.number(40, $0) } ?? Data()
        settings += joinPolicy?.scaling.map { NativeMeetFixture.number(49, $0) } ?? Data()
        var savedSettings = (savedChat.map { NativeMeetFixture.number(36, $0) } ?? Data())
            + (savedSharing.map { NativeMeetFixture.number(4, $0 ? 0 : 1) } ?? Data())
        savedSettings += joinPolicy?.saved.map { NativeMeetFixture.number(38, $0) } ?? Data()
        if let savedJoining {
            savedSettings += NativeMeetFixture.number(10, savedJoining ? 1 : 0)
        }
        if let savedAccessPreset {
            savedSettings += NativeMeetFixture.number(11, savedAccessPreset)
        }
        let saved = savedSettings.isEmpty ? Data() : NativeMeetFixture.bytes(15, savedSettings)
        let info = accessChoices.reduce(into: NativeMeetFixture.bytes(11, settings)) {
            $0 += NativeMeetFixture.number(27, $1)
        }
        let space = NativeMeetFixture.string(1, "spaces/demo") + NativeMeetFixture.bytes(6, info) + saved
        let local = NativeMeetFixture.string(1, "spaces/demo/devices/one") + NativeMeetFixture.number(4, 1)
            + (role.map { NativeMeetFixture.number(46, $0) } ?? Data())
        let otherHost = NativeMeetFixture.string(1, "spaces/demo/devices/other")
            + NativeMeetFixture.number(4, 1) + NativeMeetFixture.number(46, 5)
        let spaceFull = NativeMeetFixture.bytes(
            1, NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, space))
        )
        let devicesFull = NativeMeetFixture.bytes(
            2,
            NativeMeetFixture.bytes(
                2, metadata + NativeMeetFixture.bytes(2, local) + NativeMeetFixture.bytes(2, otherHost)
            )
        )
        return NativeMeetFixture.ok(spaceFull + devicesFull)
    }
}

extension NativeMeetHostControlsTests {
    @Test(arguments: [true, false])
    func meetingAccessNeedsBothConfirmedScopes(_ savedMatches: Bool) async throws {
        let before = snapshot(
            version: 1, management: false, accessPreset: 2, savedAccessPreset: 2, accessChoices: [1, 2, 3]
        )
        let after = snapshot(
            version: 2, management: false, accessPreset: 3, savedAccessPreset: savedMatches ? 3 : 2,
            accessChoices: [1, 2, 3]
        )
        let (session, transport) = try await connect([before, NativeMeetFixture.ok(Data()), after])
        let update = CallActivity("setMeetingAccess", options: ["restricted"])
        if savedMatches {
            try await session.performActivity(update)
        } else {
            await #expect(throws: ChatError.transport("The host setting change could not be confirmed.")) {
                try await session.performActivity(update)
            }
        }
        #expect(await session.activities.hostSettings?.meetingAccess?.preset == "restricted")
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "UpdateMeetingSpace" }.count == 1)
        await session.close()
    }

    @Test(arguments: [true, false])
    func aFreshOrganizerAndEligibilityListGateTheRequestedAccessPreset(_ roleRetired: Bool) async throws {
        let before = snapshot(
            version: 1, management: true, accessPreset: 2, savedAccessPreset: 2, accessChoices: [1, 2, 3]
        )
        let after = snapshot(
            version: 2, role: roleRetired ? 5 : 1, management: true,
            accessPreset: 2, savedAccessPreset: 2, accessChoices: roleRetired ? [1, 2, 3] : [1, 2]
        )
        let (session, transport) = try await connect([before, after])
        await session.refreshState()
        #expect(await session.activities.availableActions.contains("setMeetingAccess"))
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("setMeetingAccess", options: ["restricted"]))
        }
        #expect(await session.activities.availableActions.contains("setMeetingAccess") == !roleRetired)
        #expect(await transport.sent.allSatisfy { $0.url.lastPathComponent != "UpdateMeetingSpace" })
        await session.close()
    }

    @Test(arguments: [true, false], [true, false])
    func theOrganizerConfirmsBothJoinBeforeHostSettings(_ enabled: Bool, _ savedMatches: Bool) async throws {
        let initial = snapshot(version: 1, management: false, joining: !enabled, savedJoining: !enabled)
        let after = snapshot(
            version: 2, management: false, joining: enabled, savedJoining: savedMatches ? enabled : !enabled
        )
        let (session, transport) = try await connect([initial, NativeMeetFixture.ok(Data()), after])
        let setting = CallActivity("allowJoiningBeforeHost", enabled: enabled)
        if savedMatches {
            try await session.performActivity(setting)
        } else {
            await #expect(throws: ChatError.transport("The host setting change could not be confirmed.")) {
                try await session.performActivity(setting)
            }
        }
        #expect(await session.activities.hostSettings?.joiningBeforeHostAllowed == enabled)
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "UpdateMeetingSpace" }.count == 1)
        await session.close()
    }

    @Test(arguments: ["waiting", "cohost", "missing"])
    func aFreshAdmissionPolicyCanWithholdTheHostFirstWrite(_ scenario: String) async throws {
        let initial = snapshot(
            version: 1,
            management: true,
            joining: true,
            savedJoining: true,
            waitingRoom: false
        )
        let after = snapshot(
            version: 2, role: scenario == "cohost" ? 5 : 1, management: true,
            joining: scenario == "missing" ? nil : true, savedJoining: true,
            waitingRoom: scenario == "waiting"
        )
        let (session, transport) = try await connect([initial, after])
        await session.refreshState()
        #expect(await session.activities.availableActions.contains("allowJoiningBeforeHost"))
        await #expect(throws: ChatError.unsupported(capability: "meetingHostControls")) {
            try await session.performActivity(CallActivity("allowJoiningBeforeHost", enabled: false))
        }
        #expect(await !session.activities.availableActions.contains("allowJoiningBeforeHost"))
        #expect(await session.activities.hostSettings?.waitingRoomEnabled == (scenario == "waiting"))
        #expect(await transport.sent.allSatisfy { $0.url.lastPathComponent != "UpdateMeetingSpace" })
        await session.close()
    }
}
