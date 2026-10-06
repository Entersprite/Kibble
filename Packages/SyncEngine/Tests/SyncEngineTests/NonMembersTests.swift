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
        model.checkMembership(Member.ID("fixture-other"))
        #expect(await model.nonMembers(in: Self.message(["fixture-other"])) == [Member.ID("fixture-other")])
        await backend.releaseHeldMembership()
        await model.stop()
    }

    @Test func aCheckStillRunningIsAwaited() async throws {
        let backend = RecordingBackend(directory: [Self.outsider])
        let model = try await DirectorySearchTests.model(backend)
        await backend.holdMemberships(true)
        model.checkMembership(Member.ID("fixture-other"))
        await settleAutoMarkRead(until: "the check is held") { await backend.heldMembershipCount == 1 }
        await backend.releaseHeldMembership()
        #expect(await model.nonMembers(in: Self.message(["fixture-other"])).isEmpty)
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
}
