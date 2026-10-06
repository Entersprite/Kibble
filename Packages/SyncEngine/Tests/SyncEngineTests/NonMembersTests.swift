import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Who the composer asks about at Return (mention non-members spec §3.4).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NonMembersTests {
    private static let outsider = Member(id: Member.ID("outsider"), kind: .human, displayName: "Out Sider")

    private static func message(_ ids: [String]) -> ComposedMessage {
        ComposedMessage(
            text: "x",
            mentions: ids.map { Mention(target: .user(Member.ID($0)), start: 0, length: 1) }
        )
    }

    /// Review Focus 1: never asked about, so never a non-member.
    @Test func aMemberPickedFromTheListIsNeverANonMember() async throws {
        let model = try await DirectorySearchTests.model(RecordingBackend(directory: [Self.outsider]))
        #expect(await model.nonMembers(in: Self.message(["fixture-other"])).isEmpty)
        await model.stop()
    }

    @Test func aCheckedOutsiderIsANonMember() async throws {
        let model = try await DirectorySearchTests.model(RecordingBackend(directory: [Self.outsider]))
        model.checkMembership(Self.outsider.id)
        #expect(await model.nonMembers(in: Self.message(["outsider"])) == [Self.outsider.id])
        await model.stop()
    }

    @Test func aCheckedMemberIsNot() async throws {
        let model = try await DirectorySearchTests.model(RecordingBackend(directory: [Self.outsider]))
        model.checkMembership(Member.ID("fixture-other"))
        #expect(await model.nonMembers(in: Self.message(["fixture-other"])).isEmpty)
        await model.stop()
    }

    @Test func aCheckThatNeverAnswersCountsAsANonMemberAfterTheWait() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await DirectorySearchTests.model(backend)
        await backend.holdMemberships(true)
        model.checkMembership(Self.outsider.id)
        #expect(await model.nonMembers(in: Self.message(["outsider"])) == [Self.outsider.id])
        await backend.releaseHeldMembership()
        await model.stop()
    }

    @Test func aCheckStillRunningIsAwaited() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await DirectorySearchTests.model(backend)
        await backend.holdMemberships(true)
        model.checkMembership(Self.outsider.id)
        await settleAutoMarkRead(until: "the check is held") { await backend.heldMembershipCount == 1 }
        await backend.releaseHeldMembership()
        #expect(await model.nonMembers(in: Self.message(["outsider"])) == [Self.outsider.id])
        await model.stop()
    }

    @Test func oneCheckPerPersonPerConversation() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await DirectorySearchTests.model(backend)
        model.checkMembership(Self.outsider.id)
        model.checkMembership(Self.outsider.id)
        _ = await model.nonMembers(in: Self.message(["outsider"]))
        #expect(await backend.membershipChecks == [Self.outsider.id])
        await model.stop()
    }

    /// Review finding 3: once "Add and send" has made them a member, picking
    /// them again must not ask again.
    @Test func aPersonAddedSinceTheirCheckIsNotAskedAboutAgain() async throws {
        let model = try await DirectorySearchTests.model(RecordingBackend(directory: [Self.outsider]))
        model.checkMembership(Self.outsider.id)
        #expect(await model.nonMembers(in: Self.message(["outsider"])) == [Self.outsider.id])
        model.send(ComposedMessage(text: "@Out Sider", mentions: [
            Mention(target: .user(Self.outsider.id), start: 0, length: 10, mode: .invite)
        ]))
        await settleAutoMarkRead(until: "they are a member") {
            model.mentionCandidates.contains { $0.id == Self.outsider.id }
        }
        #expect(await model.nonMembers(in: Self.message(["outsider"])).isEmpty)
        await model.stop()
    }

    /// Review finding 2: a send whose conversation is no longer open is
    /// handed back to that conversation's draft, never posted to the new one.
    @Test func aSendForAConversationNoLongerOpenIsHandedBack() async throws {
        let backend = RecordingBackend()
        let model = try await DirectorySearchTests.model(backend)
        model.select(Conversation.ID("dm:1"))
        await settleAutoMarkRead()
        let message = ComposedMessage(text: "meant for the space")
        model.send(message, in: Conversation.ID("space:1"))
        await settleAutoMarkRead()
        let sends = await backend.commands.filter {
            if case .sendMessage = $0 {
                true
            } else {
                false
            }
        }
        #expect(sends.isEmpty)
        model.select(Conversation.ID("space:1"))
        await settleAutoMarkRead()
        #expect(model.failedDraft == message)
        await model.stop()
    }

    @Test func aSendForTheOpenConversationIsPosted() async throws {
        let backend = RecordingBackend()
        let model = try await DirectorySearchTests.model(backend)
        model.send(ComposedMessage(text: "hello"), in: Conversation.ID("space:1"))
        await settleAutoMarkRead(until: "posted") { model.messages.contains { $0.text == "hello" } }
        await model.stop()
    }

    @Test func aKeptDraftComesBackToItsConversation() async throws {
        let model = try await DirectorySearchTests.model(RecordingBackend())
        model.keepDraft(ComposedMessage(text: "unsent"), in: Conversation.ID("space:1"))
        #expect(model.failedDraft == ComposedMessage(text: "unsent"))
        await model.stop()
    }
}
