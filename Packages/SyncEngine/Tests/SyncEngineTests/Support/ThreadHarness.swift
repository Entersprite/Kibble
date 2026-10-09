import ChatKit
import FixtureBackend
import Foundation
@testable import SyncEngine

/// One thread in the minimal world's DM, for the thread suites (threads spec §4.3).
///
/// Written into the store by each test, never taken from the fixture: the
/// fixture's threads are FixtureBackend's subject, and these suites must say
/// exactly which messages a thread holds. An hour after the fixture's own
/// messages, so nothing in the world is newer.
enum ThreadFixture {
    static let conversation = autoMarkReadConversation
    static let thread = MessageThread.ID("thread:test")
    static let otherThread = MessageThread.ID("thread:other")

    static var start: Date {
        FixtureWorld.minimal.startedAt.addingTimeInterval(3600)
    }

    /// A thread's first message, then `replies` replies a minute apart, all
    /// from the other person. Ids are `<thread>|<index>`; the first message's is 0.
    static func messages(
        in thread: MessageThread.ID = ThreadFixture.thread, replies: Int, offset: TimeInterval = 0
    ) -> [Message] {
        (0 ... replies).map { index in
            Message(
                id: Message.ID("\(thread.rawValue)|\(index)"),
                conversationID: conversation,
                threadID: thread,
                sender: Member.ID("fixture-other"),
                text: index == 0 ? "the first message" : "reply \(index)",
                createdAt: start.addingTimeInterval(offset + Double(index) * 60),
                isReply: index > 0
            )
        }
    }

    /// The newest reply's time in `messages(in:replies:offset:)`.
    static func newest(replies: Int, offset: TimeInterval = 0) -> Date {
        start.addingTimeInterval(offset + Double(replies) * 60)
    }

    static func read(_ thread: MessageThread.ID = ThreadFixture.thread, upTo position: Date) -> ChatCommand {
        .markThreadRead(conversationID: conversation, threadID: thread, upTo: position)
    }

    static func unreadMark(
        _ thread: MessageThread.ID = ThreadFixture.thread, at position: Date?
    ) -> ChatCommand {
        .setThreadUnreadMark(conversationID: conversation, threadID: thread, at: position)
    }

    /// `.fixture` without `canMarkRead`: the conversation's own marks stay out
    /// of `commands` and out of a held submission's slot, so what a thread
    /// suite counts is what the panel sent.
    static var capabilities: Capabilities {
        var capabilities = Capabilities.fixture
        capabilities.canMarkRead = false
        return capabilities
    }
}

/// `makeAutoMarkReadHarness` with every command accepted without reaching
/// the fixture: what FakeBackend does with a thread command is
/// FixtureBackend's subject, so here a refusal can only be the model's or
/// the engine's.
@MainActor
func makeThreadHarness(
    capabilities: Capabilities = ThreadFixture.capabilities, markReadDebounce: Duration = .zero
) async throws -> AutoMarkReadHarness {
    let harness = try await makeAutoMarkReadHarness(
        capabilities: capabilities, markReadDebounce: markReadDebounce
    )
    await harness.backend.acceptWithoutForwarding(true)
    return harness
}

/// Every thread read and unread mark the session sent, in order.
func threadCommands(from backend: RecordingBackend) async -> [ChatCommand] {
    await backend.commands.filter { command in
        switch command {
        case .markThreadRead, .setThreadUnreadMark: true
        default: false
        }
    }
}
