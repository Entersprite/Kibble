import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct GroupNotificationMappingTests {
    @Test func channelRoutesTheAddressAndKeepsPartialSettingsIndependent() {
        let level = ChannelEventBody(typeTag: 18, value: .object([
            "17": [[["one"]], [nil, 5]]
        ]))
        let mute = ChannelEventBody(typeTag: 18, value: .object([
            "17": [[["one"]], [nil, nil, [2]]]
        ]))
        let wrongTag = ChannelEventBody(typeTag: 17, value: level.value)
        let invalidSpace = ChannelEventBody(typeTag: 18, value: .object([
            "17": [[[""]], [nil, 4]]
        ]))
        let id = Conversation.ID("space/one")
        let events = ChannelEventMapping.chatEvents(from: ChannelEvent(
            bodies: [level, mute, wrongTag, invalidSpace]
        ))
        #expect(events == [
            .conversationNotificationSettingsChanged(
                conversationID: id,
                level: .lessWithNewThreads,
                muted: nil
            ),
            .conversationNotificationSettingsChanged(conversationID: id, level: nil, muted: true),
            .unknown(type: "googlechat.eventType.17", payload: JSONValue(wrongTag.value)),
            .unknown(type: "googlechat.eventType.18", payload: JSONValue(invalidSpace.value))
        ])
    }

    @Test(arguments: [
        (UInt8(4), NotificationLevel.always),
        (5, .lessWithNewThreads), (2, .less), (3, .never),
        (0, .unknown("provider:0")), (7, .unknown("provider:7"))
    ])
    func worldDecodesRoomLevelAndMuteIndependently(raw: UInt8, expected: NotificationLevel) throws {
        var row = WorldItemFixture.item(groupID: WorldItemFixture.spaceGroupID("one"))
        // Read state 12 wraps settings. Settings 2 is the level, and 3
        // wraps the active mute state. Use bytes to exercise decoding too.
        row.readState = try GroupReadState(serializedBytes: Data([
            0x62, 0x06, 0x10, raw, 0x1A, 0x02, 0x08, 0x02
        ]))
        let conversation = try #require(WorldItemFixture.mapped(row))
        #expect(conversation.notificationLevel == expected)
        #expect(conversation.isMuted)
    }

    @Test func temporaryMuteExpiresIndependentlyOfTheLevel() {
        var state = GroupReadState()
        state.notificationSettings.roomState = .notifyLess
        state.notificationSettings.muteSettings.state = .muted
        state.notificationSettings.muteSettings.expiry.seconds = 2
        state.notificationSettings.muteSettings.expiry.nanos = 500_000_000
        let before = GroupNotificationMapping(state, now: Date(timeIntervalSince1970: 2))
        let expired = GroupNotificationMapping(state, now: Date(timeIntervalSince1970: 2.5))
        #expect(before.isMuted == true)
        #expect(expired.isMuted == false)
        #expect(expired.level == .less)
    }

    @Test func detailResponsePreservesAbsentFieldsAndAppliesExplicitUnmute() throws {
        let groupID = WorldItemFixture.spaceGroupID("one")
        let world = WorldItemFixture.item(groupID: groupID)
        var baseline = try #require(WorldItemFixture.mapped(world))
        baseline.notificationLevel = .never
        baseline.isMuted = true

        var group = Group()
        group.groupID = groupID
        group.groupReadState.notificationSettings.state = .unmuted
        let partial = try #require(ManagementMapping.conversation(group, fallback: baseline))
        #expect(partial.notificationLevel == .never)
        #expect(partial.isMuted)

        group.groupReadState.notificationSettings.muteSettings.state = .unmuted
        let updated = try #require(ManagementMapping.conversation(group, fallback: baseline))
        #expect(updated.notificationLevel == .never)
        #expect(!updated.isMuted)
    }
}
