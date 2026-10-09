import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// Viewing a thread marks it read (threads spec §4.3), with no wait
/// (`markReadDebounce: .zero`); the sequences with a real wait are in
/// `ThreadAutoMarkReadSequenceTests`. Every verdict is the whole list of
/// thread commands, never a count read the instant the first one lands.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ThreadAutoMarkReadTests {
    private let messages = ThreadFixture.messages(replies: 2)

    private var newest: Date {
        ThreadFixture.newest(replies: 2)
    }

    /// What the backend's answer to a Mark as Unread files.
    private var markedUnread: StoreWrite {
        .applyThreadChange(
            thread: ThreadFixture.thread, conversation: ThreadFixture.conversation,
            change: .markedUnread(at: messages[1].createdAt)
        )
    }

    private func sent(_ backend: RecordingBackend, count: Int) async {
        await settleAutoMarkRead(until: "\(count) thread commands are sent") {
            await threadCommands(from: backend).count == count
        }
    }

    @Test func openingAThreadMarksItReadUpToItsNewestReply() async throws {
        let harness = try await makeThreadHarness()
        try openStoredThread(messages, in: harness)
        await sent(harness.backend, count: 1)
        #expect(await threadCommands(from: harness.backend) == [ThreadFixture.read(upTo: newest)])
        await harness.model.stop()
    }

    @Test func aThreadMarkedUnreadIsClearedFirst() async throws {
        let harness = try await makeThreadHarness()
        try openStoredThread(messages, with: [markedUnread], in: harness)
        await sent(harness.backend, count: 2)
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.unreadMark(at: nil), ThreadFixture.read(upTo: newest)
        ])
        await harness.model.stop()
    }

    @Test func aRefusedClearSendsNoRead() async throws {
        let harness = try await makeThreadHarness()
        await harness.backend.failSubmissions(true)
        try openStoredThread(messages, with: [markedUnread], in: harness)
        await sent(harness.backend, count: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend) == [ThreadFixture.unreadMark(at: nil)])
        await harness.model.stop()
    }

    /// "Reply in Thread" on a plain message opens a panel with nothing to mark.
    @Test func aThreadWithNoRepliesIsNotMarkedUntilOneArrives() async throws {
        let harness = try await makeThreadHarness()
        let thread = ThreadFixture.messages(replies: 1)
        try openStoredThread([thread[0]], in: harness)
        await settleAutoMarkRead(until: "the first message reaches the panel") {
            harness.model.threads.messages.count == 1
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend).isEmpty)
        try harness.store.apply([.upsertMessage(thread[1])])
        await sent(harness.backend, count: 1)
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.read(upTo: thread[1].createdAt)
        ])
        await harness.model.stop()
    }

    /// The watermark: send-side dedupe, `published`'s rule.
    @Test func aRedeliveryMarksNothingAndANewerReplyMarksAgain() async throws {
        let harness = try await makeThreadHarness()
        try openStoredThread(messages, in: harness)
        await sent(harness.backend, count: 1)
        try harness.store.apply([.upsertMessage(messages[2])])
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend).count == 1)
        let newer = ThreadFixture.messages(replies: 3)[3]
        try harness.store.apply([.upsertMessage(newer)])
        await sent(harness.backend, count: 2)
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.read(upTo: newest), ThreadFixture.read(upTo: newer.createdAt)
        ])
        await harness.model.stop()
    }

    /// The watermark advances only on success.
    @Test func aRefusedMarkIsTriedAgainByTheNextTrigger() async throws {
        let harness = try await makeThreadHarness()
        await harness.backend.failSubmissions(true)
        try openStoredThread(messages, in: harness)
        await sent(harness.backend, count: 1)
        await harness.backend.failSubmissions(false)
        harness.model.setActive(false)
        harness.model.setActive(true)
        await sent(harness.backend, count: 2)
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.read(upTo: newest), ThreadFixture.read(upTo: newest)
        ])
        await harness.model.stop()
    }

    /// An optimistic reply carries `Date()`, not a server position.
    @Test func aReplyStillSendingIsNeverAReadPosition() async throws {
        let harness = try await makeThreadHarness()
        let model = harness.model
        try openStoredThread(messages, in: harness)
        await sent(harness.backend, count: 1)
        await settleAutoMarkRead(until: "you are known") { model.me != nil }
        model.sendReply(ComposedMessage(text: "not yet echoed"))
        await settleAutoMarkRead(until: "the reply reaches the panel") {
            model.threads.messages.contains { $0.text == "not yet echoed" }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend) == [ThreadFixture.read(upTo: newest)])
        await model.stop()
    }
}
