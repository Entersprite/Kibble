import ChatKit
import Foundation
import GChatBridgeCore
@testable import LocalBridgeBackend

/// `WorldItemLite` values carrying the fields `findings.md` §37.4-§37.8 found
/// on the real account: `attribute_checker_group_type` (19), `name_users`
/// (20) and the read-state timestamp pair.
///
/// Separate from `WorldMappingTests`' own private builders, because those
/// predate all three and every fixture they build leaves them unset. That is
/// why the whole suite could stay green while saying nothing about any of the
/// paths these fields drive: each of its fixtures took the old fallback.
///
/// Values are invented. Only the *shapes* are measured - which fields are
/// present together - and each call site says which measured shape it is,
/// or that it is a synthetic one built to reach a guard.
enum WorldItemFixture {
    static func spaceGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var space = SpaceId()
        space.spaceID = id
        group.spaceID = space
        return group
    }

    static func dmGroupID(_ id: String) -> GroupId {
        var group = GroupId()
        var dm = DmId()
        dm.dmID = id
        group.dmID = dm
        return group
    }

    /// One item. Every optional left `nil` stays **absent on the wire**, which
    /// is the distinction the mapping under test reads: `dm_members` is set
    /// only when members are given, because §37.5 measured it absent on a
    /// space, and `name_users` only when ids or a group name are given.
    static func item(
        groupID: GroupId,
        roomName: String? = nil,
        dmMembers: [String] = [],
        nameUsers: [String]? = nil,
        groupName: String? = nil,
        groupType: SharedAttributeCheckerGroupType? = nil,
        lastReadMicros: Int64? = nil,
        newestMessageMicros: Int64? = nil,
        threadedGroup: Bool = false,
        flatGroup: Bool = false
    ) -> WorldItemLite {
        var item = WorldItemLite()
        item.groupID = groupID
        if let roomName {
            item.roomName = roomName
        }
        if !dmMembers.isEmpty {
            var members = WorldItemLite.DmMembers()
            members.members = dmMembers.map(userID)
            item.dmMembers = members
        }
        if nameUsers != nil || groupName != nil {
            var names = NameUsers()
            names.nameUserIds = (nameUsers ?? []).map(userID)
            if let groupName {
                names.groupName = groupName
            }
            item.nameUsers = names
        }
        if let groupType {
            item.attributeCheckerGroupType = groupType
        }
        // Present on all 220 of the real account's items (§37.8), so always
        // set; only its two timestamps are optional.
        var readState = GroupReadState()
        if let lastReadMicros {
            readState.lastReadTime = lastReadMicros
        }
        if let newestMessageMicros {
            readState.lastHeadMessageCreateTimeUsec = newestMessageMicros
        }
        item.readState = readState
        if threadedGroup {
            item.threadedGroup = WorldItemLite.ThreadedGroup()
        }
        if flatGroup {
            item.flatGroup = WorldItemLite.FlatGroup()
        }
        return item
    }

    /// `item` with field 19 appended as a raw varint and then **decoded**, so
    /// the value reaches `WorldMapping` the way §37.4 found it on the wire:
    /// rejected by the closed proto2 enum, presence bit clear, bytes kept in
    /// `unknownFields`. Setting `unknownFields` by hand would test the
    /// fixture's idea of that behaviour rather than SwiftProtobuf's.
    static func withRawGroupType(_ raw: UInt64, on item: WorldItemLite) throws -> WorldItemLite {
        var bytes: Data = try item.serializedBytes()
        bytes.append(contentsOf: varint(19 << 3)) // field 19, wire type 0
        bytes.append(contentsOf: varint(raw))
        return try WorldItemLite(serializedBytes: bytes)
    }

    /// The single conversation `item` maps to, through the public entry point
    /// rather than the internal helpers, so a test covers the order they run in.
    static func mapped(_ item: WorldItemLite) -> ChatKit.Conversation? {
        var response = PaginatedWorldResponse()
        response.worldItems = [item]
        return WorldMapping.map(response).conversations.first
    }

    private static func userID(_ id: String) -> UserId {
        var user = UserId()
        user.id = id
        return user
    }

    private static func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }
            bytes.append(byte)
        } while remaining != 0
        return bytes
    }
}
