import ChatKit
import Foundation
import GChatBridgeCore
import Synchronization
import Testing
@testable import LocalBridgeBackend

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeMeetHandModerationTests {
    @Test(arguments: [true, false])
    func moderatorLowersHandsThroughTheExactRouteAndKeepsNewRaises(bulk: Bool) async throws {
        let begin = snapshot(5, hands: ["peer", "other"])
        let after = snapshot(6, hands: bulk ? ["new"] : ["other", "new"])
        let (session, transport) = try await connect([begin, begin, NativeMeetFixture.ok(Data()), after])
        await session.refreshState()
        let peer = try #require(await session.participantHandles["spaces/demo/devices/peer"])
        #expect(await session.activities.availableActions.contains("lowerAllHands"))
        #expect(await session.publishedParticipants?.first { $0.id == peer }?.handRaisedAt
            == Date(timeIntervalSince1970: 1_800_000_000.5))
        let activity = bulk ? CallActivity("lowerAllHands") : CallActivity(
            "lowerParticipantHand",
            resourceID: peer
        )
        try await session.performActivity(activity)
        let requests = await transport.sent
        let request = try #require(requests.first { $0.url.lastPathComponent == handMethod(bulk) })
        #expect(request.body == NativeMeetFixture.string(1, bulk ? "spaces/demo" : "spaces/demo/hands/peer"))
        let handles = await session.participantHandles
        let expected = (bulk ? ["new"] : ["new", "other"]).compactMap { handles["spaces/demo/devices/" + $0] }
        let people = try #require(await session.publishedParticipants)
        #expect(Set(people.filter { $0.handRaised == true }.map(\.id)) == Set(expected))
        #expect(people.first { $0.id == peer }?.handRaised == false)
        await session.close()
    }

    @Test(arguments: ["demoted", "foreign", "stale", "still-raised"])
    func refusesUnsafeTargetsAndDoesNotReplayAnUnconfirmedWrite(_ scenario: String) async throws {
        let begin = snapshot(5, hands: ["peer"])
        let current = snapshot(6, role: scenario == "demoted" ? 3 : 1, hands: ["peer"])
        let writes = ["stale", "still-raised"].contains(scenario)
        let later = writes
            ? [NativeMeetFixture.ok(Data()), snapshot(scenario == "stale" ? 6 : 7, hands: ["peer"])]
            : []
        let (session, transport) = try await connect([begin, current] + later)
        await session.refreshState()
        let peer = try #require(await session.participantHandles["spaces/demo/devices/peer"])
        await #expect(throws: (any Error).self) {
            try await session.performActivity(CallActivity(
                "lowerParticipantHand", resourceID: scenario == "foreign" ? UUID() : peer
            ))
        }
        #expect(await transport.sent.filter { $0.url.lastPathComponent == "DeleteHandRaise" }
            .count == (writes ? 1 : 0))
        #expect(await session.publishedParticipants?.first { $0.id == peer }?.handRaised == true)
        await session.close()
    }

    @Test(arguments: [true, false])
    func aNewerExternalLowerPublishesOneNoticeAndRespectsInactiveRows(inactiveRow: Bool) async throws {
        let raised = snapshot(5, hands: ["one", "peer"])
        let lowered = snapshot(6, hands: inactiveRow ? ["one", "peer"] : ["peer"], inactive: ["one"])
        let (session, _) = try await connect([raised, raised, lowered, lowered])
        await session.refreshState()
        await session.refreshState()
        #expect(await session.activities.ownHandLowered == nil)
        await session.refreshState()
        let event = try #require(await session.activities.ownHandLowered)
        #expect(await session.publishedParticipants?.first(where: \.isLocal)?.handRaised == false)
        #expect(await session.publishedParticipants?.first { !$0.isLocal && $0.handRaised == true } != nil)
        await session.refreshState()
        #expect(await session.activities.ownHandLowered == event)
        await session.close()
        #expect(await session.activities.ownHandLowered == nil)
    }

    @Test(arguments: ["missing", "reconnect", "self", "bulk"])
    func observationGapsAndKibbleCommandsDoNotProduceAnExternalNotice(_ cause: String) async throws {
        let raised = snapshot(5, hands: ["one"])
        let lowered = snapshot(6, hands: [])
        let accepted = NativeMeetFixture.ok(Data())
        let between: [Result<HTTPResponse, any Error>] = switch cause {
        case "missing": [snapshot(5, hands: nil)]
        case "self": [raised, accepted, raised]
        case "bulk": [raised, accepted, lowered]
        default: []
        }
        let (session, _) = try await connect([raised, raised] + between + [lowered])
        await session.refreshState()
        await session.refreshState()
        switch cause {
        case "missing": await session.refreshState()
        case "reconnect":
            await session.mediaEvent(.disconnected)
            await session.mediaEvent(.connected)
        case "self":
            try await session.setHandRaised(false)
            await session.refreshState()
        default: try await session.performActivity(CallActivity("lowerAllHands"))
        }
        await session.refreshState()
        #expect(await session.activities.ownHandLowered == nil)
        #expect(await session.publishedParticipants?.first(where: \.isLocal)?.handRaised == false)
        await session.close()
    }

    @Test(arguments: ["expire", "cancel", "reconnect", "replacement"])
    func automaticLoweringFollowsOnlyTheOriginalHand(_ scenario: String) async throws {
        let clock = Mutex<ContinuousClock.Instant>(.now)
        let media = NativeFakeMedia()
        let raised = snapshot(5, hands: ["one"])
        let later: [Result<HTTPResponse, any Error>] = switch scenario {
        case "expire": [raised, NativeMeetFixture.ok(Data())]
        case "replacement": [snapshot(6, hands: ["one"], localHandSuffix: "-second")]
        default: []
        }
        let (session, transport) = try await connect([raised, raised] + later, media: media) {
            clock.withLock { $0 }
        }
        await session.refreshState()
        await session.refreshState()
        guard !media.isMicrophoneMuted else {
            Issue.record("Fixture microphone must be available")
            return
        }
        for tick in 0 ... 3 {
            media.localAudioSample = CallLocalAudioActivity(level: 0.12, timestamp: Double(tick))
            await session.updateAutomaticHandLowering()
            if tick < 3 {
                #expect(await session.activities.automaticHandLowering == nil)
                clock.withLock { $0 += .seconds(1) }
            }
        }
        let prompt = try #require(await session.activities.automaticHandLowering)
        switch scenario {
        case "cancel":
            try await session.performActivity(CallActivity("keepHandRaised", resourceID: prompt.id))
        case "reconnect":
            await session.mediaEvent(.disconnected)
            await session.mediaEvent(.connected)
        default: break
        }
        clock.withLock { $0 += .seconds(10) }
        await session.updateAutomaticHandLowering()
        #expect(await session.activities.automaticHandLowering == nil)
        let deletes = await transport.sent.filter { $0.url.lastPathComponent == "DeleteHandRaise" }
        #expect(deletes.map(\.body) == (scenario == "expire"
                ? [NativeMeetFixture.string(1, "spaces/demo/hands/one")] : []))
        #expect(await session.activities.ownHandLowered == nil)
        await session.close()
    }

    @Test func quietAndRepeatedAudioSamplesResetTheSpeechInterval() {
        let start = ContinuousClock.Instant.now
        var state = NativeAutomaticHandLowering()
        let activity = CallLocalAudioActivity(level: 0.12, timestamp: 1)
        let initial = state.observe(activity, at: start)
        let repeated = state.observe(activity, at: start + .seconds(3))
        let quiet = state.observe(.init(level: 0, timestamp: 2), at: start + .seconds(4))
        let afterSilence = state.observe(.init(level: 0.12, timestamp: 3), at: start + .seconds(5))
        let afterGap = state.observe(.init(level: 0.12, timestamp: 4), at: start + .seconds(9))
        #expect(!initial && !repeated && !quiet && !afterSilence && !afterGap)
    }

    private func handMethod(_ bulk: Bool) -> String {
        bulk ? "ClearHandRaises" : "DeleteHandRaise"
    }

    private func connect(
        _ later: [Result<HTTPResponse, any Error>], media: NativeFakeMedia = NativeFakeMedia(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    )
        async throws -> (NativeMeetCallSession, ScriptedTransport) {
        let setup = NativeMeetFixture.responses()
        let transport = ScriptedTransport(Array(setup.prefix(4)) + later + Array(setup.suffix(1)))
        let session = try await NativeMeetFixture.session(
            transport,
            media: media,
            staysWhenAlone: true,
            now: now
        )
        try await session.connect()
        return (session, transport)
    }

    private func snapshot(
        _ version: UInt64,
        role: UInt64 = 1,
        hands: [String]?,
        inactive: Set<String> = [],
        localHandSuffix: String = ""
    ) -> Result<HTTPResponse, any Error> {
        let devices = [device("one", role: role), device("peer"), device("other"), device("new")]
        let roster = collection(2, version, devices)
        guard let hands else { return NativeMeetFixture.ok(roster) }
        let time = NativeMeetFixture.number(1, 1_800_000_000) + NativeMeetFixture.number(2, 500_000_000)
        let records = hands.map {
            let name = $0 + ($0 == "one" ? localHandSuffix : "")
            return NativeMeetFixture.string(1, "spaces/demo/hands/" + name) + NativeMeetFixture.bytes(2, time)
                + NativeMeetFixture.number(3, inactive.contains($0) ? 0 : 1)
                + NativeMeetFixture.string(4, "spaces/demo/devices/" + $0)
        }
        return NativeMeetFixture.ok(roster + collection(10, version, records))
    }

    private func device(_ name: String, role: UInt64 = 3) -> Data {
        NativeMeetFixture.string(1, "spaces/demo/devices/" + name)
            + NativeMeetFixture.number(4, 1) + NativeMeetFixture.number(46, role)
    }

    private func collection(_ field: UInt64, _ version: UInt64, _ values: [Data]) -> Data {
        let metadata = NativeMeetFixture.bytes(1, NativeMeetFixture.number(1, version))
        let full = values.reduce(into: metadata) { $0 += NativeMeetFixture.bytes(2, $1) }
        return NativeMeetFixture.bytes(field, NativeMeetFixture.bytes(2, full))
    }
}
