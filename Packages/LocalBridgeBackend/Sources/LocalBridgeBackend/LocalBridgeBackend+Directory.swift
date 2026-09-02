import ChatKit
import Foundation
import GChatBridgeCore

/// Resolving the member directory, and correcting what the world response
/// could not know.
///
/// Split out of `LocalBridgeBackend.swift` for `file_length`, and it is a
/// coherent seam rather than an arbitrary cut: everything here runs *after*
/// `loadConversations()` has already returned, filling in names and fixing one
/// kind that `WorldMapping` documents itself as guessing.
extension LocalBridgeBackend {
    /// Names, via one `get_members` call over the union of every returned
    /// conversation's members - `MemberMapping` builds `[ChatKit.Member]`
    /// from what it returns, the way `WorldMapping` does for the world
    /// itself. One `.membersChanged` event per conversation that has any
    /// members, never for one that has none (`findings.md` §20.4: one of the
    /// four observed conversations - a space - has no `dm_members` at all).
    ///
    /// **Never throws.** `loadConversations()`'s whole point is that it
    /// "must still return promptly and must not fail because names failed" -
    /// a name lookup that errors is a degraded sidebar, not a broken one, so
    /// any failure here becomes a `.backendError` event instead of
    /// propagating to the caller.
    func resolveAndEmitMembers(
        for conversations: [Conversation],
        using apiClient: ProtoAPIClient
    ) async {
        let ids = Array(Set(conversations.flatMap(\.members)))
        guard !ids.isEmpty else { return }

        var request = GetMembersRequest()
        request.requestHeader = APIRequestHeader.make()
        request.memberIds = ids.map { id in
            var userID = UserId()
            userID.id = id.rawValue
            var memberID = MemberId()
            memberID.userID = userID
            return memberID
        }

        let response: GetMembersResponse
        do {
            response = try await apiClient.call(.getMembers, request)
        } catch {
            emit(.backendError(Self.chatError(fromAPI: error, call: "the /api/ get_members call")))
            return
        }

        let mapped = MemberMapping.map(response)
        if mapped.skipped > 0 {
            emit(.backendError(.unknown(
                "\(mapped.skipped) member(s) could not be mapped and were skipped"
            )))
        }

        let byID = Dictionary(uniqueKeysWithValues: mapped.members.map { ($0.id, $0) })
        for conversation in conversations {
            let members = conversation.members.compactMap { byID[$0] }
            guard !members.isEmpty else { continue }
            emit(.membersChanged(conversationID: conversation.id, members: members))
            if let reclassified = Self.asAppDirectMessage(conversation, members: members) {
                emit(.conversationUpdated(reclassified))
            }
        }
    }

    /// A DM with a Chat app, once the members come back and say so.
    ///
    /// `WorldMapping.kind(for:)` has to guess here and documents it: a `dm_id`
    /// says nothing about whether the other party is a person or an app, so it
    /// files every two-member DM as `.directMessage`. That guess is only
    /// resolvable *after* `get_members`, which reports `UserType.BOT` as
    /// `Member.Kind.app` - so the correction happens here rather than being
    /// wrong forever in a mapping that cannot know.
    ///
    /// Why it is worth correcting: `SidebarSections` already has an **"Apps"**
    /// section that nothing has ever populated, so Google Drive - which is a
    /// real Chat app DM, and how Drive reports a share or a comment - sat in
    /// "Direct messages" looking like a colleague.
    ///
    /// Membership in `.app` rather than an exact non-self match, because the
    /// local user's own identity arrives on a separate unawaited call and may
    /// not be known yet. A human DM's members are two humans, so "any member is
    /// an app" separates the two cases without needing to know which one is
    /// you. Only `.directMessage` is reclassified: a group chat that happens to
    /// contain an app is still a group chat.
    static func asAppDirectMessage(
        _ conversation: Conversation,
        members: [ChatKit.Member]
    ) -> Conversation? {
        guard conversation.kind == .directMessage,
              members.contains(where: { $0.kind == .app })
        else {
            return nil
        }
        var updated = conversation
        updated.kind = .appDirectMessage
        return updated
    }

    /// `ChatKit.Message`, spelled out.
    ///
    /// This is the one package that imports both the domain and the generated
    /// protobuf, and the protobuf has a `Message` of its own. Every domain type
    /// whose name the wire also uses has to be qualified here - which is a real
    /// cost of hosting the core, and an argument for keeping this package thin.
    public func loadMessages(
        in _: Conversation.ID,
        before _: ChatKit.Message.ID?
    ) async throws -> [ChatKit.Message] {
        throw ChatError.unsupported(capability: Self.missingChannel)
    }

    public func setNotificationSetting(
        _: NotificationLevel,
        for _: Conversation.ID
    ) async throws {
        throw ChatError.unsupported(capability: Self.missingChannel)
    }

    // Not `private`: `resolveAndEmitSelf()` moved to its own file once this
    // one crossed swiftlint's `file_length`, and still needs to call this.
}
