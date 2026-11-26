import ChatAPI
import ChatKit
import Foundation

actor ReconciliationBackend: ManagedChatActivityBackend, ProviderCheckpointBackend {
    nonisolated let capabilities: Capabilities
    nonisolated let events: AsyncStream<ChatEvent>
    private let sink: AsyncStream<ChatEvent>.Continuation
    nonisolated let providerEventBatches: AsyncStream<ProviderEventBatch>
    let providerBatchSink: AsyncStream<ProviderEventBatch>.Continuation
    let checkpointing: Bool
    var acknowledgedBatches: [String] = []
    var resumedCheckpoint: Data?
    var acknowledgementObserver: (@Sendable (String) -> Void)?
    private var rows: [Conversation]
    private var history: [Message]
    private var directoryComplete = true
    private var holdWorld = false
    private var holdHistory = false
    private var worldWaiter: CheckedContinuation<Void, Never>?
    private var historyWaiter: CheckedContinuation<Void, Never>?
    private var holdEveryHistory = false
    private var historyWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var worldHeld = false
    private(set) var historyHeld = false
    private(set) var worldReads = 0
    private var worldFailures = 0
    private var worldFailure = ServiceFailure.overloaded
    private(set) var historyReads = 0
    private(set) var threadReads = 0
    private(set) var historyReadsByConversation: [Conversation.ID: Int] = [:]
    private var conversationHistories: [Conversation.ID: [Message]] = [:]
    private(set) var sentCommands: [ChatCommand] = []
    private(set) var receivePresence: Set<Member.ID> = []
    private(set) var receiveConversations: Set<Conversation.ID> = []
    var searchMembers: [Member] = []
    var preview = ConversationPreview()
    var detailsQuery: (@Sendable () async throws -> ConversationDetails)?
    var pinQuery: (@Sendable () async throws -> PinnedMessages)?
    var integrations = ConversationIntegrations()
    var appSearchReads = 0
    var emailReads = 0
    var consequenceReads = 0
    var consequences = ConversionConsequences(
        items: [ConversionConsequence(topic: .history, outcome: .changed)],
        requiresHistoryAcknowledgement: false
    )
    var appOpens = 0
    var managementMutations: [ConversationMutation] = []
    var deliveryURL = URL(string: "https://example.invalid/private-delivery-key")!
    var holdDeliveryURL = false
    private(set) var deliveryURLHeld = false
    private var deliveryURLWaiter: CheckedContinuation<Void, Never>?
    private(set) var integrationReads = 0
    private(set) var deliveryURLReads = 0

    func setIntegrations(_ value: ConversationIntegrations, holdURL: Bool = false) {
        integrations = value
        holdDeliveryURL = holdURL
    }

    func conversationIntegrations(_: Conversation.ID) -> ConversationIntegrations {
        integrationReads += 1
        return integrations
    }

    func webhookDeliveryURL(_: String, in _: Conversation.ID) async -> URL {
        deliveryURLReads += 1
        let value = deliveryURL
        if holdDeliveryURL {
            deliveryURLHeld = true
            await withCheckedContinuation { deliveryURLWaiter = $0 }
        }
        return value
    }

    func releaseDeliveryURL() {
        holdDeliveryURL = false
        deliveryURLWaiter?.resume()
        deliveryURLWaiter = nil
    }

    func setPreview(_ value: ConversationPreview) {
        preview = value
    }

    func conversationPreview(_: Conversation.ID) -> ConversationPreview {
        preview
    }

    var holdSearch = false
    private(set) var searchHeld = false
    private var searchWaiter: CheckedContinuation<Void, Never>?
    var holdTyping = false
    private(set) var typingHeld = false
    private(set) var disconnects = 0
    private(set) var startupAttempts = 0
    private var startupFailures: [ChatError]
    private var typingWaiter: CheckedContinuation<Void, Never>?

    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let conversation = Conversation.ID("shared")
    static let message = Message(
        id: Message.ID("message"), conversationID: conversation, threadID: MessageThread.ID("thread"),
        sender: Member.ID("peer"), text: "Original", createdAt: date
    )

    init(
        backfill: Bool = false,
        holdHistory: Bool = false,
        checkpointing: Bool = false,
        webhooks: Bool = false, integrationsFlags: Set<String> = [], pins: Bool = false,
        startupFailures: [ChatError] = []
    ) {
        self.checkpointing = checkpointing
        self.startupFailures = startupFailures
        (providerEventBatches, providerBatchSink) = AsyncStream
            .makeStream(bufferingPolicy: .bufferingOldest(128))
        capabilities = Capabilities(
            needsMentionBackfill: backfill,
            extendedFlags: integrationsFlags.union(webhooks ? ["conversationWebhooks"] : [])
                .union(pins ? ["messagePins"] : [])
        )
        self.holdHistory = holdHistory
        rows = [Conversation(id: Self.conversation, kind: .space, title: "Original", lastActivity: Self.date)]
        history = [Self.message]
        (events, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(128))
    }

    func beginFixtureConnection() throws {
        startupAttempts += 1
        if !startupFailures.isEmpty {
            throw startupFailures.removeFirst()
        }
    }

    func connect() throws {
        try beginFixtureConnection()
        sink.yield(.connectionStateChanged(.connected))
    }

    func disconnect() {
        disconnects += 1
    }

    func send(_ command: ChatCommand) async {
        if case .setTyping(_, _, true) = command, holdTyping {
            typingHeld = true
            await withCheckedContinuation { typingWaiter = $0 }
        }
        sentCommands.append(command)
    }

    func setReceiveInterests(presenceMembers: Set<Member.ID>, conversations: Set<Conversation.ID>) {
        receivePresence = presenceMembers; receiveConversations = conversations
    }

    func setSearchMembers(_ members: [Member], hold: Bool = false) {
        searchMembers = members
        holdSearch = hold
    }

    func searchPeople(_ query: String) async -> [Member] {
        let captured = searchMembers
        if holdSearch {
            holdSearch = false
            searchHeld = true
            await withCheckedContinuation { searchWaiter = $0 }
        }
        return captured
    }

    func releaseSearch() {
        searchWaiter?.resume(); searchWaiter = nil
    }

    func holdNextTyping() {
        holdTyping = true
    }

    func releaseTyping() {
        holdTyping = false; typingWaiter?.resume(); typingWaiter = nil
    }

    func holdNextWorld() {
        holdWorld = true
    }

    func holdNextHistory() {
        holdHistory = true
    }

    func releaseWorld() {
        worldWaiter?.resume(); worldWaiter = nil
    }

    func releaseHistory() {
        historyWaiter?.resume(); historyWaiter = nil
    }

    func holdHistoryQueries() {
        holdEveryHistory = true
    }

    func replaceHistorySilently(_ messages: [Message]) {
        history = messages
    }

    /// Answers reads of `conversation` with these messages instead of the
    /// shared history, so several conversations can each load their own.
    func setHistory(_ messages: [Message], in conversation: Conversation.ID) {
        conversationHistories[conversation] = messages
    }

    func releaseHistoryQuery(_ read: Int) {
        historyWaiters.removeValue(forKey: read)?.resume()
    }

    func releaseAllHistoryQueries() {
        holdEveryHistory = false
        let waiters = historyWaiters.values
        historyWaiters = [:]
        for waiter in waiters {
            waiter.resume()
        }
    }

    func emit(_ event: ChatEvent) {
        sink.yield(event)
    }

    func addConversation(_ id: Conversation.ID) {
        rows.append(Conversation(id: id, kind: .space, title: id.rawValue))
        sink.yield(.conversationsChanged(rows))
    }

    /// Recently active conversations, which the background refill fetches.
    func addRecentConversations(_ ids: [Conversation.ID]) {
        rows += ids.map { Conversation(id: $0, kind: .space, title: $0.rawValue, lastActivity: Self.date) }
        sink.yield(.conversationsChanged(rows))
    }

    func removeConversation() {
        rows = []
        sink.yield(.conversationRemoved(conversationID: Self.conversation, historyBefore: nil))
    }

    func deleteMessage() {
        history[0].isDeleted = true
        sink.yield(.messageDeleted(id: Self.message.id, in: Self.conversation))
    }

    func failNextWorldReads(_ count: Int, with failure: ServiceFailure = .overloaded) {
        worldFailures = count
        worldFailure = failure
    }

    func replaceDirectorySilently(_ conversations: [Conversation], complete: Bool) {
        rows = conversations
        directoryComplete = complete
    }

    func loadConversationSnapshot() async throws -> ConversationSnapshot {
        let complete = directoryComplete
        return try await ConversationSnapshot(conversations: loadConversations(), isComplete: complete)
    }

    func loadConversations() async throws -> [Conversation] {
        worldReads += 1
        if worldFailures > 0 {
            worldFailures -= 1
            throw worldFailure
        }
        let captured = rows
        if holdWorld {
            holdWorld = false; worldHeld = true
            await withCheckedContinuation { worldWaiter = $0 }
        }
        return captured
    }

    func loadMessages(in conversation: Conversation.ID, before: Message.ID?) async -> [Message] {
        historyReads += 1
        historyReadsByConversation[conversation, default: 0] += 1
        let read = historyReads
        let captured = conversationHistories[conversation]
            ?? history.filter { $0.conversationID == conversation }
        if holdEveryHistory {
            await withCheckedContinuation { historyWaiters[read] = $0 }
        } else if holdHistory {
            holdHistory = false; historyHeld = true
            await withCheckedContinuation { historyWaiter = $0 }
        }
        return captured
    }

    func loadThread(_ thread: MessageThread.ID, in conversation: Conversation.ID) -> [Message] {
        threadReads += 1
        return history.filter { $0.conversationID == conversation && $0.threadID == thread }
    }

    func setNotificationSetting(_ level: NotificationLevel, for conversation: Conversation.ID) {}
}
