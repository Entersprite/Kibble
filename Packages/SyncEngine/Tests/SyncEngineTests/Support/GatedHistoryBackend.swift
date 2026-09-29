import ChatKit
import Foundation

/// A backend for the mention backfill. Every `loadMessages` parks until the
/// test releases its conversation, or opens the gate for all of them, and
/// the backend counts how many are in flight at once. `loadConversations`
/// answers `world`, and can be held the same way, for the one test that
/// needs a world load to land while `stop()` is draining.
///
/// `HangingHistoryBackend`'s idiom, per conversation. Nothing here can make a
/// parked call return early, which is exactly the property a cancelled run
/// has to survive.
actor GatedHistoryBackend: ChatBackend {
    nonisolated let capabilities = Capabilities()
    nonisolated let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation

    private var world: [Conversation]
    private var pages: [Conversation.ID: [Message]] = [:]
    private var failing: Set<Conversation.ID> = []
    private var gateOpen = false
    private var parked: [Conversation.ID: [CheckedContinuation<Void, Never>]] = [:]
    private var holdingWorld = false
    private var parkedWorld: CheckedContinuation<Void, Never>?

    private(set) var requested: [Conversation.ID] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0

    init(world: [Conversation]) {
        self.world = world
        (events, continuation) = AsyncStream.makeStream(of: ChatEvent.self, bufferingPolicy: .unbounded)
    }

    var parkedCount: Int {
        parked.values.reduce(0) { $0 + $1.count }
    }

    var isHoldingWorld: Bool {
        parkedWorld != nil
    }

    func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }

    func setWorld(_ conversations: [Conversation]) {
        world = conversations
    }

    func answer(_ conversation: Conversation.ID, with page: [Message]) {
        pages[conversation] = page
    }

    func fail(_ conversation: Conversation.ID) {
        failing.insert(conversation)
    }

    /// Resumes the fetches parked for one conversation. Later ones still park.
    func release(_ conversation: Conversation.ID) {
        for fetch in parked.removeValue(forKey: conversation) ?? [] {
            fetch.resume()
        }
    }

    /// Resumes every parked fetch, and no later one parks.
    func openGate() {
        gateOpen = true
        let waiting = parked.values.flatMap(\.self)
        parked = [:]
        for fetch in waiting {
            fetch.resume()
        }
    }

    func holdWorld() {
        holdingWorld = true
    }

    func releaseWorld() {
        holdingWorld = false
        parkedWorld?.resume()
        parkedWorld = nil
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_: ChatCommand) async throws {}
    func setNotificationSetting(_: NotificationLevel, for _: Conversation.ID) async throws {}

    func loadConversations() async throws -> [Conversation] {
        if holdingWorld {
            await withCheckedContinuation { parkedWorld = $0 }
        }
        return world
    }

    func loadMessages(in conversation: Conversation.ID, before _: Message.ID?) async throws -> [Message] {
        requested.append(conversation)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if !gateOpen {
            await withCheckedContinuation { parked[conversation, default: []].append($0) }
        }
        inFlight -= 1
        if failing.contains(conversation) {
            throw ChatError.server(status: 500, message: "gated failure")
        }
        return pages[conversation] ?? []
    }
}
