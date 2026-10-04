import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The probe's reaction section: counts only, and nothing that could carry an
/// id, an emoji, a shortcode or a URL.
struct ReactionProbeTests {
    private func message(
        id: String,
        topic: String = "t-1",
        reactions: [GChatBridgeCore.Reaction]
    ) -> GChatBridgeCore.Message {
        var message = GChatBridgeCore.Message()
        message.id.messageID = id
        message.id.parentID.topicID.topicID = topic
        message.id.parentID.topicID.groupID.spaceID.spaceID = "s-1"
        message.reactions = reactions
        return message
    }

    private func unicode(_ text: String, count: Int32, mine: Bool = false) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.unicode = text
        reaction.count = count
        reaction.currentUserParticipated = mine
        return reaction
    }

    private func custom(url: String?, count: Int32) -> GChatBridgeCore.Reaction {
        var reaction = GChatBridgeCore.Reaction()
        reaction.emoji.customEmoji.uuid = "secret-uuid"
        reaction.emoji.customEmoji.shortcode = ":secretshortcode:"
        if let url {
            reaction.emoji.customEmoji.ephemeralURL = url
        }
        reaction.count = count
        return reaction
    }

    @Test func itCountsKindsAndTalliesCounts() {
        let shapes = APIProbeReport.reactionShapes([
            message(
                id: "m-1",
                reactions: [unicode("👍", count: 2, mine: true), custom(url: "https://x.invalid/e", count: 1)]
            ),
            message(id: "m-2", reactions: []),
            message(id: "m-3", reactions: [unicode("🎉", count: 1)])
        ])
        #expect(shapes.messages == 3)
        #expect(shapes.withReactions == 2)
        #expect(shapes.reactions == 3)
        #expect(shapes.unicode == 2)
        #expect(shapes.custom == 1)
        #expect(shapes.customWithURL == 1)
        #expect(shapes.includesMe == 1)
        #expect(shapes.countTally == [1: 2, 2: 1])
        #expect(shapes.firstReacted?.messageID == "m-1")
        #expect(shapes.firstCustomURL == "https://x.invalid/e")
    }

    /// The leak test's sentinels are lowercase and inside every value a line
    /// could print (`CLAUDE.md`: pick the secret from inside the masker's
    /// exception).
    @Test func noLineCarriesAnIDAnEmojiAShortcodeOrAURL() {
        let shapes = APIProbeReport.reactionShapes([
            message(
                id: "secretmessageid",
                topic: "secrettopicid",
                reactions: [
                    unicode("👍", count: 2),
                    custom(url: "https://secrethost.invalid/secretpath", count: 1)
                ]
            )
        ])
        let text = APIProbeReport.reactionShapesLines(shapes).joined(separator: "\n")
        #expect(!text.contains("secret"))
        #expect(!text.contains("👍"))
    }

    /// The image fetch's lines go through the attachment probe's own
    /// reporting (`renderHost`), which keeps an unknown host's registrable
    /// domain - its last two labels - **on purpose**, so a report can say
    /// which service answered (`findings.md` §52 diagnosed hosts exactly this
    /// way). What must never print is everything that domain does not need:
    /// any subdomain label below it, a path segment, or a query name. So the
    /// sentinel sits only in those - `secretlabel` (a subdomain label kept out
    /// of the registrable domain), the path segments and the query name - and
    /// never in the registrable domain itself (`example.invalid`).
    @Test func theImageFetchLinesCarryNoAddress() {
        let fetched = FetchedAttachment(
            body: Data("PNG".utf8), contentType: "image/png",
            hops: [AttachmentHop(
                host: "secretlabel.lh3.example.invalid", status: 200, carriedCredentials: false,
                pathSegments: ["secretsegment", "secrettoken"], queryNames: ["secretname"], location: nil
            )]
        )
        let text = APIProbeReport.attachmentFetchLines(label: "ephemeral_url", outcome: .success(fetched))
            .joined(separator: "\n")
        #expect(!text.contains("secret"))
    }

    @Test func aMessageWithNoReactionsAnywhereSaysSo() {
        let lines = APIProbeReport.reactionShapesLines(APIProbeReport.reactionShapes([message(
            id: "m",
            reactions: []
        )]))
        #expect(lines.contains { $0.contains("messages with reactions: 0/1") })
    }
}
