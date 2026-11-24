import ChatKit
import DesignSystem
import Testing
@testable import AppCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ComposerDraftSynchronizationTests {
    let room = ComposerDraftAddress(conversation: .init("room"))
    var thread: ComposerDraftAddress {
        ComposerDraftAddress(
            conversation: room.conversation,
            thread: .init("one")
        )
    }

    @Test func delayedReadPreservesLocalTextAndOffersTheSavedVersion() async throws {
        let provider = DraftSyncFixture()
        provider.holdReads = true
        provider.drafts[room] = provider.draft("From web", at: room)
        let sync = provider.makeSync()
        sync.opened(room, local: nil)
        try await waitUntil { provider.held != nil }
        let local = ComposedMessage(text: "Typed while waiting")
        sync.observed(local, at: room)
        provider.releaseRead()
        try await waitUntil { sync.statuses[room]?.conflict == true }
        #expect(provider.writes.isEmpty)
        #expect(sync.statuses[room]?.replacement == nil)

        sync.useSaved(at: room)
        let offer = try #require(sync.statuses[room]?.replacement)
        #expect(offer.expected == local && offer.body?.text == "From web")
        let newer = ComposedMessage(text: "Typed again before applying")
        sync.resolved(offer.id, at: room, local: newer, applied: false)
        #expect(sync.statuses[room]?.conflict == true)
        sync.keepLocal(at: room)
        try await waitUntil { provider.drafts[room]?.body == newer }
        #expect(provider.writes.map(\.0.body) == [newer])
        #expect(provider.writes.first?.0.previous?.body.text == "From web")
        await sync.stop()
    }

    @Test func restoresAndWritesOnlyTheExactConversationOrThreadComposer() async throws {
        let provider = DraftSyncFixture()
        provider.drafts[room] = provider.draft("Conversation draft", at: room)
        provider.drafts[thread] = provider.draft("Thread draft", at: thread)
        let sync = provider.makeSync()
        sync.opened(room, local: nil)
        sync.opened(thread, local: nil)
        try await waitUntil {
            sync.statuses[room]?.replacement != nil && sync.statuses[thread]?.replacement != nil
        }
        let main = try #require(sync.statuses[room]?.replacement)
        let reply = try #require(sync.statuses[thread]?.replacement)
        #expect(main.body?.text == "Conversation draft" && reply.body?.text == "Thread draft")
        sync.resolved(main.id, at: room, local: main.body, applied: true)
        sync.resolved(reply.id, at: thread, local: reply.body, applied: true)
        sync.observed(nil, at: thread)
        try await waitUntil { provider.drafts[thread] == nil }
        #expect(provider.drafts[room]?.body == main.body)
        #expect(provider.writes.map(\.0.address) == [thread])
        #expect(provider.writes.first?.0.previous?.body == reply.body)
        await sync.stop()
    }

    @Test func offlineCompositionSyncsAfterTheComposerReopens() async throws {
        let provider = DraftSyncFixture()
        provider.connected = false
        let sync = provider.makeSync()
        sync.opened(room, local: nil)
        sync.observed(ComposedMessage(text: "Early text"), at: room)
        let offline = ComposedMessage(text: "Last offline edit")
        sync.observed(offline, at: room)
        #expect(provider.reads.isEmpty && provider.writes.isEmpty)
        provider.connected = true
        sync.opened(room, local: offline)
        try await waitUntil { provider.drafts[room]?.body == offline }
        #expect(provider.writes.map(\.0.body) == [offline])
        await sync.stop()
    }

    @Test func optimisticSendSuppressesItsOldDraftUntilTheProviderVersionChanges() async throws {
        let provider = DraftSyncFixture()
        provider.drafts[room] = provider.draft("Previously synced", at: room)
        let sync = provider.makeSync()
        sync.opened(room, local: nil)
        try await waitUntil { sync.statuses[room]?.replacement != nil }
        let offer = try #require(sync.statuses[room]?.replacement)
        sync.resolved(offer.id, at: room, local: offer.body, applied: true)
        sync.submitted(offer.body, at: room)
        sync.observed(nil, at: room)
        sync.opened(room, local: nil)
        try await waitUntil { provider.reads.count == 2 }
        #expect(sync.statuses[room]?.replacement == nil && provider.writes.isEmpty)

        provider.drafts[room] = provider.draft("Another device wrote this", at: room)
        sync.opened(room, local: nil)
        try await waitUntil { sync.statuses[room]?.replacement?.body?.text == "Another device wrote this" }
        #expect(provider.writes.isEmpty)
        await sync.stop()
    }

    @Test func retryReusesTheOperationIdentityOfAnUnconfirmedWrite() async throws {
        let provider = DraftSyncFixture()
        provider.failWrite = true
        let sync = provider.makeSync()
        let body = ComposedMessage(text: "Keep this text")
        sync.opened(room, local: body)
        try await waitUntil { sync.statuses[room]?.failed == true }
        provider.failWrite = false
        sync.opened(room, local: body)
        try await waitUntil { provider.drafts[room]?.body == body }
        let operations = provider.writes.map(\.1)
        #expect(operations.count == 2 && Set(operations).count == 1)
        await sync.stop()
    }

    @Test func convertedDraftDoesNotOverwriteTextTypedWhileScheduling() async throws {
        let provider = DraftSyncFixture()
        let original = provider.draft("Previously synced", at: thread)
        provider.drafts[thread] = original
        let sync = provider.makeSync()
        sync.opened(thread, local: original.body)
        #expect(try await sync.prepareSchedule(original.body, at: thread) == original)
        let later = ComposedMessage(text: "Next draft")
        sync.observed(later, at: thread)
        #expect(provider.writes.isEmpty)

        provider.drafts[thread] = nil
        sync.finishSchedule(original, at: thread)
        try await waitUntil { provider.drafts[thread]?.body == later }
        #expect(provider.writes.map(\.0.body) == [later])
        #expect(provider.writes.first?.0.previous == nil)
        await sync.stop()
    }

    @Test func anAcceptedSendRetiresTheExactSavedVersionAndKeepsNewTyping() async throws {
        let provider = DraftSyncFixture()
        let original = provider.draft("Previously synced", at: room)
        provider.drafts[room] = original
        let sync = provider.makeSync()
        sync.opened(room, local: nil)
        try await waitUntil { sync.statuses[room]?.replacement != nil }
        let offer = try #require(sync.statuses[room]?.replacement)
        sync.resolved(offer.id, at: room, local: offer.body, applied: true)
        #expect(sync.beginSend(original.body, at: room) == original)
        let next = ComposedMessage(text: "Next composition")

        provider.drafts[room] = nil
        sync.observed(next, at: room)
        sync.finishSend(original, at: room)
        try await waitUntil { provider.drafts[room]?.body == next }
        #expect(provider.writes.map(\.0.body) == [next])
        #expect(provider.writes.first?.0.previous == nil)
        await sync.stop()
    }

    @Test func sendingLocalTextKeepsACompetingSavedDraftAvailable() async throws {
        let provider = DraftSyncFixture()
        let other = provider.draft("Remote composition", at: room)
        provider.drafts[room] = other
        let local = ComposedMessage(text: "Local composition")
        let sync = provider.makeSync()
        sync.opened(room, local: local)
        try await waitUntil { sync.statuses[room]?.conflict == true }

        #expect(sync.beginSend(local, at: room) == nil)
        sync.finishSend(nil, at: room)
        try await waitUntil { sync.statuses[room]?.replacement?.body == other.body }
        #expect(provider.writes.isEmpty)
        await sync.stop()
    }

    @Test func clusteredInvalidationsDuringAReadDiscardTheOldResponse() async throws {
        let provider = DraftSyncFixture()
        provider.holdReads = true
        provider.drafts[thread] = provider.draft("Previous version", at: thread)
        let sync = provider.makeSync()
        sync.opened(thread, local: nil)
        try await waitUntil { provider.held != nil }
        provider.drafts[thread] = provider.draft("Updated on another device", at: thread)
        sync.invalidated(thread, local: nil)
        sync.invalidated(thread, local: nil)
        provider.releaseRead()

        try await waitUntil { sync.statuses[thread]?.replacement != nil }
        #expect(sync.statuses[thread]?.replacement?.body?.text == "Updated on another device")
        #expect(provider.reads == [thread, thread] && provider.writes.isEmpty)
        await sync.stop()
    }

    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0 ..< 200 where !ready() {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(ready())
    }
}

@MainActor
private final class DraftSyncFixture {
    var connected = true
    var holdReads = false
    var held: CheckedContinuation<Void, Never>?
    var failWrite = false
    var drafts: [ComposerDraftAddress: SyncedDraft] = [:]
    var reads: [ComposerDraftAddress] = []
    var writes: [(SyncedDraftChange, String)] = []

    func draft(_ text: String, at address: ComposerDraftAddress) -> SyncedDraft {
        SyncedDraft(
            id: .init(address: address, record: "draft"), body: ComposedMessage(text: text), changeToken: text
        )
    }

    func makeSync() -> ComposerDraftSynchronization {
        ComposerDraftSynchronization(
            connected: { [self] in connected }, writable: true, debounce: .zero,
            fetch: { [self] address in
                reads.append(address)
                let snapshot = drafts[address]
                if holdReads {
                    await withCheckedContinuation { held = $0 }
                }
                return snapshot
            },
            save: { [self] change, id in
                writes.append((change, id))
                if failWrite {
                    throw ChatError.transport("fixture failure")
                }
                let updated = change.body.map { draft($0.text, at: change.address) }
                drafts[change.address] = updated
                return SyncedDraftWriteResult(applied: true, current: updated)
            }
        )
    }

    func releaseRead() {
        holdReads = false
        held?.resume()
        held = nil
    }
}
