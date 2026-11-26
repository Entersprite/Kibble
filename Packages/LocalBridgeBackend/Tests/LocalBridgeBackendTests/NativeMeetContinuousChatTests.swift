import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
struct NativeMeetContinuousChatTests {
    @Test(arguments: [UInt64(0), 1, 2, 9])
    func onlyTheLocalDevicesExplicitChatEligibilityCanAssociateAConversation(_ eligibility: UInt64)
        async throws {
        let session = try await connect([snapshot(1, eligibility: eligibility, group: "Room_A")])
        await session.refreshState()
        let expected = eligibility == 1
            ? CallMeetingChat(conversationID: .init("space/Room_A"), canSend: true) : nil
        #expect(await session.activities.meetingChat == expected)
        #expect(await session.activities.availableActions.contains("chat"))
        await session.close()
        #expect(await session.activities.meetingChat == nil)
    }

    @Test func theRouteFollowsVersionedGroupEligibilityAndPostingPolicy() async throws {
        let session = try await connect([
            snapshot(3, eligibility: 1, group: "First"),
            snapshot(4, eligibility: 1, group: "Wrong", spaceVersion: 2),
            snapshot(5, eligibility: 2, group: "First"),
            snapshot(6, eligibility: 1, group: "Second", sendPolicy: 3),
            snapshot(7, eligibility: 1, group: "space/invalid"),
            snapshot(8, eligibility: 1, group: "Third", sendPolicy: 2, legacyLock: true),
            snapshot(9, eligibility: 1, group: nil)
        ])
        let routes: [CallMeetingChat?] = [
            .init(conversationID: .init("space/First"), canSend: true),
            .init(conversationID: .init("space/First"), canSend: true),
            nil,
            .init(conversationID: .init("space/Second"), canSend: false),
            nil,
            .init(conversationID: .init("space/Third"), canSend: false),
            nil
        ]
        for route in routes {
            await session.refreshState()
            #expect(await session.activities.meetingChat == route)
        }
        await session.close()
    }

    private func connect(_ reads: [Result<HTTPResponse, any Error>]) async throws -> NativeMeetCallSession {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + reads + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(
            transport,
            media: NativeFakeMedia(),
            staysWhenAlone: true
        )
        try await session.connect()
        return session
    }

    private func snapshot(
        _ version: UInt64, eligibility: UInt64, group: String?, spaceVersion: UInt64? = nil,
        sendPolicy: UInt64 = 2, legacyLock: Bool = false
    ) -> Result<HTTPResponse, any Error> {
        let own = device("one", eligibility: eligibility)
        let browser = device("browser", eligibility: 1)
        let devices = metadata(version) + NativeMeetFixture.bytes(2, own) + NativeMeetFixture.bytes(
            2,
            browser
        )
        let settings = NativeMeetFixture.number(38, sendPolicy) + NativeMeetFixture.number(
            2,
            legacyLock ? 1 : 0
        )
        var info = NativeMeetFixture.bytes(11, settings)
        if let group {
            info += NativeMeetFixture.bytes(34, NativeMeetFixture.string(1, group))
        }
        let space = NativeMeetFixture.string(1, "spaces/demo") + NativeMeetFixture.bytes(6, info)
        let full = metadata(spaceVersion ?? version) + NativeMeetFixture.bytes(2, space)
        return NativeMeetFixture.ok(NativeMeetFixture.bytes(1, NativeMeetFixture.bytes(2, full))
            + NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, devices)))
    }

    private func device(_ id: String, eligibility: UInt64) -> Data {
        NativeMeetFixture.string(1, "spaces/demo/devices/" + id)
            + NativeMeetFixture.number(4, 1) + NativeMeetFixture.number(46, 3)
            + NativeMeetFixture.number(64, eligibility)
    }

    private func metadata(_ version: UInt64) -> Data {
        NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
    }
}
