import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

/// A panel the window does not draw (session 58): the model has a thread
/// open, but its conversation offers no replies yet. A notification's click
/// on a reply does that before the first world load after the v13 upgrade.
/// Nothing is marked read until the window can show the thread.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ThreadPanelGateTests {
    private let messages = ThreadFixture.messages(replies: 2)

    /// Opens the stored thread in a conversation without replies, and waits
    /// until the panel holds its messages: the positive control, so only the
    /// gate can keep a mark out.
    private func openHidden() async throws -> AutoMarkReadHarness {
        let harness = try await makeThreadHarness(repliesEnabled: false)
        try openStoredThread(messages, in: harness)
        await settleAutoMarkRead(until: "the panel holds the thread") {
            harness.model.threads.messages.count == messages.count
        }
        #expect(harness.model.threads.openThread == ThreadFixture.thread)
        return harness
    }

    @Test func aPanelTheWindowDoesNotDrawIsNotShown() async throws {
        let harness = try await openHidden()
        #expect(!harness.model.isThreadPanelShown)
        try await enableReplies(in: harness)
        #expect(harness.model.isThreadPanelShown)
        harness.model.closeThread()
        #expect(!harness.model.isThreadPanelShown)
        await harness.model.stop()
    }

    @Test func aPanelTheWindowDoesNotDrawMarksNothing() async throws {
        let harness = try await openHidden()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await threadCommands(from: harness.backend).isEmpty)
        await harness.model.stop()
    }

    /// The first world load after the upgrade turns replies on: the window
    /// draws the panel, and the thread it shows is marked read then.
    @Test func theGateOpeningMarksTheThreadThePanelShows() async throws {
        let harness = try await openHidden()
        try await enableReplies(in: harness)
        await settleAutoMarkRead(until: "the read is sent") {
            await threadCommands(from: harness.backend).count == 1
        }
        #expect(await threadCommands(from: harness.backend) == [
            ThreadFixture.read(upTo: ThreadFixture.newest(replies: 2))
        ])
        await harness.model.stop()
    }
}
