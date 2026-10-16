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
