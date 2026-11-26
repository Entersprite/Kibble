import ChatKit
import FixtureBackend
import Testing
@testable import ChatPersistence
@testable import SyncEngine

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConversationSectionRefreshTests {
    @Test func aDeletionSurvivesADroppedRefreshNotification() async throws {
        var capabilities = Capabilities.fixture
        capabilities.extendedFlags.insert("conversationSections")
        let backend = RecordingBackend(capabilities: capabilities)
        let engine = try SyncEngine(backend: backend, store: ChatStore.inMemory())
        await engine
            .publishMessageCollectionChange(for: .conversationSectionsChanged(removedSectionID: "removed"))
        for _ in 0 ..< 40 {
            await engine.publishMessageCollectionChange(for: .conversationSectionsChanged())
        }
        engine.messageCollectionChangeSink.finish()
        var sawBroadRefresh = false
        for await change in engine.messageCollectionChanges {
            if case .refreshAll = change {
                sawBroadRefresh = true
            }
        }
        #expect(sawBroadRefresh)
        #expect(await engine.takeConversationSectionRemovals() == ["removed"])
        #expect(await engine.takeConversationSectionRemovals().isEmpty)
    }

    @Test func aDeletionFencesAHeldResponseAndQueuesOneFreshRead() async throws {
        var capabilities = Capabilities.fixture
        capabilities.extendedFlags.insert("conversationSections")
        let backend = RecordingBackend(capabilities: capabilities)
        let initial = ConversationSection(id: "old", name: "Old", conversationIDs: [])
        let replacement = ConversationSection(id: "fresh", name: "Fresh", conversationIDs: [])
        let reader = HeldSectionReads(initial)
        await backend.setConversationSectionReader { try await reader.read() }
        let store = try ChatStore.inMemory()
        let model = ChatSessionModel(store: store, engine: SyncEngine(backend: backend, store: store))
        try await model.start()
        try await waitFor { model.conversationSections == [initial] && model.conversationSectionTask == nil }
        let baseline = await reader.count

        await reader.setNext([initial], held: true)
        model.refreshConversationSections()
        try await waitFor { await reader.hold.count == 1 }
        try #require(await reader.count == baseline + 1)

        await reader.setNext([replacement], held: true)
        await backend.inner.applyConversationSections(nil, removedSectionID: initial.id)
        try await waitFor { model.conversationSectionReadInvalidated && model.conversationSections.isEmpty }
        #expect(await reader.count == baseline + 1)
        await reader.hold.release()
        try await waitFor {
            let count = await reader.count
            let held = await reader.hold.count
            return count == baseline + 2 && held == 1
        }
        #expect(model.conversationSections.isEmpty)

        await reader.hold.release()
        try await waitFor {
            model.conversationSections == [replacement] && model.conversationSectionTask == nil
        }
        await model.stop()
    }

    private func waitFor(_ ready: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while await !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await ready())
    }
}

private actor HeldSectionReads {
    let hold = AbortableHold()
    private var sections: [ConversationSection]
    private var holdingNext = false
    private(set) var count = 0

    init(_ initial: ConversationSection) {
        sections = [initial]
    }

    func setNext(_ sections: [ConversationSection], held: Bool) {
        self.sections = sections
        holdingNext = held
    }

    func read() async throws -> [ConversationSection] {
        let answer = sections
        count += 1
        if holdingNext {
            holdingNext = false
            try await hold.wait()
        }
        return answer
    }
}

extension RecordingBackend {
    fileprivate func setConversationSectionReader(_ read: @escaping @Sendable () async throws
        -> [ConversationSection]?) {
        conversationSectionReader = read
    }

    func conversationSections() async throws -> [ConversationSection]? {
        if let conversationSectionReader {
            return try await conversationSectionReader()
        }
        return try await inner.conversationSections()
    }
}
