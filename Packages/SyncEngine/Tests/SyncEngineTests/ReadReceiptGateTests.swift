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
    /// are read here, so the banners for them are withdrawn locally -
    /// otherwise a receipts-off conversation fills Notification Center. A
    /// published mark announces nothing here: the server's read state does,
    /// later, through the reducer.
    ///
    /// The announced position is one microsecond past the mark's, which is
    /// its newest message's own time - the wire's step, and what a strict
    /// `createdAt < upTo` withdraw needed (`findings.md` §36; the withdraw
    /// covers equality since §42.2). `MarkReadNowTests` checks that against a
    /// stored message; this pins the exact value.
    @Test func aRefusedMarkAnnouncesALocalReadAndAPublishedOneDoesNot() async throws {
        let (engine, _) = try await harness()
        var settings = NotificationSettings()
        settings.setRule(NotificationRule(readReceipts: false), for: .conversation(quiet.id), at: at, by: "t")
        engine.readReceipts.set(.resolve(settings))
        let pastTheMark = Date(timeIntervalSince1970: 1_790_000_000.000_001)

        #expect(await engine.submit(mark(open)))
        #expect(await !(engine.submit(mark(quiet))))
        #expect(await firstAnnouncement(of: engine) == .read(quiet.id, upTo: pastTheMark))
    }
}
