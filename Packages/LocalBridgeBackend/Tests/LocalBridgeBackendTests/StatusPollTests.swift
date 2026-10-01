import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Statuses from the same `get_user_presence` poll: emitted on change, cleared
/// when they go, withdrawn when a poll fails.
@Suite(.timeLimit(.minutes(1)))
struct StatusPollTests: PresencePollFixtures {
    private func statuses(in events: [ChatEvent]) -> [ChatKit.Member.ID: [MemberStatus?]] {
        var result: [ChatKit.Member.ID: [MemberStatus?]] = [:]
        for case let .statusChanged(member, status) in events {
            result[member, default: []].append(status)
        }
        return result
    }

    private func vacation(_ text: String) -> MemberStatus {
        MemberStatus(emoji: "🌴", text: text)
    }

    /// Set, unchanged, changed, cleared: three events, not four. Someone who
    /// never had a status emits nothing when answered with none. Deleting the
    /// change check turns this red.
    @Test func aStatusIsEmittedOnChangeAndCleared() async throws {
        let transport = try transport([
            .statuses(["u-1": "Lunch", "u-2": nil]),
            .statuses(["u-1": "Lunch", "u-2": nil]),
            .statuses(["u-1": "Back at 3", "u-2": nil]),
            .statuses(["u-1": nil, "u-2": nil])
        ])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(5, on: transport)
        let events = await log.settle()

        #expect(statuses(in: events)[ada] == [vacation("Lunch"), vacation("Back at 3"), nil])
        #expect(statuses(in: events)[grace] == nil)
        await backend.disconnect()
    }

    /// Someone answered with a status and then missing from an answer
    /// entirely loses it, as their dot does. Deleting that clear turns this red.
    @Test func aStatusGoesWhenItsPersonDropsOutOfTheAnswer() async throws {
        let transport = try transport([.statuses(["u-1": "Lunch"]), .statuses(["u-2": nil])])
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(3, on: transport)
        let events = await log.settle()

        #expect(statuses(in: events)[ada] == [vacation("Lunch"), nil])
        await backend.disconnect()
    }

    /// An answer without a `user_status` says nothing about the status - the
    /// server may simply not have included it - so it is kept. Treating it as
    /// "cleared" turns this red.
    @Test func anAnswerWithoutAUserStatusKeepsTheStatus() async throws {
        let transport = try transport(
            [.statuses(["u-1": "Lunch"]), .people(["u-1": .active])],
            dmMembers: ["u-1"]
        )
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(3, on: transport)
        let events = await log.settle()

        #expect(statuses(in: events)[ada] == [vacation("Lunch")])
        await backend.disconnect()
    }

    /// A failed poll cannot confirm a status any more than a dot. Deleting
    /// the status half of the withdrawal turns this red.
    @Test func aFailedPollWithdrawsStatuses() async throws {
        let transport = try transport(
            [.statuses(["u-1": "Lunch"]), .failure, .statuses(["u-1": "Lunch"])],
            dmMembers: ["u-1"]
        )
        let backend = backend(transport, interval: .milliseconds(20))
        let log = SenderEventLog(backend)
        try await backend.connect()

        _ = try await backend.loadConversations()
        try await awaitPolls(3, on: transport)
        let events = await log.settle()

        #expect(statuses(in: events)[ada] == [vacation("Lunch"), nil, vacation("Lunch")])
        await backend.disconnect()
    }
}
