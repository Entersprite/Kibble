import ChatKit
import FixtureBackend
import Foundation
import GRDB
import Testing
@testable import SyncEngine

@Suite(.timeLimit(.minutes(1)))
struct MeetingTranscriptTests {
    let world = FixtureWorld.recurringMeetings
    let first = Conversation.ID("planning-first")
    let latest = Conversation.ID("planning-latest")

    @Test func scheduleOrderKeepsLateMessagesInTheirOriginalMeetingAndPersistsMetadata() async throws {
        let store = try ChatStore.inMemory()
        try store
            .apply(world.conversations.map { .upsertConversation($0) } + world.messages
                .map { .upsertMessage($0) })
        let rows = try store.conversations()
        #expect(rows.first { $0.id == first }?.meeting == world.conversations[0].meeting)
        let transcript = try await store.meetingTranscript(
            occurrences: [first, latest],
            request: .latest(100)
        )
        #expect(transcript.messages.map(\.conversationID) == [
            first,
            first,
            first,
            first,
            latest,
            latest,
            latest
        ])
        #expect(transcript.messages[3].id == Message.ID("late-old-message"))
        #expect(!transcript.hasOlder && !transcript.hasNewer)
        #expect(!transcript.messages.contains { $0.conversationID == Conversation.ID("other-planning") })
        let target = try await store.meetingTranscript(
            occurrences: [first, latest], request: .around(.init("late-old-message"), 4)
        )
        #expect(target.messages.map(\.id) == [
            .init("planning-first-1"),
            .init("planning-first-2"),
            .init("late-old-message"),
            .init("planning-latest-0")
        ])
        #expect(target.hasOlder && target.hasNewer)
    }

    @Test func largeSeriesWindowNeverDecodesUnrequestedHistory() async throws {
        let store = try ChatStore.inMemory()
        let messages = (0 ..< 20000).map { number in
            Message(
                id: .init(String(format: "m-%05d", number)), conversationID: number < 10000 ? first : latest,
                threadID: .init("t-\(number)"), sender: world.me, text: "Message \(number)",
                createdAt: Date(timeIntervalSince1970: Double(number))
            )
        }
        try store.apply(messages.map { .upsertMessage($0) })
        try await store.database.write { db in
            try db.execute(sql: "UPDATE message SET reactions = 'invalid' WHERE createdAt < 19500")
        }
        let queryStarted = ContinuousClock.now
        let window = try await store.meetingTranscript(occurrences: [first, latest], request: .latest(10000))
        if ProcessInfo.processInfo.environment["KIBBLE_MEETING_BENCHMARK"] == "1" {
            print(
                "Meeting query: 20,000 stored rows, 500 decoded rows, \(ContinuousClock.now - queryStarted)"
            )
        }
        #expect(window.messages.count == 500)
        #expect(window.messages.first?.id == Message.ID("m-19500"))
        #expect(window.hasOlder && !window.hasNewer)
        let empty = try await store.meetingTranscript(occurrences: [], request: .latest(100))
        #expect(empty.messages.isEmpty)
    }

    @MainActor
    @Test func olderMeetingOpensInSeriesButSendingAlwaysUsesLatest() async throws {
        let (model, backend) = try await model()
        model.select(first)
        try await wait { model.messages.contains { $0.conversationID == first } }
        #expect(model.selected == latest)
        #expect(model.selectedMeetingSeries == MeetingSeries.ID("title:Planning"))
        #expect(model.newerMessagesAreLatestJump)
        model.send(ComposedMessage(text: "For today’s meeting"))
        for _ in 0 ..< 10000 {
            if await backend.commands.contains(where: {
                if case let .sendMessage(id, _, _, _, _, _) = $0 {
                    return id == latest
                }
                return false
            }) {
                break
            }
            await Task.yield()
        }
        #expect(await backend.commands.contains {
            if case let .sendMessage(id, _, _, _, _, _) = $0 {
                return id == latest
            }
            return false
        })
        try await wait { model.messages.contains { $0.id == Message.ID("planning-latest-2") } }
        #expect(model.transcriptIncludesLatest)
        await model.stop()
    }

    @MainActor
    @Test func olderPagingCrossesOccurrenceBoundaryAndReadMarksOnlyVisibleOriginalChats() async throws {
        let (model, backend) = try await model()
        model.selectMeetingSeries(.init("title:Planning"))
        try await wait { model.messages.count == 3 }
        #expect(model.markTasks.isEmpty)
        model.loadOlderMessages()
        try await wait { model.messages.count == 7 && !model.isLoadingOlderMessages }
        #expect(model.messages[3].id == Message.ID("late-old-message"))
        model.visibleMeetingMessages([.init("planning-first-1")])
        for _ in 0 ..< 10000 {
            if await backend.commands
                .contains(where: {
                    if case .markRead = $0 {
                        return true
                    }; return false
                }) {
                break
            }
            await Task.yield()
        }
        let marks = await backend.commands.compactMap { command -> Conversation.ID? in
            if case let .markRead(id, _) = command {
                return id
            }; return nil
        }
        #expect(marks == [first])
        model.selectMeetingSeries(.init("title:Other Planning"))
        try await wait { model.messages.first?.conversationID == Conversation.ID("other-planning") }
        #expect(model.meetingWork.visible.isEmpty)
        await model.stop()
    }

    @MainActor
    @Test func newOccurrenceMovesSendDestinationAndOldMessageActionsKeepTheirAddress() async throws {
        let (model, backend) = try await model()
        model.selectMeetingSeries(.init("title:Planning"))
        try await wait { model.messages.count == 3 }
        var next = world.conversations[1]
        next.id = .init("planning-next")
        next.meeting?.occurrenceID = "next"
        next.meeting?.scheduledStart = world.startedAt.addingTimeInterval(172_800)
        model.conversationsObserved(world.conversations + [next])
        #expect(model.selected == next.id)
        #expect(model.selectedMeetingSeries == MeetingSeries.ID("title:Planning"))
        model.delete(.init("late-old-message"))
        for _ in 0 ..< 10000 {
            if await backend.commands.contains(where: {
                if case let .deleteMessage(_, id, _) = $0 {
                    return id == first
                }; return false
            }) {
                break
            }
            await Task.yield()
        }
        #expect(await backend.commands.contains {
            if case let .deleteMessage(_, id, _) = $0 {
                return id == first
            }; return false
        })
        await model.stop()
        #expect(model.selectedMeetingSeries == nil)
        #expect(model.meetingWork.included.isEmpty)
    }

    @MainActor
    @Test func renamedSelectionFollowsItsOriginalChatAndRetainsProviderHistory() async throws {
        let (model, _) = try await model()
        model.select(latest)
        try await wait { model.messages.count == 3 }
        var renamed = world.conversations
        let parent = try #require(renamed[1].meeting?.seriesID)
        renamed[0].meeting?.seriesID = parent
        renamed[1].meeting?.seriesTitle = "Renamed planning"
        model.conversationsObserved(renamed)
        #expect(model.selected == latest)
        #expect(model.selectedMeetingSeries == .init("title:Renamed planning"))
        #expect(model.meetingSeries?.occurrences.map(\.id) == [first, latest])
        await model.stop()
    }

    @MainActor
    @Test func hiddenOccurrenceStopsAppearingAndCanceledReadCannotReachTheBackend() async throws {
        let (model, backend) = try await model(debounce: .seconds(10))
        model.select(first)
        try await wait { model.messages.count == 4 }
        model.visibleMeetingMessages([.init("planning-first-1")])
        #expect(model.markTasks[first] != nil)
        model.conversationsObserved(world.conversations.filter { $0.id != first })
        try await wait { model.messages.allSatisfy { $0.conversationID != first } }
        await model.stop()
        #expect(await backend.markReadCount == 0)
    }

    @MainActor
    @Test func meetingVisibilityStillUsesSubmissionTimeReceiptPrivacyAndDoesNotLoopOnRefusal() async throws {
        let (model, backend) = try await model()
        model.engine.readReceipts.set(.withhold)
        model.selectMeetingSeries(.init("title:Planning"))
        try await wait { model.messages.count == 3 }
        model.visibleMeetingMessages([.init("planning-latest-2")])
        try await wait { model.markTasks.isEmpty }
        #expect(await backend.markReadCount == 0)
        #expect(model.published[latest] == nil)
        model.engine.readReceipts.set(.publish)
        model.visibleMeetingMessages([.init("planning-latest-2")])
        try await wait { model.published[latest] != nil && model.markTasks.isEmpty }
        #expect(await backend.markReadCount == 1)
        await model.stop()
    }

    @MainActor
    @Test func emptyPageDoesNotJoinUnverifiedOldSearchContextWhenCrossingMeetings() async throws {
        let store = try ChatStore.inMemory()
        let messages = (0 ..< 1100).filter { $0 < 30 || $0 >= 1000 }.map { number in
            Message(
                id: .init("gap-\(number)"), conversationID: latest, threadID: .init("gap-topic-\(number)"),
                sender: world.me, text: "Message \(number)",
                createdAt: Date(timeIntervalSince1970: Double(number))
            )
        }
        try store
            .apply(world.conversations.map { .upsertConversation($0) } + messages.map { .upsertMessage($0) })
        let backend = RecordingBackend(world: world)
        await backend.answerHistory(in: latest, with: Array(messages.suffix(100)))
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        model.conversations = world.conversations
        model.selectMeetingSeries(.init("title:Planning"))
        try await wait { model.messages.count == 100 }
        await backend.answerHistory(in: latest, with: [])
        model.loadOlderMessages()
        try await wait { !model.isLoadingOlderMessages }
        #expect(model.messages.count == 100)
        #expect(model.meetingWork.included == [latest])
        #expect(!model.meetingWork.exhausted.contains(latest))
        #expect(model.hasOlderMessages)
        await model.stop()
    }

    @MainActor
    private func model() async throws -> (ChatSessionModel, RecordingBackend) {
        try await model(debounce: .zero)
    }

    @MainActor
    private func model(debounce: Duration) async throws -> (ChatSessionModel, RecordingBackend) {
        let store = try ChatStore.inMemory()
        try store
            .apply(world.conversations.map { .upsertConversation($0) } + world.messages
                .map { .upsertMessage($0) })
        let backend = RecordingBackend(world: world)
        let model = ChatSessionModel(
            store: store, engine: SyncEngine(backend: backend, store: store), markReadDebounce: debounce
        )
        try await model.start()
        try await wait { model.conversations.count == world.conversations.count && model.me == world.me }
        return (model, backend)
    }

    @MainActor
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 10000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        try #require(condition())
    }
}
