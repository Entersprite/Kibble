import ChatKit
import FixtureBackend
import Foundation

/// The fixture, with the Conversation Info reads and writes held or failed on
/// demand. A held call ignores cancellation, as an answer already queued
/// before the panel moved on does.
actor HeldInfoBackend: ChatBackend {
    enum Hold: Sendable {
        case integrations, webhookURL, mutation, laterPages, participants
    }

    nonisolated let capabilities = Capabilities.fixture
    nonisolated let inner: FakeBackend
    nonisolated var events: AsyncStream<ChatEvent> {
        inner.events
    }

    private var holding: Set<Hold> = []
    private var waiters: [(Hold, CheckedContinuation<Void, Never>)] = []
    private var failNextPeople = false
    private var failNextDetail = false
    private var failingMutations = false
    private var failingLaterPages = false
    private var failingMutationNumber: Int?
    private(set) var mutationCount = 0
    /// Details reads the client asked for: one per panel reload.
    private(set) var detailsReads = 0

    var isHolding: Bool {
        !waiters.isEmpty
    }

    init(world: FixtureWorld = .minimal, pageSize: Int = 30) {
        inner = FakeBackend(world: world, pageSize: pageSize)
    }

    func hold(_ call: Hold) {
        holding.insert(call)
    }

    /// Answers every held call and stops holding.
    func release() {
        holding = []
        let held = waiters
        waiters = []
        held.forEach { $0.1.resume() }
    }

    func isHolding(_ call: Hold) -> Bool {
        waiters.contains { $0.0 == call }
    }

    func release(_ call: Hold) {
        holding.remove(call)
        let held = waiters.filter { $0.0 == call }
        waiters.removeAll { $0.0 == call }
        held.forEach { $0.1.resume() }
    }

    func failNextDetails() {
        failNextDetail = true
    }

    func failNextParticipants() {
        failNextPeople = true
    }

    func failMutations() {
        failingMutations = true
    }

    /// Fails only the `number`th mutation from now, counting from 1.
    func failMutation(number: Int) {
        failingMutationNumber = mutationCount + number
    }

    /// Fails every participant page after the first.
    func failLaterPages() {
        failingLaterPages = true
    }

    private func wait(for call: Hold) async {
        guard holding.contains(call) else { return }
        await withCheckedContinuation { waiters.append((call, $0)) }
    }

    func connect() async throws {
        try await inner.connect()
    }

    func disconnect() async {
        await inner.disconnect()
    }

    func send(_ command: ChatCommand) async throws {
        try await inner.send(command)
    }

    func loadConversations() async throws -> [Conversation] {
        try await inner.loadConversations()
    }

    func loadMessages(in id: Conversation.ID, before cursor: Message.ID?) async throws -> [Message] {
        try await inner.loadMessages(in: id, before: cursor)
    }

    func setNotificationSetting(_ level: NotificationLevel, for id: Conversation.ID) async throws {
        try await inner.setNotificationSetting(level, for: id)
    }

    func conversationDetails(_ id: Conversation.ID) async throws -> ConversationDetails {
        detailsReads += 1
        if failNextDetail {
            failNextDetail = false
            throw ChatError.server(status: 500, message: "The details read failed.")
        }
        return try await inner.conversationDetails(id)
    }

    func participants(in id: Conversation.ID, after cursor: String?) async throws
        -> ConversationParticipantPage {
        await wait(for: .participants)
        if failNextPeople {
            failNextPeople = false
            throw ChatError.server(status: 500, message: "The old people read failed.")
        }
        if cursor != nil {
            await wait(for: .laterPages)
        }
        if failingLaterPages, cursor != nil {
            throw ChatError.server(status: 500, message: "The page could not be loaded.")
        }
        return try await inner.participants(in: id, after: cursor)
    }

    func mutateConversation(
        _ mutation: ConversationMutation,
        in id: Conversation.ID,
        operationID: String,
        expectedRevision: String?
    ) async throws -> ConversationMutationResult {
        await wait(for: .mutation)
        mutationCount += 1
        if failingMutations || mutationCount == failingMutationNumber {
            throw ChatError.server(status: 500, message: "The change failed.")
        }
        return try await inner.mutateConversation(
            mutation, in: id, operationID: operationID, expectedRevision: expectedRevision
        )
    }

    func conversationIntegrations(_ id: Conversation.ID) async throws -> ConversationIntegrations {
        await wait(for: .integrations)
        return try await inner.conversationIntegrations(id)
    }

    func webhookDeliveryURL(_ webhookID: String, in id: Conversation.ID) async throws -> URL {
        await wait(for: .webhookURL)
        return try await inner.webhookDeliveryURL(webhookID, in: id)
    }
}
