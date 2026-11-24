import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetSharedPinsTests {
    @Test(arguments: [true, false], [UInt64(1), 5])
    func updatesOnlyTheAddressedTileAndPublishesNewerReadback(pinned: Bool, role: UInt64) async throws {
        let target = pinned ? "peer" : "presentation"
        let local = device("one", role: role, grant: packedGrant)
        let others = [device("peer", pinned: false), device("presentation", pinned: true, parent: "peer")]
        let begin = snapshot(5, [local] + others)
        let updated = device(target, pinned: pinned, parent: target == "presentation" ? "peer" : nil)
        let sibling = target == "peer" ? others[1] : others[0]
        let (session, transport) = try await connect([
            begin,
            begin,
            NativeMeetFixture.ok(updated),
            snapshot(6, [local, updated, sibling])
        ])
        await session.refreshState()
        #expect(await session.activities.availableActions.contains("setPinForEveryone"))
        let id = try #require(await session.participantHandles["spaces/demo/devices/" + target])
        try await session.performActivity(CallActivity("setPinForEveryone", resourceID: id, enabled: pinned))
        let request = try #require(await transport.sent.first { $0.body == patch(target, pinned: pinned) })
        #expect(request.url.lastPathComponent == "UpdateMeetingDevice")
        #expect(request.headers["x-goog-ext-174067345-bin"] == "CgIIAw==")
        #expect(await transport.sent.count == 8)
        let people = await session.publishedParticipants
        #expect(people?.first(where: { $0.id == id })?.isPinnedForEveryone == pinned)
        #expect(people?.filter { $0.isPinnedForEveryone == true }.count == (pinned ? 2 : 0))
        await session.close()
    }

    @Test(arguments: [
        "no-grant",
        "other-role",
        "other-grant",
        "capacity",
        "unknown-state",
        "stale",
        "foreign"
    ])
    func requiresFreshPermissionBoundedPinsAndExactAddressedConfirmation(_ scenario: String) async throws {
        let local = device("one", role: 1, grant: packedGrant)
        let begin = snapshot(5, [local, device("peer")])
        let target = device("peer") + (scenario == "unknown-state"
            ? NativeMeetFixture.bytes(52, NativeMeetFixture.number(1, 9)) : Data())
        let scoped = device(
            "one",
            role: scenario == "other-role" ? 3 : 1,
            grant: ["no-grant", "other-grant"].contains(scenario) ? Data() : packedGrant
        )
        let extra = (scenario == "capacity" ? ["a", "b", "c"] : []).map { device($0, pinned: true) }
        let otherGrant = scenario == "other-grant" ? [device("other", role: 5, grant: packedGrant)] : []
        let current = snapshot(6, [scoped, target] + extra + otherGrant)
        let writes = ["stale", "foreign"].contains(scenario)
        var responses = [begin, current]
        if writes {
            responses.append(NativeMeetFixture.ok(device(
                scenario == "foreign" ? "other" : "peer",
                pinned: true
            )))
            if scenario == "stale" {
                responses.append(snapshot(6, [scoped, device("peer", pinned: true)]))
            }
        }
        let (session, transport) = try await connect(responses)
        await session.refreshState()
        let id = try #require(await session.participantHandles["spaces/demo/devices/peer"])
        await #expect(throws: (any Error).self) {
            try await session.performActivity(CallActivity("setPinForEveryone", resourceID: id))
        }
        #expect(await transport.sent.filter { $0.body == patch("peer", pinned: true) }
            .count == (writes ? 1 : 0))
        #expect(await session.publishedParticipants?.first { $0.id == id }?.isPinnedForEveryone == false)
        await session.close()
    }

    private var packedGrant: Data {
        NativeMeetFixture.bytes(13, Data([1, 82]))
    }

    private func connect(_ later: [Result<HTTPResponse, any Error>])
        async throws -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + later + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(
            transport,
            media: NativeFakeMedia(),
            staysWhenAlone: true
        )
        try await session.connect()
        return (session, transport)
    }

    private func snapshot(_ version: UInt64, _ devices: [Data]) -> Result<HTTPResponse, any Error> {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let full = devices.reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
        return NativeMeetFixture.ok(NativeMeetFixture.bytes(2, NativeMeetFixture.bytes(2, full)))
    }

    private func device(
        _ id: String, role: UInt64 = 3, grant: Data = Data(), pinned: Bool = false, parent: String? = nil
    ) -> Data {
        var value = NativeMeetFixture.string(1, "spaces/demo/devices/" + id)
            + NativeMeetFixture.number(4, 1) + NativeMeetFixture.number(46, role) + grant
        if let parent {
            value += NativeMeetFixture.string(21, "spaces/demo/devices/" + parent)
                + NativeMeetFixture.number(25, 2)
        }
        if pinned {
            value += NativeMeetFixture.bytes(52, NativeMeetFixture.number(1, 1))
        }
        return value
    }

    private func patch(_ id: String, pinned: Bool) -> Data {
        var value = NativeMeetFixture.string(1, "spaces/demo/devices/" + id)
        if pinned {
            value += NativeMeetFixture.bytes(52, NativeMeetFixture.number(1, 1))
        }
        return NativeMeetFixture.bytes(1, value)
            + NativeMeetFixture.bytes(2, NativeMeetFixture.string(1, "spotlight_info"))
    }
}
