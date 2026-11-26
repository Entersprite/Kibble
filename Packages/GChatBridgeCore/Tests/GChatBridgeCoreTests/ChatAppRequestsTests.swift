import Foundation
import Testing
@testable import GChatBridgeCore

struct ChatAppRequestsTests {
    @Test func autocompleteAndMembershipRequestsKeepAppTypes() throws {
        let request = try ChatAppRequests.search("build")
        #expect(request.rpc == "wxhTDd")
        #expect(request.payload == #"["build",null,null,null,null,[1]]"#)
        var group = GroupId(); group.spaceID.spaceID = "room"
        #expect(ChatAppRequests.list(group, token: nil).filter == 2)
        let add = ChatAppRequests.add("app", to: group)
        #expect(add.groupID == group)
        #expect(add.memberIds.count == 1 && add.memberIds[0].userID.type == .bot)
        #expect(try PBLiteEncoder.encode(ChatAppRequests.directMessage("app")).jsonString()
            .contains(#"["app",1]"#))
        #expect(APIMethod<CreateBotDmRequest, CreateDmResponse>.createBotDm.name == "create_bot_dm")
    }
}
