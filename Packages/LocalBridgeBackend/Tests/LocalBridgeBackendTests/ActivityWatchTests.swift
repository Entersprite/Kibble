import ChatKit
import Testing
@testable import GChatBridgeCore
@testable import LocalBridgeBackend

private extension LocalBridgeBackend {
    func installActivityTestChannel(_ value: ChannelSession) {
        channel = value
    }
}

struct ActivityWatchTests {
    @Test func managedReceiveInterestsMapEveryConversationAndClearOnlyThatLayer() async throws {
        let cookies = try #require(SessionCookies(header: "SID=a; COMPASS=b"))
        let transport = ScriptedTransport([])
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        let channel = ChannelSession(cookies: cookies, transport: transport)
        await backend.installActivityTestChannel(channel)
        try await backend.setReceiveInterests(
            presenceMembers: [ChatKit.Member.ID("visible")],
            conversations: [
                Conversation.ID("dm/first"), Conversation.ID("space/second")
            ]
        )
        var first = GroupId(); first.dmID.dmID = "first"
        var second = GroupId(); second.spaceID.spaceID = "second"
        #expect(await channel.watchedGroups == [first, second])
        try await backend.setReceiveInterests(presenceMembers: [], conversations: [])
        #expect(await channel.watchedGroups.isEmpty)
        await channel.stop()
    }

    @Test func commandMapsTheOpaqueConversationOnlyInTheAdapter() async throws {
        let cookies = try #require(SessionCookies(header: "SID=a; COMPASS=b"))
        let transport = ScriptedTransport([])
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        let channel = ChannelSession(cookies: cookies, transport: transport)
        await backend.installActivityTestChannel(channel)
        try await backend.send(.watchConversationActivity(conversationID: Conversation.ID("dm/selected")))
        var expected = GroupId()
        expected.dmID.dmID = "selected"
        #expect(await channel.watchedGroup == expected)
        try await backend.send(.watchConversationActivity(conversationID: Conversation.ID("space/other")))
        expected = GroupId()
        expected.spaceID.spaceID = "other"
        #expect(await channel.watchedGroup == expected)
        try await backend.send(.watchConversationActivity(conversationID: nil))
        #expect(await channel.watchedGroup == nil)
        await channel.stop()
    }
}
