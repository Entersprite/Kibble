import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The demo's scripted call: discovery says it is going on, a join reports
/// its devices, and a quiet start of another conversation reports nobody.
@MainActor
struct FixtureStorefrontCallTests {
    @Test func aJoinIntoTheScriptedCallReportsItsDevices() async throws {
        let backend = FakeBackend(world: .acme)
        try await backend.connect()
        let calls = FixtureAudioCallService(world: .acme)
        await Acme.scriptStorefrontCall(backend: backend, calls: calls)
        let found = try await backend.callAvailability(in: Acme.storefront)
        #expect(found.status == .active)
        #expect(found.totalParticipants == 4)
        #expect(try await backend.callAvailability(in: Acme.priceEngine).status == .unknown("unavailable"))

        var events = calls.events.makeAsyncIterator()
        try await calls.startListening()
        _ = await events.next()
        _ = await events.next()
        let id = UUID()
        let target = ConversationCallTarget(conversationID: Acme.storefront, displayName: "storefront-web")
        try await calls.joinConversationCall(to: target, callID: id)
        var phases: [AudioCallPhase] = []
        var devices: [CallParticipantDevice]?
        while devices == nil, let event = await events.next() {
            switch event {
            case let .conversationSnapshot(call): phases.append(call.phase)
            case let .participantsChanged(callID, value) where callID == id: devices = value
            default: break
            }
        }
        #expect(phases == [.connecting, .connected])
        #expect(devices == Acme.storefrontCallDevices)
        // One device is a presentation belonging to another, never a person.
        #expect(devices?.filter(\.isPresentation).count == 1)
        #expect(devices?.contains { $0.microphoneMuted == nil && !$0.isPresentation } == true)
    }

    @Test func theScriptedDevicesAreTheSameEveryRun() {
        #expect(Acme.storefrontCallDevices.map(\.id.uuidString) == [
            "CA110000-0000-0000-0000-000000000001", "CA110000-0000-0000-0000-000000000002",
            "CA110000-0000-0000-0000-000000000003", "CA110000-0000-0000-0000-000000000004",
            "CA110000-0000-0000-0000-000000000005"
        ])
    }
}
