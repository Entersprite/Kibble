import ChatKit
import Foundation
import GChatBridgeCore

/// What sort of conversation a `WorldItemLite` describes.
///
/// Split from `WorldMapping.swift` for the same `file_length` reason
/// `APIProbeReport+WorldFields.swift` and `LocalBridgeBackend`'s own
/// `+Directory`/`+Errors` files already are: classification grew past
/// `swiftlint`'s 400-line ceiling once field 19, the calendar group type and
/// the group-chat test all landed in it.
///
/// It is a coherent seam rather than an arbitrary cut. Everything here answers
/// **"what is this conversation"** from `attribute_checker_group_type` (19),
/// the `GroupId` namespace and the naming fields; `WorldMapping.swift` keeps
/// the field-by-field mapping that turns one item into a `Conversation`. Field
/// 19's meaning is therefore described in exactly one file.
extension WorldMapping {
    /// Space, direct message, group direct message, or app DM - from the
    /// server's own answer where it gives one.
    ///
    /// `attribute_checker_group_type` (field 19) is read first. `findings.md`
    /// §37.2: it is declared in the vendored proto, has therefore been in the
    /// generated Swift all along, and §20.4 observed it present on all four
    /// scanned items - so this function's former doc comment, which said an
    /// app DM **cannot** be distinguished from a human one at this layer, was
    /// never true. `oneToOneBotDm` is exactly that distinction.
    ///
    /// The `GroupId`-plus-member-count inference stays as the fallback rather
    /// than being deleted. Field 19 was observed on four items of one
    /// account, which is not a promise about every account or every future
    /// response, and a conversation whose type cannot be read should stay as
    /// well-categorised as it already was rather than become `.unknown`.
    /// Because the proto is proto2, a value added by Google after this build
    /// arrives as an unrecognised enum, which leaves the presence bit clear
    /// and lands here too.
    static func kind(for item: WorldItemLite) -> Conversation.Kind {
        // Checked before the group type, because it is a statement about the
        // conversation rather than about which enum value this build can name:
        // a space with no name of its own is a group chat whether its group
        // type reads 4 or 10.
        if isSpaceNamespace(item), isNamedAfterItsMembers(item) {
            return .groupDirectMessage
        }
        if item.hasAttributeCheckerGroupType,
           let stated = statedKind(for: item.attributeCheckerGroupType) {
            return stated
        }
        let inferred = inferredKind(for: item)
        if inferred == .space, let raw = unrecognisedGroupType(in: item) {
            return raw == meetChatGroupType
                ? .meetChat
                : .unknown("\(Self.groupTypeTokenPrefix)\(raw)")
        }
        return inferred
    }

    /// A space in the `space_id` namespace, as opposed to a DM.
    ///
    /// Separate from `inferredKind(for:)` because the group-chat test below
    /// has to run *before* the group type is consulted, and by then
    /// `inferredKind` has not been called.
    private static func isSpaceNamespace(_ item: WorldItemLite) -> Bool {
        switch item.groupID.id {
        case .spaceID: true
        default: false
        }
    }

    /// A space with no `room_name` of its own, titled after its members
    /// instead - which is what Chat calls a group chat.
    ///
    /// Measured 2026-09-08 across the real account's 220 conversations
    /// (`findings.md` §37.5), and the cross-tabulation closes with nothing
    /// left over:
    ///
    /// | | `room_name` | no `room_name` |
    /// | --- | --- | --- |
    /// | has `dm_members` | 0 | **15** - the DMs |
    /// | has `name_users` | 0 | **6** - the group chats |
    /// | neither | 199 | 0 |
    ///
    /// So the two conditions are equivalent on this account and either alone
    /// would do. Both are required anyway: `name_users` present is the
    /// positive evidence that a title is *meant* to come from the members,
    /// and `room_name` absent is what makes deriving one not an override of
    /// something the server sent - `Conversation.title`'s own doc comment
    /// draws that line, and an empty-but-present `room_name` is on the other
    /// side of it.
    ///
    /// `[Verify]`: whether a **named** group chat exists. Chat lets you name a
    /// group conversation, and such a conversation would have a `room_name`
    /// and be indistinguishable here from a small space - it would stay under
    /// "Spaces". None of the 220 is in that state, so nothing has exercised
    /// it. §20.4 recorded `name_users` as absent from all four items it
    /// scanned, which is the third finding that four-item sample got wrong.
    ///
    /// The result is `.groupDirectMessage` even though the identifier is
    /// `space/`, because that is the case `SidebarSections` already heads
    /// "Group chats" and the one `ConversationList` already draws a
    /// three-person glyph for. `Kind` has no `.groupChat`, and adding one is a
    /// wire-format change; the honest alternative would be that, not a
    /// different bucket.
    private static func isNamedAfterItsMembers(_ item: WorldItemLite) -> Bool {
        !item.hasRoomName && item.hasNameUsers
    }

    /// The `attribute_checker_group_type` of a space created for a scheduled
    /// meeting - **187 of the real account's 220 conversations**, every one a
    /// space and every one titled after a calendar event (`findings.md`
    /// §37.4).
    ///
    /// Still a bare number, because no vendored reference proto names value
    /// 10; `Conversation.Kind.meetChat`'s doc comment records that the *name*
    /// is the owner's decision from visual confirmation while the wire
    /// meaning stays `[Verify]`. Any **other** unrecognised space type still
    /// becomes `.unknown` keyed on its number, which is the path that found
    /// this one.
    private static let meetChatGroupType: UInt64 = 10

    /// The prefix a `Kind.unknown` payload carries when the *only* thing this
    /// build knows about a conversation's type is field 19's number.
    ///
    /// A number, never an invented case name - the rule
    /// `ChannelEventMapping` already follows for unmapped events, and the one
    /// §12.1.1 exists to enforce. Google's own name for group type 10 is
    /// unknown to all three vendored reference protos, so minting
    /// `"calendarSpace"` here would be a fixture standing in for a capture.
    static let groupTypeTokenPrefix = "attributeCheckerGroupType"

    /// Field 19's raw value when the generated enum could not name it.
    ///
    /// Measured on 2026-09-08 (`findings.md` §37.4): of 220 conversations,
    /// **188** reported `hasAttributeCheckerGroupType == false` while a byte
    /// scan showed field 19 present on every single item. Both are true
    /// because the proto is `syntax = "proto2"`: a closed enum rejects a value
    /// outside its generated set, leaves the presence bit clear, and keeps the
    /// bytes in `unknownFields`. The values are **10** (187 items, every one a
    /// space) and **11** (1 item, a DM).
    ///
    /// Read only for a space, and that is deliberate. Carrying an unnamed type
    /// into `Kind` costs the conversation its `.space`-ness at every call site
    /// that switches on it, which is the same objection that ruled out adding
    /// a `.meetSpace` case. For a space that is an acceptable trade **while
    /// the meaning of 10 is being established**, because the sidebar is the
    /// only consumer that matters and the alternative is 187 conversations
    /// that cannot be told apart from the 18 real ones. For a DM it is not:
    /// group type 11's single conversation reaches
    /// `LocalBridgeBackend.asAppDirectMessage` as `.directMessage` and is
    /// correctly promoted to `.appDirectMessage`, which is where the store's
    /// sixth app DM comes from. An `.unknown` kind would fail that guard and
    /// silently drop it out of "Apps".
    private static func unrecognisedGroupType(in item: WorldItemLite) -> UInt64? {
        ProtoFieldScan.varintValues(
            ofField: attributeCheckerGroupTypeField,
            in: item.unknownFields.data
        ).first
    }

    /// `WorldItemLite.attribute_checker_group_type`'s field number. Named
    /// here because nothing generated can supply it: the whole reason this
    /// path runs is that the typed decode rejected the value.
    private static let attributeCheckerGroupTypeField = 19

    /// What field 19 says, or `nil` when it says nothing usable.
    ///
    /// `[Verify]`: §20.4 recorded field 19's **presence and length, never its
    /// value** - `ProtoFieldScan` reports field numbers, wire types and sizes
    /// and deliberately never contents - so which of the seven values each
    /// conversation actually carries is unobserved. Two readings here claim
    /// more than has been established, and both pick the least invasive
    /// answer: `immutableMembershipHumanDm` (6) is treated as a plain DM,
    /// and `postRoom` (7) as a plain space. An announcement space may deserve
    /// separating later; nothing has confirmed this account has one.
    private static func statedKind(
        for groupType: SharedAttributeCheckerGroupType
    ) -> Conversation.Kind? {
        switch groupType {
        case .oneToOneHumanDm, .immutableMembershipHumanDm:
            .directMessage
        case .oneToOneBotDm:
            .appDirectMessage
        case .immutableMembershipGroupDm:
            .groupDirectMessage
        case .flatRoom, .threadedRoom, .postRoom:
            .space
        case .attributeCheckerGroupTypeUnspecified:
            // The presence bit was set and the value still says nothing.
            nil
        }
    }

    /// The pre-§37.2 reading: the `GroupId` oneof, plus member count for the
    /// DM-versus-group-DM split. Now the fallback rather than the only answer.
    ///
    /// It cannot see an app DM at all, which is why
    /// `LocalBridgeBackend.asAppDirectMessage` still exists as a second pass.
    private static func inferredKind(for item: WorldItemLite) -> Conversation.Kind {
        switch item.groupID.id {
        case .spaceID:
            .space
        case .dmID:
            item.dmMembers.members.count <= 2 ? .directMessage : .groupDirectMessage
        default:
            // Unreachable in practice: `conversation(from:)` only reaches
            // here once `ChannelEventMapping.conversationID` has already
            // succeeded, which requires `group.id` to be one of the two
            // cases above with a non-empty inner id. Kept explicit rather
            // than force-unwrapped, because "unreachable today" is not a
            // promise a future proto regeneration has to keep.
            .unknown("noGroupID")
        }
    }

    /// `attribute_checker_group_type` beats `threaded_group` present beats
    /// `flat_group` present beats `group_lite.is_flat`, inverted - and when
    /// **none** of the four is present, `false`.
    ///
    /// Field 19 leads because `flatRoom` and `threadedRoom` are the server
    /// stating the answer, where the three fields below it are a client
    /// reading structure out of which empty marker message arrived
    /// (`findings.md` §37.2). Only those two values decide: the DM cases say
    /// nothing about threading, and `postRoom` is unobserved, so all of them
    /// fall through to the ladder rather than claim a default.
    ///
    /// The ladder run (`findings.md` §20.1) is why `group_lite` cannot be
    /// dropped from the request even though `EXCLUDE_GROUP_LITE` costs ~48
    /// bytes an item: it is the only place `is_flat` lives when neither
    /// oneof case is set. But §20.1 also found that `EXCLUDE_GROUP_LITE`
    /// *can* strip `group_lite` entirely, so "none of the three present" is a
    /// real, reachable shape and not just a hypothetical - proto3's default
    /// for an absent `is_flat` is `false`, and reading that default as
    /// "threaded" was inventing structure from silence.
    ///
    /// `[Verify]`: whether "no information" should default to flat rather
    /// than threaded has not been checked against a live response - this
    /// picks the less invasive wrong answer. `Conversation.isThreaded`'s own
    /// doc comment calls the difference structural, not cosmetic: a threaded
    /// space rendered flat is a degraded but still coherent view, whereas a
    /// flat group rendered threaded invents a structure that was never there.
    static func isThreaded(_ item: WorldItemLite) -> Bool {
        if item.hasAttributeCheckerGroupType {
            switch item.attributeCheckerGroupType {
            case .threadedRoom:
                return true
            case .flatRoom:
                return false
            case .oneToOneHumanDm, .oneToOneBotDm, .immutableMembershipGroupDm,
                 .immutableMembershipHumanDm, .postRoom,
                 .attributeCheckerGroupTypeUnspecified:
                // Deliberately exhaustive rather than `default`: regenerating
                // the proto with a new case should fail to compile here and
                // force a decision, not silently pick the ladder.
                break
            }
        }
        if item.hasThreadedGroup {
            return true
        }
        if item.hasFlatGroup {
            return false
        }
        guard item.hasGroupLite else {
            return false
        }
        return !item.groupLite.isFlat
    }
}
