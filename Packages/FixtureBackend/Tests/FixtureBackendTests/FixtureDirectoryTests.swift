import ChatKit
import Foundation
import Testing
@testable import FixtureBackend

/// The fixture's directory, membership and invite, so `--backend=fixture`
/// shows the whole non-member flow (mention non-members spec §3.6).
@Suite(.timeLimit(.minutes(1)))
struct FixtureDirectoryTests {
    private static let outsider = Member(
        id: Member.ID("outsider"), kind: .human, displayName: "Out Sider", email: "out@example.invalid"
    )
    private static let space = Conversation.ID("space:1")

    private static func connected() async throws -> FakeBackend {
        let backend = FakeBackend(world: .minimal, directory: [outsider])
        try await backend.connect()
        return backend
    }

    @Test func aSearchFindsDirectoryPeopleByWordOrEmail() async throws {
        let backend = try await Self.connected()
        #expect(try await backend.searchPeople("sid").map(\.id) == [Self.outsider.id])
        #expect(try await backend.searchPeople("out@").map(\.id) == [Self.outsider.id])
        #expect(try await backend.searchPeople("zzz").isEmpty)
    }

    @Test func membershipComesFromTheWorld() async throws {
        let backend = try await Self.connected()
        #expect(try await backend.membership(of: Self.outsider.id, in: Self.space) == .notMember)
        #expect(try await backend.membership(of: Member.ID("fixture-other"), in: Self.space) == .member)
    }

    @Test func anInviteAddsThePerson() async throws {
        let backend = try await Self.connected()
        var iterator = backend.events.makeAsyncIterator()
        try await backend.send(.sendMessage(
            conversationID: Self.space, threadID: nil, text: "@Out Sider hi", localID: "l-1",
            mentions: [Mention(target: .user(Self.outsider.id), start: 0, length: 10, mode: .invite)]
        ))
        var added = false
        for _ in 0 ..< 50 {
            guard let event = await iterator.next() else { break }
            if case let .membersChanged(conversation, members) = event, conversation == Self.space,
               members.contains(where: { $0.id == Self.outsider.id }) {
                added = true
                break
            }
        }
        #expect(added)
        #expect(try await backend.membership(of: Self.outsider.id, in: Self.space) == .member)
    }

    @Test func withoutAddingAddsNobody() async throws {
        let backend = try await Self.connected()
        try await backend.send(.sendMessage(
            conversationID: Self.space, threadID: nil, text: "@Out Sider hi", localID: "l-2",
            mentions: [Mention(target: .user(Self.outsider.id), start: 0, length: 10, mode: .withoutAdding)]
        ))
        #expect(try await backend.membership(of: Self.outsider.id, in: Self.space) == .notMember)
    }

    @Test func theFixtureAdvertisesIt() {
        #expect(FakeBackend(world: .minimal).capabilities.canMentionNonMembers)
    }
}
