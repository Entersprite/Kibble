import Foundation
import GChatBridgeCore

/// What `list_topics` pages carry in field 21 (`Message.reactions`) - counts
/// only (reactions spec §0). Never an id, an emoji, a shortcode or a URL: the
/// emoji itself is content, and the report is pasted into `findings.md`.
struct ReactionShapes: Equatable {
    var messages = 0
    var withReactions = 0
    var reactions = 0
    var unicode = 0
    var custom = 0
    var customWithURL = 0
    /// Neither a unicode string nor a custom emoji.
    var neither = 0
    var includesMe = 0
    var withCreateTimestamp = 0
    /// `count` value → how many reactions had it. Counts are tallies, not content.
    var countTally: [Int: Int] = [:]
    /// Top-level field numbers inside each `Emoji`, from a byte walk → how many
    /// emoji carried one, so a field neither proto names still shows
    /// (`CLAUDE.md`: believe the walk).
    var emojiFields: [Int: Int] = [:]
    /// Top-level field numbers inside each `Reaction` itself, from the same
    /// byte walk one level up. A reactor-identity field would sit at the
    /// `Reaction` level, not inside its `Emoji`, and `emojiFields`'s walk
    /// cannot see it.
    var reactionFields: [Int: Int] = [:]
    /// How many reactions' `Emoji` could not be re-serialized for the byte
    /// walk, so a failure reads as "none" never silently. **`[Verify]` this
    /// ever happens** - every field the vendored proto declares on `Emoji`,
    /// `CustomEmoji` and `Reaction` is `optional`, so nothing known today
    /// makes `serializedBytes()` throw; counted anyway so a future required
    /// field does not read as "walked, found nothing" instead of "could not
    /// walk".
    var walkFailures = 0
    /// The first message with a reaction: what the `list_messages` check asks
    /// for. Held, never printed.
    var firstReacted: ReactedMessage?
    /// The first custom emoji's `ephemeral_url`. Held, never printed.
    var firstCustomURL: String?

    struct ReactedMessage: Equatable {
        let messageID: String
        let parent: MessageParentId
        let reactionCount: Int
    }
}

/// The probe's reaction sections. Its own file for `file_length`, like the
/// mentions section; pure apart from `appendReactionSections`.
extension APIProbeReport {
    static func reactionShapes(_ messages: [GChatBridgeCore.Message]) -> ReactionShapes {
        var shapes = ReactionShapes()
        for message in messages {
            shapes.messages += 1
            guard !message.reactions.isEmpty else { continue }
            shapes.withReactions += 1
            if shapes.firstReacted == nil {
                shapes.firstReacted = ReactionShapes.ReactedMessage(
                    messageID: message.id.messageID, parent: message.id.parentID,
                    reactionCount: message.reactions.count
                )
            }
            for reaction in message.reactions {
                count(reaction, into: &shapes)
            }
        }
        return shapes
    }

    private static func count(_ reaction: GChatBridgeCore.Reaction, into shapes: inout ReactionShapes) {
        shapes.reactions += 1
        let emoji = reaction.emoji
        if emoji.hasCustomEmoji {
            shapes.custom += 1
            if emoji.customEmoji.hasEphemeralURL, !emoji.customEmoji.ephemeralURL.isEmpty {
                shapes.customWithURL += 1
                shapes.firstCustomURL = shapes.firstCustomURL ?? emoji.customEmoji.ephemeralURL
            }
        } else if emoji.hasUnicode, !emoji.unicode.isEmpty {
            shapes.unicode += 1
        } else {
            shapes.neither += 1
        }
        if reaction.currentUserParticipated {
            shapes.includesMe += 1
        }
        if reaction.hasCreateTimestamp {
            shapes.withCreateTimestamp += 1
        }
        shapes.countTally[Int(reaction.count), default: 0] += 1
        if let bytes: Data = try? emoji.serializedBytes() {
            for number in Set(ProtoFieldScan.fields(in: bytes).fields.map(\.number)) {
                shapes.emojiFields[number, default: 0] += 1
            }
        } else {
            shapes.walkFailures += 1
        }
        if let bytes: Data = try? reaction.serializedBytes() {
            for number in Set(ProtoFieldScan.fields(in: bytes).fields.map(\.number)) {
                shapes.reactionFields[number, default: 0] += 1
            }
        }
    }

    static func reactionShapesLines(_ shapes: ReactionShapes) -> [String] {
        let walkFailureSuffix = shapes.walkFailures > 0 ? " (walk failures \(shapes.walkFailures))" : ""
        return [
            "  messages with reactions: \(shapes.withReactions)/\(shapes.messages)",
            "  reactions: \(shapes.reactions); unicode \(shapes.unicode), custom \(shapes.custom) "
                + "(with ephemeral_url \(shapes.customWithURL)), neither \(shapes.neither)",
            "  current_user_participated: \(shapes.includesMe); create_timestamp present: "
                + "\(shapes.withCreateTimestamp)",
            "  count values: \(reactionTally(shapes.countTally))",
            "  Emoji fields (byte walk): \(reactionTally(shapes.emojiFields))\(walkFailureSuffix)",
            "  Reaction fields (byte walk): \(reactionTally(shapes.reactionFields))"
        ]
    }

    /// `value×count` pairs, keys ascending; `none` when empty.
    private static func reactionTally(_ counts: [Int: Int]) -> String {
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }

    /// One more `list_topics` call on the minimum-viable rung (the convention
    /// every section here follows), then two checks on what it found:
    /// - `list_messages` on the first reacted message's topic - the refetch
    ///   plan 1b's live path rests on (spec §2.2), never yet sent by this
    ///   client (`APIMethod.listMessages`);
    /// - the first custom emoji's `ephemeral_url`, through
    ///   `AttachmentFetch.fetch(url:)`'s credential rules.
    static func appendReactionSections(
        client: ProtoAPIClient,
        group: GroupId,
        fetch: AttachmentFetch?,
        lines: inout [String]
    ) async {
        lines.append("reaction shapes (counts only):")
        let response: ListTopicsResponse
        do {
            response = try await client.call(
                .listTopics,
                TopicsRequestLadder.minimumViable(for: group).request
            )
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        let shapes = reactionShapes(response.topics.flatMap(\.replies))
        lines.append(contentsOf: reactionShapesLines(shapes))
        lines.append("")
        lines.append("reaction refetch (list_messages on the first reacted message's topic):")
        if let target = shapes.firstReacted {
            await appendRefetchCheck(client: client, target: target, lines: &lines)
        } else {
            lines.append("  no reacted message on this page - react to one in this conversation and rerun")
        }
        lines.append("")
        lines.append("custom emoji image (first ephemeral_url):")
        if let address = shapes.firstCustomURL.flatMap(URL.init(string:)), let fetch {
            let outcome: Result<FetchedAttachment, AttachmentFetchFailure>
            do {
                outcome = try await .success(fetch.fetch(url: address))
            } catch {
                outcome = .failure(error)
            }
            lines.append(contentsOf: attachmentFetchLines(label: "ephemeral_url", outcome: outcome))
        } else {
            lines.append("  no custom emoji with an ephemeral_url on this page")
        }
    }

    private static func appendRefetchCheck(
        client: ProtoAPIClient,
        target: ReactionShapes.ReactedMessage,
        lines: inout [String]
    ) async {
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID = target.parent
        request.pageSize = 50
        do {
            let response = try await client.call(.listMessages, request)
            let index = response.messages.firstIndex { $0.id.messageID == target.messageID }
            let found = index.map { response.messages[$0].reactions.count }
            lines.append("  messages returned: \(response.messages.count); target "
                + (index.map { "found at \($0 + 1)" } ?? "not found")
                + "; reactions there \(found.map(String.init) ?? "-") (list_topics: \(target.reactionCount))")
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
        }
    }
}
