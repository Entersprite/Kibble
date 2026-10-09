import ChatKit
import FixtureBackend
import Foundation
import Testing
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MentionSendTests {
    private static let other = Mention(target: .user(Member.ID("fixture-other")), start: 0, length: 6)

    private static func model(_ backend: RecordingBackend) async throws -> ChatSessionModel {
        let store = try ChatStore.inMemory()
        let engine = SyncEngine(backend: backend, store: store)
        let model = ChatSessionModel(
            store: store,
            engine: engine,
            me: FixtureWorld.minimal.me,
            markReadDebounce: .zero
        )
        try await model.start()
        await settleAutoMarkRead()
        model.select(Conversation.ID("space:1"))
        await settleAutoMarkRead()
        return model
    }

    private static let message = ComposedMessage(text: "@Other hi", mentions: [other])

    private static func sentMentions(_ backend: RecordingBackend) async -> [[Mention]] {
        await backend.commands.compactMap { command in
            if case let .sendMessage(_, _, _, _, _, mentions) = command {
                mentions
            } else {
                nil
            }
        }
    }

    /// Settles on the fixture's echo, which only exists once the command went out.
    @Test func theCommandCarriesTheMentions() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        model.send(Self.message)
        await settleAutoMarkRead(until: "the echo arrives") {
            model.messages.contains { $0.text == "@Other hi" && !$0.id.rawValue.hasPrefix("local/") }
        }
        #expect(await Self.sentMentions(backend) == [[Self.other]])
        await model.stop()
    }

    @Test func theOptimisticRowCarriesTheMentions() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        await backend.holdSubmissions(true)
        model.send(Self.message)
        await settleAutoMarkRead(until: "the optimistic row is shown") {
            model.messages.contains { $0.id.rawValue.hasPrefix("local/") }
        }
        let row = try #require(model.messages.first { $0.id.rawValue.hasPrefix("local/") })
        #expect(row.mentions == [Self.other])
        await backend.releaseHeldSubmission()
        await model.stop()
    }

    @Test func aRefusedSendHandsBackItsMentions() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        await backend.failSubmissions(true)
        model.send(Self.message)
        await settleAutoMarkRead(until: "the draft comes back") { model.failedDraft != nil }
        #expect(model.failedDraft == Self.message)
        await model.stop()
    }

    @Test func aStagedFileCarriesTheCaptionsMentions() async throws {
        let backend = RecordingBackend()
        let model = try await Self.model(backend)
        model.stage([OutgoingAttachment(
            id: "a", file: URL(fileURLWithPath: "/nonexistent/a.png"), name: "a.png",
            contentType: "image/png", byteSize: 100, width: 40, height: 30
        )], in: .conversation)
        model.send(Self.message)
        await settleAutoMarkRead(until: "the staged file has gone") { model.stagedAttachments.isEmpty }
        #expect(await Self.sentMentions(backend) == [[Self.other]])
        await model.stop()
    }
}
