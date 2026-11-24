import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetCohostTests {
    private let target = "spaces/demo/devices/two"

    @Test(arguments: [true, false])
    func hostChangesTheAddressedRoleAndPublishesNewerRoster(_ enabled: Bool) async throws {
        let before: UInt64 = enabled ? 3 : 5
        let after: UInt64 = enabled ? 5 : 3
        let start = snapshot(1, targetRole: before)
        let receipt = NativeMeetFixture.ok(NativeMeetFixture.bytes(1, participant(target, role: after)))
        let confirmed = snapshot(2, targetRole: after)
        let (session, transport) = try await connect([start, start, receipt, confirmed, start, confirmed])
        let previous = try #require(await participant(in: session))
        #expect(await session.activities.availableActions.contains("setCohost"))
        try await session.performActivity(CallActivity(
            "setCohost",
            resourceID: previous.id,
            enabled: enabled
        ))
        #expect(await participant(in: session)?.role == (enabled ? .cohost : .participant))
        await session.refreshState()
        await session.refreshState()
        #expect(await participant(in: session)?.id == previous.id)
        #expect(await participant(in: session)?.role == (enabled ? .cohost : .participant))
        let request = try #require(await transport.sent
            .first { $0.url.lastPathComponent == "ChangeMeetingRole" })
        #expect(request.body == NativeMeetFixture.string(1, target) + NativeMeetFixture.number(2, after))
        #expect(request.headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "ChangeMeetingRole" }.count == 1)
        await session.close()
    }

    @Test(arguments: ["cohost", "host-off", "departed", "view-only", "presentation", "host-target"])
    func changedAuthorityOrTargetCannotWrite(_ caseName: String) async throws {
        let start = snapshot(1, targetRole: 3)
        let before = snapshot(
            2, targetRole: caseName == "host-target" ? 1 : caseName == "view-only" ? 4 : 3,
            localRole: caseName == "cohost" ? 5 : 1, management: caseName != "host-off",
            targetState: caseName == "departed" ? 6 : 1, presentation: caseName == "presentation"
        )
        let (session, transport) = try await connect([start, before])
        let id = try #require(await participant(in: session)?.id)
        await #expect(throws: ChatError.self) {
            try await session.performActivity(CallActivity("setCohost", resourceID: id))
        }
        #expect(await transport.sent.allSatisfy { $0.url.lastPathComponent != "ChangeMeetingRole" })
        await session.close()
    }

    @Test(arguments: ["stale", "unchanged", "wrong-device-receipt"])
    func roleChangeRequiresMatchingNewerConfirmation(_ caseName: String) async throws {
        let before = snapshot(1, targetRole: 3)
        let receipt = caseName == "wrong-device-receipt"
            ? NativeMeetFixture.ok(NativeMeetFixture.bytes(
                1,
                participant("spaces/demo/devices/other", role: 5)
            ))
            : NativeMeetFixture.ok(Data())
        let readback = snapshot(caseName == "stale" ? 1 : 2, targetRole: caseName == "unchanged" ? 3 : 5)
        let (session, transport) = try await connect(
            caseName == "wrong-device-receipt" ? [before, before, receipt] : [
                before,
                before,
                receipt,
                readback
            ]
        )
        let id = try #require(await participant(in: session)?.id)
        await #expect(throws: (any Error).self) {
            try await session.performActivity(CallActivity("setCohost", resourceID: id))
        }
        #expect(await participant(in: session)?.role == .participant)
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "ChangeMeetingRole" }.count == 1)
        await session.close()
    }

    private func connect(_ responses: [Result<HTTPResponse, any Error>]) async throws
        -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + responses + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(transport, media: NativeFakeMedia())
        try await session.connect()
        await session.refreshState()
        return (session, transport)
    }

    private func participant(in session: NativeMeetCallSession) async -> CallParticipantDevice? {
        await session.publishedParticipants?.first { !$0.isLocal && !$0.isPresentation }
    }

    private func snapshot(
        _ version: UInt64, targetRole: UInt64, localRole: UInt64 = 1, management: Bool = true,
        targetState: UInt64 = 1, presentation: Bool = false
    ) -> Result<HTTPResponse, any Error> {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let settings = NativeMeetFixture.number(7, management ? 1 : 0)
        let space = NativeMeetFixture.string(1, "spaces/demo")
            + NativeMeetFixture.bytes(6, NativeMeetFixture.bytes(11, settings))
        let local = participant("spaces/demo/devices/one", role: localRole)
        let peer = participant(target, role: targetRole, state: targetState)
            + (presentation ? NativeMeetFixture.number(25, 2) : Data())
        let spaceFull = NativeMeetFixture.bytes(
            1, NativeMeetFixture.bytes(2, metadata + NativeMeetFixture.bytes(2, space))
        )
        let devicesFull = NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(
            2, metadata + NativeMeetFixture.bytes(2, local) + NativeMeetFixture.bytes(2, peer)
        ))
        return NativeMeetFixture.ok(spaceFull + devicesFull)
    }

    private func participant(_ name: String, role: UInt64, state: UInt64 = 1) -> Data {
        NativeMeetFixture.string(1, name) + NativeMeetFixture.number(4, state)
            + NativeMeetFixture.number(46, role)
    }
}
