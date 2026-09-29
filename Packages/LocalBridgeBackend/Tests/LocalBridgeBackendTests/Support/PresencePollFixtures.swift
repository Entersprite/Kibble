import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// What `PresencePollTests` and `PresenceSenderTests` both build from.
protocol PresencePollFixtures: SenderResolutionFixtures {}

extension PresencePollFixtures {
    var ada: ChatKit.Member.ID {
        ChatKit.Member.ID("u-1")
    }

    var grace: ChatKit.Member.ID {
        ChatKit.Member.ID("u-2")
    }

    func backend(
        _ transport: PresenceTransport,
        interval: Duration = .seconds(3600)
    ) -> LocalBridgeBackend {
        LocalBridgeBackend(
            cookies: Self.cookies,
            transport: transport,
            retry: .default,
            presencePollInterval: interval
        )
    }

    func transport(
        _ answers: [PresenceTransport.Answer],
        dmMembers: [String] = ["u-1", "u-2"],
        heldPolls: Int = 0,
        heldLookups: Int = 0,
        terminalStream: Bool = false,
        topics: HTTPResponse? = nil,
        holdPollAt: Int? = nil
    ) throws -> PresenceTransport {
        try PresenceTransport(
            shell: shell(),
            world: world(dmMembers: dmMembers),
            answers: answers,
            heldPolls: heldPolls,
            heldLookups: heldLookups,
            terminalStream: terminalStream,
            topics: topics,
            holdPollAt: holdPollAt
        )
    }

    /// Until `transport` has answered `count` polls, so a released answer is
    /// known to be back before "nothing emitted" is asserted - a fixed wait
    /// alone would pass with the guard deleted on a slow enough machine.
    func awaitAnswered(_ count: Int, on transport: PresenceTransport) async throws {
        for _ in 0 ..< 400 where await transport.pollsAnswered < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await transport.pollsAnswered >= count)
    }

    /// Until `transport` has seen `count` polls. Bounded, for the reason
    /// `awaitLookups` is.
    func awaitPolls(_ count: Int, on transport: PresenceTransport) async throws {
        for _ in 0 ..< 400 where await transport.polls.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await transport.polls.count >= count)
    }

    func presences(in events: [ChatEvent]) -> [ChatKit.Member.ID: [ChatKit.Presence]] {
        var result: [ChatKit.Member.ID: [ChatKit.Presence]] = [:]
        for case let .presenceChanged(member, presence) in events {
            result[member, default: []].append(presence)
        }
        return result
    }

    func pollErrors(in events: [ChatEvent]) -> Int {
        events.count {
            if case let .backendError(error) = $0 {
                return "\(error)".contains("get_user_presence")
            }
            return false
        }
    }
}
