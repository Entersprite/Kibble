import ChatKit
import Foundation
import GChatBridgeCore

/// A message search hit (`SBNmJb` over `batchexecute`) becoming a
/// `ChatKit.Message` - purely, with no backend call. `findings.md` §65.8 is
/// the capture this is built from, and its table names every index below.
///
/// ## Reuse, not a second translation
///
/// A hit is **not** a `GChatBridgeCore.Message` - it is its own pblite
/// layout, with different fields at the positions a `Message` uses for other
/// things entirely. This builds a synthetic `Message` out of the hit's own
/// fields and hands it to `ChannelEventMapping.domainMessage(_:)`, the exact
/// function history and the channel already use, so a hit and a history
/// message become the identical `ChatKit.Message` for identical input - the
/// same conversation-id prefixing, mentions, links, attachments and reply
/// rule, with no second copy of any of those to drift out of step with the
/// ones `ChannelEventMappingTests` already pins. `HistoryMapping` makes the
/// same choice for `list_topics` replies, for the same reason.
///
/// ## What a hit cannot carry
///
/// §65.8: a hit has no reactions, no edit time, no app cards and no sender
/// name. The synthetic `Message` never sets those fields, so
/// `domainMessage(_:)` maps them exactly as it would an ordinary message that
/// happens to lack them. Not overwriting a stored copy's richer fields with
/// a hit's absence of them is the client's business, not this type's -
/// nothing here ever sees a store.
public enum SearchHitMapping {
    /// One hit - `[inner, 2]` (302 of 302, §65.8) - to a `ChatKit.Message`, or
    /// `nil` when it lacks a message id, a valid create time, or a group
    /// reference in a recognised shape. `page(from:)` counts a `nil` as
    /// dropped.
    ///
    /// `hit` is `PBLiteValue` rather than `Any`: stripping a search-highlight
    /// span (`mappedAnnotations(_:)`) has to inspect a `FormatMetadata
    /// .FormatType` the vendored proto cannot name (`CLAUDE.md`'s proto2
    /// closed-enum rule - a typed decode would silently clear it rather than
    /// report it), and `PBLiteValue`'s own `.array`/`.object` cases make that
    /// direct instead of re-deriving it from `NSArray`/`NSDictionary` casts.
    public static func message(from hit: PBLiteValue) -> ChatKit.Message? {
        guard case let .array(wrapper) = hit, let innerValue = wrapper.first,
              let fields = SearchHitFields(innerValue)
        else { return nil }

        guard let idField = fields.field(18), let messageID = idField[0]?.stringValue, !messageID.isEmpty
        else { return nil }

        guard let createdAt = fields.field(12)?.int64Value else { return nil }

        guard let group = groupReference(fields.field(3)) else { return nil }

        var message = GChatBridgeCore.Message()
        message.id.messageID = messageID
        message.id.parentID.topicID.topicID = idField[2]?[0]?.stringValue ?? ""
        message.id.parentID.topicID.groupID = group
        message.creator.userID.id = fields.field(5)?[0]?.stringValue ?? ""
        message.textBody = fields.field(6)?.stringValue ?? ""
        message.createTime = createdAt
        message.annotations = mappedAnnotations(fields.field(9))
        // Field 58: `true` on a reply, absent on a first message (109 of 109,
        // 193 of 193, §65.8). `ThreadMapping.isReply` already falls back to
        // comparing the message id against the topic id when this is unset,
        // which the same finding says agrees with it on every hit the
        // capture saw - so leaving it unset here is never a wrong answer,
        // only a less direct one.
        if case let .bool(isReply)? = fields.field(58) {
            message.isInlineReply = isReply
        }
        return ChannelEventMapping.domainMessage(message)
    }

    // Three members - `HistoryMapping.Result` would be the two-member version
    // swiftlint's `large_tuple` otherwise asks for, but
    // `searchMessages(_:after:)` and `SearchProbeReport` both consume this
    // exact shape, so the rule is disabled for this one declaration instead.
    // Wrapped around the doc comment rather than `:next` above the `func`
    // line, which would orphan the doc comment from its declaration.
    // swiftlint:disable large_tuple
    /// A page of `SBNmJb`'s answer - `JSONSerialization` of the `wrb.fr`
    /// payload string, the same shape `SearchProbeReport.send(_:...)` already
    /// parses (`SearchProbeReport.swift:161-170`). `next` is answer index 0
    /// (`nil` when absent or empty); hits are answer index 9, each `[inner, 2]`.
    public static func page(from inner: [Any]) -> (hits: [ChatKit.Message], next: String?, dropped: Int) {
        let token = inner.first as? String
        let rawHits = inner.count > 9 ? (inner[9] as? [Any] ?? []) : []
        var hits: [ChatKit.Message] = []
        var dropped = 0
        for rawHit in rawHits {
            if let value = pbliteValue(from: rawHit), let mapped = message(from: value) {
                hits.append(mapped)
            } else {
                dropped += 1
            }
        }
        return (hits, (token?.isEmpty == false) ? token : nil, dropped)
    }

    // swiftlint:enable large_tuple

    /// `Any` - what `JSONSerialization` hands back - to the pblite tree
    /// `message(from:)` needs: the same round trip
    /// `SearchProbeReport.decodedMessage(_:)` already takes to reach a typed
    /// decode, so a malformed element fails this conversion instead of a
    /// hand-written cast crashing on it.
    private static func pbliteValue(from any: Any) -> PBLiteValue? {
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any),
              let value = try? PBLiteValue(json: data)
        else { return nil }
        return value
    }

    /// The group reference `[2]` (field 3) - identical to `[17][2][2]`, 302 of
    /// 302 (§65.8): `["space/" + id, id, 2]` for a space. A DM's shape is
    /// unconfirmed (no DM hit was captured), so this accepts only the
    /// mirrored form `"dm/" + id` and refuses anything else rather than
    /// guessing, as the finding insists. Built as a `GroupId`, never as a
    /// `Conversation.ID` by hand - `ChannelEventMapping.conversationID(_:)`
    /// stays the one place that prefix is spelled; this only ever *checks*
    /// the prefix, against a string the hit already carries.
    ///
    /// Not `private`: `SearchProbeReport+Anchor.swift`'s
    /// `fallbackGroupID(fromRawHit0:)` calls this directly too, so there is
    /// one rule for what a group reference looks like rather than two that
    /// can drift apart: a second copy would have to repeat the space branch's
    /// `items.count >= 3 && items[2] == 2` requirement, and one that dropped
    /// it would accept a reference this one refuses.
    static func groupReference(_ value: PBLiteValue?) -> GroupId? {
        guard let value, case let .array(items) = value, items.count >= 2,
              let prefixed = items[0].stringValue, let rawID = items[1].stringValue, !rawID.isEmpty
        else { return nil }
        if prefixed == "space/\(rawID)", items.count >= 3, items[2].intValue == 2 {
            var space = SpaceId()
            space.spaceID = rawID
            var group = GroupId()
            group.spaceID = space
            return group
        }
        if prefixed == "dm/\(rawID)" {
            var dm = DmId()
            dm.dmID = rawID
            var group = GroupId()
            group.dmID = dm
            return group
        }
        return nil
    }

    /// `[8]` (field 9), decoded like history's annotations, with search
    /// highlights stripped first. Not `private`, like `ChannelEventMapping
    /// .mentions(_:)`/`.links(_:)`/`.attachments(_:)`: a highlight's removal
    /// has no effect any of those three can show (none of them read a
    /// `FORMAT_DATA` annotation), so the only way to pin this is to call it
    /// directly, as `SearchHitMappingTests` does.
    static func mappedAnnotations(_ value: PBLiteValue?) -> [GChatBridgeCore.Annotation] {
        (value?.arrayValue ?? [])
            .filter { !isSearchHighlight($0) }
            .map { PBLiteDecoder.decode(GChatBridgeCore.Annotation.self, from: $0).message }
    }

    /// Whether a raw annotation is a search-highlight span: `FORMAT_DATA`
    /// (type 8) whose `format_metadata` (field 8, index 7) is `[13]` -
    /// purple's `FormatMetadata.FormatType.SEARCH_HIGHLIGHT`, a value the
    /// vendored enum has no case for (it stops at `CLIENT_HIDDEN` = 12). A
    /// typed decode of that annotation clears `hasFormatType` instead of
    /// reporting 13 (`CLAUDE.md`'s proto2 closed-enum rule), so checking the
    /// decoded `Annotation.formatMetadata.formatType` could never find it -
    /// this has to read the raw value before `PBLiteDecoder` ever sees it.
    ///
    /// **Both halves of the shape matter.** Annotation *type* 13 is a real,
    /// unrelated kind (`UPLOAD_METADATA`, kept); checking `format_metadata ==
    /// [13]` alone, without first requiring `type == 8`, would be the
    /// collision §65.8 names if a value ever happened to land at index 7 on
    /// some other annotation. Checking `type == 8` alone, without the
    /// `format_metadata` value, would instead treat every ordinary
    /// `FORMAT_DATA` span (a `BULLETED_LIST`, say) as a highlight and drop it.
    static func isSearchHighlight(_ annotation: PBLiteValue) -> Bool {
        guard annotation[0]?.intValue == GChatBridgeCore.AnnotationType.formatData.rawValue else {
            return false
        }
        return annotation[7]?[0]?.intValue == 13
    }
}

/// One hit's own pblite fields (§65.8): a message of its own, not a
/// `GChatBridgeCore.Message` - field N sits at index N-1, and a field above
/// 47 can instead be a key in a trailing object, the same merge
/// `PBLiteFieldSource`'s rule 3 does for every other pblite message. Written
/// by hand because that merge is not exposed outside `GChatBridgeCore`.
private struct SearchHitFields {
    private let items: [PBLiteValue]
    private let trailing: [String: PBLiteValue]

    init?(_ value: PBLiteValue) {
        guard case var .array(items) = value else { return nil }
        if let last = items.last, case let .object(object) = last {
            items.removeLast()
            trailing = object
        } else {
            trailing = [:]
        }
        self.items = items
    }

    /// Field `number`'s value: at index `number - 1`, or the trailing
    /// object's key `"number"` when it is there instead (field 63 was, on
    /// 153 of 302 hits; field 58 on 2).
    func field(_ number: Int) -> PBLiteValue? {
        let index = number - 1
        if index >= 0, index < items.count, !items[index].isNull {
            return items[index]
        }
        if let value = trailing[String(number)], !value.isNull {
            return value
        }
        return nil
    }
}

private extension PBLiteValue {
    /// `nil` past the array's bounds, on a null, or when `self` is not an
    /// array - a hit shorter than expected reads as "field absent" rather
    /// than crashing.
    subscript(_ index: Int) -> PBLiteValue? {
        guard case let .array(items) = self, items.indices.contains(index), !items[index].isNull else {
            return nil
        }
        return items[index]
    }

    /// A 64-bit integer from either representation pblite sends one in: a
    /// decimal string (§65.8's 16-digit `create_time`, too large for JSON's
    /// binary64) or a JSON number.
    var int64Value: Int64? {
        switch self {
        case let .string(text): Int64(text)
        case let .number(number): number.exactInteger()
        default: nil
        }
    }
}
