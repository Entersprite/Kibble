import Foundation
import Testing
@testable import GChatBridgeCore

struct WebhookRequestsTests {
    @Test func webhooksUseWebReferencesAndDuplicateAvatarFields() throws {
        var group = GroupId(); group.spaceID.spaceID = "room"
        let create = try WebhookRequests.create(group, name: "Builds", avatarURL: "")
        #expect(create.rpc == "yljFfb")
        #expect(try PBLiteValue(json: Data(create.payload.utf8)) == PBLiteValue(json: Data(
            #"[["space/room","room",2],"Builds","",null,""]"#.utf8
        )))
        var reference = WebhookReference(); reference.group = try WebhookRequests.groupReference(group)
        reference.id = "hook"
        let edit = try WebhookRequests.update(
            reference,
            name: "Deploys",
            avatarURL: "https://example.invalid/icon.png"
        )
        #expect(edit.rpc == "W7SEjd")
        let encoded = try PBLiteValue(json: Data(edit.payload.utf8))
        #expect(encoded.arrayValue?[0] == .array([
            .array([.string("space/room"), .string("room"), .number(.integer(2))]),
            .string("hook")
        ]))
        #expect(encoded.arrayValue?[2] == encoded.arrayValue?[4])
        #expect(try WebhookRequests.delete(reference).rpc == "ITXKid")
        #expect(try WebhookRequests.list(group).rpc == "yVxlUd")
        group = GroupId(); group.dmID.dmID = "chat"
        #expect(try WebhookRequests.groupReference(group).kind == 5)
    }
}
