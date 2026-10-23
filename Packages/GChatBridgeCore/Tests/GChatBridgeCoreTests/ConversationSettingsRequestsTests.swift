import Foundation
import Testing
@testable import GChatBridgeCore

struct ConversationSettingsRequestsTests {
    @Test func conversionUsesExistingIdentityAndSpaceAttribute() throws {
        var group = GroupId(); group.spaceID.spaceID = "room"
        let call = try ConversationConversionRequests.convert(group, name: "Planning", emoji: "🐾")
        #expect(call.rpc == "JpvLpe")
        #expect(try PBLiteValue(json: Data(call.payload.utf8)) == PBLiteValue(json: Data(
            #"[["space/room","room",2],"Planning",null,null,null,[["🐾"]],[1,7,3],null,null,[[6,"SPACE"]]]"#
                .utf8
        )))
    }

    @Test func emailDeliveryUsesItsOwnHeaderAndFieldMaskAndRetainsOtherData() throws {
        var group = GroupId(); group.spaceID.spaceID = "room"
        var value = try SpaceEmailDetails(serializedBytes: Data([0x48, 7]))
        value.email = "room@example.invalid"; value.name = "Retained name"; value.emailDeliverySetting = 2
        let update = SpaceEmailRequests.delivery(false, for: value, in: group)
        #expect(update.group == group && update.email == value.email)
        #expect(update.details.emailDeliverySetting == 1 && update.details.name == value.name)
        #expect(update.details.unknownFields.data == value.unknownFields.data)
        #expect(update.updateMask.paths == ["emailable_space_details.email_delivery_setting"])
        let fields = try ProtoFieldScan.fields(in: update.serializedData()).fields.map(\.number)
        #expect(fields.contains(1) && !fields.contains(100))
    }
}
