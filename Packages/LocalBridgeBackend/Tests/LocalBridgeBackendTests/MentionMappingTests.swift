import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// `USER_MENTION` annotations becoming `ChatKit.Mention`s
/// (`ChannelEventMapping.mentions(_:)`, mentions spec §2).
///
/// **These fixtures are still built from the vendored proto's field numbers,
/// not from a capture**, and `MentionFixture`'s doc comment names the fields.
/// Their shape now matches what live traffic was measured to carry
/// (`findings.md` §40.1, §41.2): `USER_MENTION` (type 6), metadata kind
/// `MENTION` (3), presence bits set, spans in UTF-16 code units (§41.1). The
/// probe's `mention shapes` section keeps measuring; `MentionShapesTests`
/// covers its counting.
struct MentionMappingTests {
    private typealias Fixture = MentionFixture

    // MARK: - The two kinds that are mentions

    @Test func aMentionOfOneUserBecomesAUserTargetWithItsSpan() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mention, user: "u-2", start: 0, length: 5)
        ])
        // The id in the same raw form `domainMessage` uses for `sender`.
        #expect(mapped == [ChatKit.Mention(target: .user(Member.ID("u-2")), start: 0, length: 5)])
    }

    @Test func aMentionOfEveryoneBecomesTheAllTarget() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mentionAll, user: nil, start: 30, length: 4)
        ])
        #expect(mapped == [ChatKit.Mention(target: .all, start: 30, length: 4)])
    }

    // MARK: - What is not a mention

    /// `INVITE` (1) and type 6 are mentions now (mention non-members spec
    /// §2, `findings.md` §58); these three still are not.
    @Test(arguments: [
        UserMentionMetadata.TypeEnum.uninvite, .failedToAdd, .unspecified
    ])
    func theInviteKindsAreNotMentions(_ kind: UserMentionMetadata.TypeEnum) {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(kind, user: "u-2", start: 0, length: 5)
        ])
        #expect(mapped.isEmpty)
    }

    @Test func anAnnotationOfAnotherTypeIsNotAMention() {
        var annotation = Fixture.mention(.mention, user: "u-2", start: 0, length: 5)
        annotation.type = .url
        #expect(ChannelEventMapping.mentions([annotation]).isEmpty)
    }

    /// Review Focus 5. No `type` set means the presence bit is clear, which is
    /// exactly what a kind outside the proto2 enum looks like after a typed
    /// decode.
    ///
    /// **This pins the outcome (skipped); it is not coverage for the
    /// `metadata.hasType` guard.** The generated getter is
    /// `_type ?? .unspecified`, which the switch already rejects, so deleting
    /// the guard leaves this test green. The count that does discriminate is
    /// `APIProbeReport.countKind`'s `hasType` gate, whose deletion
    /// `MentionShapesTests.aKindTheProtoCannotNameIsCountedAsAbsentWithItsRawValue`
    /// catches (mutation M5).
    @Test func aMentionWhoseKindIsAbsentIsSkippedRatherThanGuessed() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(nil, user: "u-2", start: 0, length: 5)
        ])
        #expect(mapped.isEmpty)
    }

    /// The decoded form of the case above: field 2 on the wire, but a value the
    /// vendored enum cannot name, so SwiftProtobuf keeps it in `unknownFields`.
    @Test func aMentionWhoseKindTheProtoCannotNameIsSkipped() throws {
        let annotation = try Fixture.mentionWithRawKind(7, start: 0, length: 5)
        #expect(!annotation.userMentionMetadata.hasType) // positive control on the fixture
        #expect(ChannelEventMapping.mentions([annotation]).isEmpty)
    }

    @Test func aMentionWithNoUserIsSkipped() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mention, user: nil, start: 0, length: 5)
        ])
        #expect(mapped.isEmpty)
    }

    @Test func aMentionWithAnEmptyUserIsSkipped() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mention, user: "", start: 0, length: 5)
        ])
        #expect(mapped.isEmpty)
    }

    @Test func aMentionWithNoStartIsSkipped() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mention, user: "u-2", start: nil, length: 5)
        ])
        #expect(mapped.isEmpty)
    }

    @Test func aMentionWithNoLengthIsSkipped() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mention, user: "u-2", start: 0, length: nil)
        ])
        #expect(mapped.isEmpty)
    }

    /// Order is the wire's, and a skipped annotation drops out without taking
    /// its neighbours with it.
    @Test func mentionsKeepTheWireOrderAndSkipOnlyTheMalformedOne() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mention, user: "u-2", start: 0, length: 5),
            Fixture.mention(.uninvite, user: "u-3", start: 6, length: 5),
            Fixture.mention(.mentionAll, user: nil, start: 12, length: 4)
        ])
        #expect(mapped == [
            ChatKit.Mention(target: .user(Member.ID("u-2")), start: 0, length: 5),
            ChatKit.Mention(target: .all, start: 12, length: 4)
        ])
    }

    // MARK: - The one function both paths share

    /// `domainMessage(_:)` is what the channel and `HistoryMapping` both call,
    /// so a mention reaching a `ChatKit.Message` here proves both paths carry
    /// them.
    @Test func domainMessageCarriesTheMentions() throws {
        let wire = Fixture.reply(
            text: "@Dana hello",
            annotations: [Fixture.mention(.mention, user: "u-2", start: 0, length: 5)]
        )
        let message = try #require(ChannelEventMapping.domainMessage(wire))
        #expect(message.mentions == [
            ChatKit.Mention(target: .user(Member.ID("u-2")), start: 0, length: 5)
        ])
    }

    @Test func domainMessageWithoutAnnotationsHasNoMentions() throws {
        let message = try #require(ChannelEventMapping.domainMessage(Fixture.reply()))
        #expect(message.mentions.isEmpty)
    }

    // MARK: - Mentions of people outside the space (findings.md §58)

    @Test func inviteMapsToAUserMentionWithInviteMode() {
        let mapped = ChannelEventMapping.mentions([Fixture.mention(
            .invite,
            user: "u-2",
            start: 0,
            length: 5
        )])
        #expect(mapped == [ChatKit.Mention(
            target: .user(Member.ID("u-2")),
            start: 0,
            length: 5,
            mode: .invite
        )])
    }

    @Test func typeSixMapsToWithoutAdding() {
        let mapped = ChannelEventMapping.mentions([
            Fixture.mention(.mentionWithoutAdding, user: "u-2", start: 0, length: 5)
        ])
        #expect(mapped.first?.mode == .withoutAdding)
    }

    /// From raw bytes, as the wire sends it: the proto now names 6, so the
    /// presence bit survives and the mention is kept.
    @Test func typeSixFromRawBytesMaps() throws {
        let annotation = try Fixture.mentionWithRawKind(6, start: 0, length: 5, user: "u-2")
        #expect(annotation.userMentionMetadata.hasType)
        #expect(ChannelEventMapping.mentions([annotation]).first?.mode == .withoutAdding)
    }

    @Test func uninviteIsStillIgnored() {
        #expect(ChannelEventMapping.mentions([Fixture.mention(.uninvite, user: "u-2", start: 0, length: 5)])
            .isEmpty)
    }

    @Test func aPlainMentionIsStillModeMention() {
        let mapped = ChannelEventMapping.mentions([Fixture.mention(
            .mention,
            user: "u-2",
            start: 0,
            length: 5
        )])
        #expect(mapped.first?.mode == .mention)
    }
}
