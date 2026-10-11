import ChatKit
import Foundation

/// `RecordingBackend`'s thread calls (threads spec §4.3). Split from the main
/// file to keep it under swiftlint's `file_length` once message search joined
/// it; the stored properties stay in `RecordingBackend.swift`, an actor's
/// extension cannot add them.
extension RecordingBackend {
    func answerThread(_ thread: MessageThread.ID, with page: [Message]) {
        threadPages[thread] = page
    }

    func answerFollowedThreads(with messages: [Message]) {
        followedAnswer = messages
    }

    /// Makes every later thread request record itself and then throw.
    func failThreadCalls(_ fail: Bool) {
        failingThreadCalls = fail
    }

    /// Makes every later thread request record itself, then wait for
    /// `releaseHeldThreadCall()`: a request asked and not yet answered.
    func holdThreadCalls(_ hold: Bool) {
        holdingThreadCalls = hold
    }

    var heldThreadCallCount: Int {
        heldThreadCalls.count
    }

    /// Releases the oldest held thread request, if any.
    func releaseHeldThreadCall() {
        guard !heldThreadCalls.isEmpty else { return }
        heldThreadCalls.removeFirst().resume()
    }

    func loadThread(_ thread: MessageThread.ID, in _: Conversation.ID) async throws -> [Message] {
        threadLoads.append(thread)
        try await threadCallGate()
        return threadPages[thread] ?? []
    }

    func setThreadFollowed(_ followed: Bool, thread _: MessageThread.ID, in _: Conversation.ID) async throws {
        followRequests.append(followed)
        try await threadCallGate()
    }

    func loadFollowedThreads() async throws -> [Message] {
        followedThreadLoads += 1
        try await threadCallGate()
        return followedAnswer
    }

    /// Recording happens before this, in the same actor turn, so a test that
    /// saw the call recorded knows it has already passed the hold check.
    func threadCallGate() async throws {
        if holdingThreadCalls {
            await withCheckedContinuation { heldThreadCalls.append($0) }
        }
        if failingThreadCalls {
            throw ChatError.server(status: 500, message: "the thread call failed")
        }
    }
}
