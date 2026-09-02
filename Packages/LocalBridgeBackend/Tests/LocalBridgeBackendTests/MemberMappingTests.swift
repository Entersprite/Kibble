import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `GetMembersResponse` becoming `[ChatKit.Member]`.
///
/// Same shape as `WorldMappingTests`: fixtures built as typed `SwiftProtobuf`
/// values, because `MemberMapping` runs after `ProtoAPIClient`'s own typed
/// decode - there is no pblite layer to fight here either. `get_members`
/// itself has never been sent by this implementation (`APIMethod.getMembers`'s
/// own doc comment), so every mapping asserted here is a claim about the
/// vendored proto's field numbers, not about a shape observed on the wire.
struct MemberMappingTests {
    // MARK: - Building fixtures in the shape the proto actually uses

    private func userID(_ id: String, type: UserType = .human) -> UserId {
        var userID = UserId()
        userID.id = id
        userID.type = type
        return userID
    }

    private func wireMember(
        id: String,
        type: UserType = .human,
        name: String? = nil,
        email: String? = nil,
        avatarURL: String? = nil
    ) -> GChatBridgeCore.Member {
        var user = User()
        user.userID = userID(id, type: type)
        if let name {
            user.name = name
        }
        if let email {
            user.email = email
        }
        if let avatarURL {
            user.avatarURL = avatarURL
        }
        var member = GChatBridgeCore.Member()
        member.user = user
        return member
    }

    private func response(_ members: [GChatBridgeCore.Member]) -> GetMembersResponse {
        var response = GetMembersResponse()
        response.members = members
        return response
    }

    // MARK: - Identity, and nothing is silently dropped

    @Test func aUserIDBecomesTheMemberID() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1")]))
        #expect(mapped.members.first?.id == ChatKit.Member.ID("u-1"))
    }

    @Test func anEmptyUserIDIsSkippedAndCounted() {
        let mapped = MemberMapping.map(response([wireMember(id: "")]))
        #expect(mapped.members.isEmpty)
        #expect(mapped.skipped == 1)
    }

    @Test func aMemberWithNoProfileAtAllIsSkippedAndCounted() {
        let mapped = MemberMapping.map(response([GChatBridgeCore.Member()]))
        #expect(mapped.members.isEmpty)
        #expect(mapped.skipped == 1)
    }

    @Test func validAndInvalidEntriesAreBothAccountedForInOneRun() {
        let mapped = MemberMapping.map(response([
            wireMember(id: "u-1"),
            wireMember(id: ""),
            wireMember(id: "u-2")
        ]))
        #expect(mapped.members.count == 2)
        #expect(mapped.skipped == 1)
    }

    @Test func anEmptyResponseProducesNoMembersAndNoSkips() {
        let mapped = MemberMapping.map(response([]))
        #expect(mapped.members.isEmpty)
        #expect(mapped.skipped == 0)
    }

    // MARK: - Kind: HUMAN and BOT, never a guess

    @Test func aHumanUserTypeBecomesHumanKind() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1", type: .human)]))
        #expect(mapped.members.first?.kind == .human)
    }

    @Test func aBotUserTypeBecomesAppKind() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1", type: .bot)]))
        #expect(mapped.members.first?.kind == .app)
    }

    // MARK: - displayName / email / avatarURL: empty means absent

    /// `Display.name` treats an empty name as absent and falls back to the
    /// id - an empty string here would be a silently useless name rather
    /// than an honest "we do not have one".
    @Test func anEmptyNameBecomesANilDisplayName() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1")]))
        #expect(mapped.members.first?.displayName == nil)
    }

    @Test func aNonEmptyNameIsKeptAsTheDisplayName() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1", name: "Ada Lovelace")]))
        #expect(mapped.members.first?.displayName == "Ada Lovelace")
    }

    @Test func anEmptyEmailBecomesNil() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1")]))
        #expect(mapped.members.first?.email == nil)
    }

    @Test func aNonEmptyEmailIsKept() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1", email: "ada@example.com")]))
        #expect(mapped.members.first?.email == "ada@example.com")
    }

    @Test func anEmptyAvatarURLBecomesNil() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1")]))
        #expect(mapped.members.first?.avatarURL == nil)
    }

    @Test func aNonEmptyAvatarURLIsParsed() {
        let mapped = MemberMapping.map(response([
            wireMember(id: "u-1", avatarURL: "https://example.com/a.png")
        ]))
        #expect(mapped.members.first?.avatarURL?.absoluteString == "https://example.com/a.png")
    }

    // MARK: - Presence: nobody has told us, never invented

    @Test func presenceIsAlwaysNilBecauseNothingHasObservedIt() {
        let mapped = MemberMapping.map(response([wireMember(id: "u-1")]))
        #expect(mapped.members.first?.presence == nil)
    }
}

@Suite("App DM reclassification")
struct AppDirectMessageTests {
    private func conversation(kind: Conversation.Kind, members: [String]) -> Conversation {
        Conversation(
            id: Conversation.ID("dm/d-1"),
            kind: kind,
            members: members.map { ChatKit.Member.ID($0) }
        )
    }

    private func member(_ id: String, kind: ChatKit.Member.Kind) -> ChatKit.Member {
        ChatKit.Member(id: ChatKit.Member.ID(id), kind: kind, displayName: "n")
    }

    /// The case that prompted this: Google Drive is a real Chat app DM, and it
    /// sat under "Direct messages" looking like a colleague because a `dm_id`
    /// does not say whether the other party is a person.
    @Test func aDirectMessageWithAnAppBecomesAnAppDirectMessage() {
        let updated = LocalBridgeBackend.asAppDirectMessage(
            conversation(kind: .directMessage, members: ["me", "bot"]),
            members: [member("me", kind: .human), member("bot", kind: .app)]
        )
        #expect(updated?.kind == .appDirectMessage)
        #expect(updated?.id.rawValue == "dm/d-1")
    }

    @Test func aDirectMessageBetweenHumansIsLeftAlone() {
        let updated = LocalBridgeBackend.asAppDirectMessage(
            conversation(kind: .directMessage, members: ["me", "you"]),
            members: [member("me", kind: .human), member("you", kind: .human)]
        )
        #expect(updated == nil)
    }

    /// A group chat containing an app is still a group chat - only the guess
    /// `WorldMapping` actually makes is corrected.
    @Test func aGroupChatContainingAnAppIsStillAGroupChat() {
        let updated = LocalBridgeBackend.asAppDirectMessage(
            conversation(kind: .groupDirectMessage, members: ["me", "you", "bot"]),
            members: [
                member("me", kind: .human),
                member("you", kind: .human),
                member("bot", kind: .app)
            ]
        )
        #expect(updated == nil)
    }

    @Test func aSpaceIsNeverReclassified() {
        let updated = LocalBridgeBackend.asAppDirectMessage(
            conversation(kind: .space, members: ["me", "bot"]),
            members: [member("me", kind: .human), member("bot", kind: .app)]
        )
        #expect(updated == nil)
    }

    /// Everything else about the conversation survives the correction - only
    /// `kind` changes, because the rest was already right.
    @Test func onlyTheKindChanges() {
        var original = conversation(kind: .directMessage, members: ["me", "bot"])
        original.unreadCount = 3
        original.isThreaded = true
        let updated = LocalBridgeBackend.asAppDirectMessage(
            original,
            members: [member("bot", kind: .app)]
        )
        #expect(updated?.unreadCount == 3)
        #expect(updated?.isThreaded == true)
        #expect(updated?.members == original.members)
    }
}
