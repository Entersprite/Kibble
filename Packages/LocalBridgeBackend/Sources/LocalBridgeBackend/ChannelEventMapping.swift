import ChatKit
import Foundation
import GChatBridgeCore

/// Wire events becoming domain events.
///
/// This is the translation the architecture puts in exactly one place: the core
/// knows nothing about `ChatKit`, and `ChatKit` knows nothing about protobuf, so
/// the package that imports both is where they meet.
///
/// ## Two rules, both from `findings.md` §12.1.1
///
/// **Nothing is dropped.** The vendored proto's `EventType` stops at 50 and live
/// traffic carried 51, 64, 70 and 83 — so a mapping that handled only what it
/// recognised would silently lose four kinds of event, and regenerating from a
/// newer proto would shrink that set without ever emptying it. Everything this
/// does not map becomes `.unknown`, which is the case `ChatKit` added for
/// precisely this and which re-encodes verbatim.
///
/// **Nameable is not the same as mapped.** `SESSION_READY` has a name in the
/// proto and no domain meaning here; it is routed exactly like tag 64. Treating
/// "the proto knows this" as "we handle this" is how events go missing while
/// every test still passes.
public enum ChannelEventMapping {
    /// The discriminator for a routed event.
    ///
    /// The **number** is the identity, not the proto's name for it: `ChatKit`'s
    /// wire rule is that an unknown discriminator re-encodes verbatim, and a
    /// generated Swift case name is not a thing to promise across versions. A
    /// tag the proto cannot name has no name to use anyway.
    static func discriminator(for tag: Int?) -> String {
        "googlechat.eventType.\(tag.map(String.init) ?? "untagged")"
    }

    /// Maps one channel event's bodies onto domain events, one for one.
    public static func chatEvents(from event: ChannelEvent) -> [ChatEvent] {
        event.bodies.map(chatEvent(from:))
    }

    private static func chatEvent(from body: ChannelEventBody) -> ChatEvent {
        // Dispatch on the **type tag**, never on what the body happens to
        // decode as - `findings.md` §12.1.3. `MESSAGE_UPDATED` and
        // `MESSAGE_POSTED` share body field 6, so the tag is the only thing
        // that separates an edit from a new message.
        switch body.type {
        case .messagePosted:
            message(in: body).map(ChatEvent.messageReceived) ?? routed(body)
        case .messageUpdated:
            message(in: body).map(ChatEvent.messageUpdated) ?? routed(body)
        case .groupViewed:
            readState(in: body) ?? routed(body)
        default:
            routed(body)
        }
    }

    private static func routed(_ body: ChannelEventBody) -> ChatEvent {
        .unknown(
            type: discriminator(for: body.typeTag),
            payload: JSONValue(body.value)
        )
    }

    /// Decodes the message out of a `MESSAGE_POSTED` or `MESSAGE_UPDATED` body.
    ///
    /// Returns `nil` when the body is not one of those, or when it is and the
    /// message lacks the identity a domain message cannot be built without. The
    /// caller routes it instead — **a `Message` with an invented id is
    /// indistinguishable from a real one once it is in the store**, which makes
    /// fabricating one worse than admitting the body was not understood.
    private static func message(in body: ChannelEventBody) -> ChatKit.Message? {
        guard body.type == .messagePosted || body.type == .messageUpdated else { return nil }
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        // **Both arrive in body field 6.** The vendored proto has no
        // `message_updated` member in `EventBody`'s oneof at all, and the
        // captures confirm an edit populates the same field a post does - so
        // the *type tag* is the only thing that tells them apart, and reading
        // the body alone would call every edit a new message.
        guard case let .messagePosted(event)? = decoded.message.type else { return nil }
        return domainMessage(event.message)
    }

    /// Decodes the read state out of a `GROUP_VIEWED` body.
    ///
    /// This is the event that clears a badge when the conversation was read
    /// somewhere else - another device, or the web client. The reference does
    /// the same at `mautrix_googlechat/portal.py:557`.
    ///
    /// **`unread: 0` is an inference, and the only one in this mapping.**
    /// `GroupViewedEvent` carries `group_id` and `view_time` and no count, so
    /// there is nothing to read. Viewing a group is what clears it, so 0 is
    /// right in every case anyone has been able to construct - but it is
    /// reasoning, not observation, and `findings.md` marks it `[Verify]`. The
    /// alternative, refetching the world per event, is not worth an HTTP call
    /// for a number the next `mark_group_readstate` will correct anyway.
    ///
    /// `nil` when the group id is neither namespace, or `view_time` is
    /// absent, for the same reason `message(in:)` returns `nil` without an
    /// id: the caller routes it, and a fabricated conversation, or a 1970
    /// read position, is indistinguishable from a real one once it is in the
    /// store.
    private static func readState(in body: ChannelEventBody) -> ChatEvent? {
        guard body.type == .groupViewed else { return nil }
        let decoded = PBLiteDecoder.decode(Event.EventBody.self, from: body.value)
        guard case let .groupViewed(event)? = decoded.message.type else { return nil }
        guard let conversationID = conversationID(event.groupID) else { return nil }
        // **Presence decides, never the value**, as in
        // `WorldMapping.readPosition`: an absent `view_time` reads as 0,
        // which is 1970, and would turn every mention in the conversation
        // unread. Routed instead, like a body with no group id.
        guard event.hasViewTime else { return nil }
        return .readStateChanged(
            conversationID: conversationID,
            lastReadAt: Microseconds.date(event.viewTime),
            unread: 0
        )
    }

    /// Not `private`: `HistoryMapping` reuses this exact translation for
    /// `Topic.replies`, so the channel and the history call cannot drift apart
    /// on the microsecond-string `create_time` handling `findings.md` §2.3
    /// documents. Duplicating this would be the same defect a reviewer already
    /// caught once on this branch.
    static func domainMessage(_ message: GChatBridgeCore.Message) -> ChatKit.Message? {
        let identifier = message.id.messageID
        guard !identifier.isEmpty else { return nil }
        guard let conversationID = conversationID(message.id.parentID.topicID.groupID) else {
            return nil
        }
        return ChatKit.Message(
            id: ChatKit.Message.ID(identifier),
            conversationID: conversationID,
            threadID: MessageThread.ID(message.id.parentID.topicID.topicID),
            sender: Member.ID(message.creator.userID.id),
            text: message.textBody,
            // Microseconds since the epoch, and they arrive as a *string*:
            // pblite sends 64-bit values that way because a 16-digit number does
            // not survive JSON's binary64. `PBLiteDecoder` coerces it back.
            createdAt: Microseconds.date(message.createTime),
            editedAt: message.hasLastEditTime
                ? Microseconds.date(message.lastEditTime)
                : nil,
            isDeleted: message.hasDeleteTime && message.deleteTime > 0,
            // Echoed straight back by the server on a message we sent, and
            // absent on everyone else's - which is exactly the distinction
            // `Message.localID` documents. `nil` rather than `""` for absent,
            // because an empty string would match an optimistic copy that also
            // had none.
            localID: message.hasLocalID ? message.localID : nil,
            mentions: mentions(message.annotations)
        )
    }

    /// A message's mentions (mentions spec §2): `USER_MENTION` annotations of
    /// kind `MENTION` or `MENTION_ALL`. The invite kinds are not mentions.
    /// **An absent presence bit is skipped, never guessed:** the proto is
    /// proto2, so a metadata type outside the vendored enum clears `hasType`
    /// and would otherwise read as `.unspecified` (`CLAUDE.md`, the typed
    /// decode rule).
    ///
    /// The `metadata.hasType` guard changes no output today: an unset `type`
    /// reads `.unspecified`, which the switch already rejects, so deleting it
    /// leaves every test green. It is kept so that a later case for
    /// `.unspecified` cannot start mapping values it never saw.
    ///
    /// Measured on live `list_topics` pages (`findings.md` §40.1, §41.2): a
    /// mention arrives as `USER_MENTION` (type 6) with metadata kind
    /// `MENTION` (3), presence bits set, and a span counted in UTF-16 code
    /// units (§41.1). Live channel events carrying them are `[Verify]` beyond
    /// the owner's reported check; `APIProbeReport.mentionShapes(_:)` keeps
    /// measuring.
    static func mentions(_ annotations: [GChatBridgeCore.Annotation]) -> [ChatKit.Mention] {
        annotations.compactMap { annotation in
            guard annotation.hasType, annotation.type == .userMention,
                  case let .userMentionMetadata(metadata)? = annotation.metadata,
                  metadata.hasType, annotation.hasStartIndex, annotation.hasLength
            else { return nil }
            let target: ChatKit.Mention.Target
            switch metadata.type {
            case .mention:
                guard metadata.hasID, !metadata.id.id.isEmpty else { return nil }
                target = .user(Member.ID(metadata.id.id))
            case .mentionAll:
                target = .all
            case .unspecified, .invite, .uninvite, .failedToAdd:
                return nil
            }
            return ChatKit.Mention(
                target: target,
                start: Int(annotation.startIndex),
                length: Int(annotation.length)
            )
        }
    }

    /// A space id and a DM id are different namespaces on the wire.
    ///
    /// Prefixed rather than flattened, so two conversations that happen to share
    /// a raw identifier cannot merge into one. Anything else building a
    /// `Conversation.ID` from this protocol has to use this same function, which
    /// is why it is the only place the rule is written.
    static func conversationID(_ group: GroupId) -> Conversation.ID? {
        switch group.id {
        case let .spaceID(space) where !space.spaceID.isEmpty:
            Conversation.ID("space/\(space.spaceID)")
        case let .dmID(dm) where !dm.dmID.isEmpty:
            Conversation.ID("dm/\(dm.dmID)")
        default:
            nil
        }
    }

    /// The inverse of `conversationID(_:)` - the one other place this
    /// namespace rule has to be applied, so it lives right next to the
    /// function it undoes rather than being re-derived somewhere that could
    /// drift out of step with it (`LocalBridgeBackend+History.swift` needs a
    /// `GroupId` to ask `list_topics` for one conversation's history).
    ///
    /// `nil` for anything that is not exactly one of the two prefixes this
    /// package ever produces, **including a prefix with nothing after it** -
    /// `conversationID(_:)` itself never emits `"space/"` or `"dm/"` alone,
    /// since it requires a non-empty inner id, so accepting the empty suffix
    /// here would build a `GroupId` `conversationID(_:)` could never have
    /// produced and that would not round-trip back to the id it came from.
    static func groupID(for conversationID: Conversation.ID) -> GroupId? {
        let raw = conversationID.rawValue
        var group = GroupId()
        if let suffix = raw.dropFirstIfPrefixed(with: "space/"), !suffix.isEmpty {
            var space = SpaceId()
            space.spaceID = String(suffix)
            group.spaceID = space
            return group
        }
        if let suffix = raw.dropFirstIfPrefixed(with: "dm/"), !suffix.isEmpty {
            var dm = DmId()
            dm.dmID = String(suffix)
            group.dmID = dm
            return group
        }
        return nil
    }
}

private extension String {
    /// `nil` when `self` does not start with `prefix` at all - distinct from
    /// an empty result, which means the prefix matched and nothing followed
    /// it. `groupID(for:)` needs that distinction to reject `"space/"` alone
    /// rather than reading it as a valid, empty-id space.
    func dropFirstIfPrefixed(with prefix: String) -> Substring? {
        guard hasPrefix(prefix) else { return nil }
        return dropFirst(prefix.count)
    }
}

// MARK: - Carrying an unmapped body across the seam

extension JSONValue {
    /// Converts a pblite tree into the seam's JSON vocabulary.
    ///
    /// Lossless except in one place, and that place is documented rather than
    /// hidden: `JSONValue.number` is a `Double`, so an integer too large to be
    /// exact in one becomes a **string**. pblite already sends 64-bit values as
    /// strings for the same reason, so this matches what the wire does with them
    /// — and silently rounding an id would be far worse than changing its type.
    init(_ value: PBLiteValue) {
        switch value {
        case .null:
            self = .null
        case let .bool(flag):
            self = .bool(flag)
        case let .string(text):
            self = .string(text)
        case let .array(items):
            self = .array(items.map(JSONValue.init))
        case let .object(entries):
            self = .object(entries.mapValues(JSONValue.init))
        case let .number(number):
            self = JSONValue(number)
        }
    }

    private init(_ number: PBLiteNumber) {
        switch number {
        case let .double(value):
            self = .number(value)
        case let .integer(value):
            self = Double(exactly: value).map(JSONValue.number) ?? .string(String(value))
        case let .unsigned(value):
            self = Double(exactly: value).map(JSONValue.number) ?? .string(String(value))
        }
    }
}
