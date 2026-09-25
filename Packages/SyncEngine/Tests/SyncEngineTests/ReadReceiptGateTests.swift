import ChatKit
import Foundation
import Testing
@testable import SyncEngine

/// The gate is read at submit time - the same chokepoint ghost mode uses.
struct ReadReceiptGateTests {
    private let quiet = Conversation(id: Conversation.ID("dm/quiet"), kind: .directMessage)
    private let open = Conversation(id: Conversation.ID("dm/open"), kind: .directMessage)
    private let space = Conversation(id: Conversation.ID("space/s"), kind: .space)
    private let at = Date(timeIntervalSince1970: 1_790_000_000)

    /// `acceptWithoutForwarding` lets a submit succeed without a connected
    /// fixture, so a refusal here can only be the gate's.
    private func harness() async throws -> (SyncEngine, RecordingBackend) {
        let backend = RecordingBackend()
        await backend.acceptWithoutForwarding(true)
        let store = try ChatStore.inMemory()
        try store.apply([.replaceConversations([quiet, open, space])])
        return (SyncEngine(backend: backend, store: store), backend)
    }

    private func mark(_ conversation: Conversation) -> ChatCommand {
        .markRead(conversationID: conversation.id, upTo: at)
    }

    @Test func byDefaultEveryMarkIsPublished() async throws {
        let (engine, backend) = try await harness()
        #expect(await engine.submit(mark(quiet)))
        #expect(await backend.commands.count == 1)
    }

    @Test func withholdingRefusesEveryMark() async throws {
        let (engine, backend) = try await harness()
        engine.readReceipts.set(.withhold)
        #expect(await !(engine.submit(mark(open))))
        #expect(await backend.commands.isEmpty)
    }

    @Test func aConversationWithReceiptsOffIsRefusedAndItsNeighbourIsNot() async throws {
        let (engine, backend) = try await harness()
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .conversation(quiet.id), at: at, by: "t")
        engine.readReceipts.set(.resolve(settings))
        #expect(await !(engine.submit(mark(quiet))))
        #expect(await engine.submit(mark(open)))
        #expect(await backend.commands == [mark(open)])
    }

    /// The store supplies the kind, so a section rule reaches the conversation.
    @Test func aSectionRuleReachesItsConversations() async throws {
        let (engine, _) = try await harness()
        var settings = NotificationSettings()
        settings.setRule(
            NotificationRule(readReceipts: false),
            for: .section(.directMessages),
            at: at,
            by: "t"
        )
        engine.readReceipts.set(.resolve(settings))
        #expect(await !(engine.submit(mark(quiet))))
        #expect(await engine.submit(mark(space)))
    }

    /// A conversation the store has not listed yet resolves through Other -
    /// the fallback the notification path uses too. Only Other's rule
    /// changes, so the listed space beside it is the control.
    @Test func anUnlistedConversationResolvesThroughOther() async throws {
        let (engine, _) = try await harness()
        let unlisted = ChatCommand.markRead(conversationID: Conversation.ID("space/unlisted"), upTo: at)
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .section(.other), at: at, by: "t")
        engine.readReceipts.set(.resolve(settings))
        #expect(await !(engine.submit(unlisted)))
        #expect(await engine.submit(mark(space)))

        settings.setRule(NotificationRule(readReceipts: true), for: .section(.other), at: at, by: "t")
        engine.readReceipts.set(.resolve(settings))
        #expect(await engine.submit(unlisted))
    }

    /// Review Focus 4: receipts switched off after a mark was scheduled.
    @Test func thePolicyInForceAtSubmitTimeDecides() async throws {
        let (engine, _) = try await harness()
        engine.readReceipts.set(.publish)
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .global, at: at, by: "t")
        engine.readReceipts.set(.resolve(settings))
        #expect(await !(engine.submit(mark(open))))
    }

    /// Ghost mode is unchanged: still refuses marks and typing regardless of the gate.
    @Test func ghostModeStillRefusesUnderAPublishingGate() async throws {
        let (engine, _) = try await harness()
        await engine.setGhostMode(true)
        #expect(await !(engine.submit(mark(open))))
    }

    /// Review Focus 4. A refused mark still means the messages it covers
    /// were on screen here, so the banners for them are withdrawn locally -
    /// otherwise a receipts-off conversation fills Notification Center. A
    /// published mark announces nothing here: the server's read state does,
    /// later, through the reducer.
    @Test func aRefusedMarkAnnouncesALocalReadAndAPublishedOneDoesNot() async throws {
        let (engine, _) = try await harness()
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .conversation(quiet.id), at: at, by: "t")
        engine.readReceipts.set(.resolve(settings))

        #expect(await engine.submit(mark(open)))
        #expect(await !(engine.submit(mark(quiet))))
        #expect(await firstAnnouncement(of: engine) == .read(quiet.id, upTo: at))
    }

    /// The first announcement, or `nil` after a second - so a missing one
    /// fails rather than hangs. Cancelling the loser finishes the engine's
    /// stream for good (`CLAUDE.md`, §25.10's rule), which is harmless for an
    /// engine this test throws away.
    private func firstAnnouncement(of engine: SyncEngine) async -> SyncAnnouncement? {
        await withTaskGroup(of: SyncAnnouncement?.self) { group in
            group.addTask { await engine.announcements.first { _ in true } }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return nil
            }
            // Not actually redundant: `group.next()` is `SyncAnnouncement??`
            // (the group's own optional wrapping the task's own optional
            // result), and `?? nil` is what flattens the two - the rule's
            // syntax match cannot tell that apart from a literal no-op.
            // swiftlint:disable:next redundant_nil_coalescing
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
