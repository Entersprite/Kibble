import Foundation

/// A composer location inside one bound account. Nil `thread` addresses the conversation composer.
public struct ComposerDraftAddress: Codable, Hashable, Sendable {
    public let conversation: Conversation.ID
    public let thread: MessageThread.ID?

    public init(conversation: Conversation.ID, thread: MessageThread.ID? = nil) {
        self.conversation = conversation
        self.thread = thread
    }
}

/// Signals that the account should reread a composer or its delivery queue.
public struct UnsentMessagesChange: Codable, Hashable, Sendable {
    public let address: ComposerDraftAddress?
    public let drafts: Bool
    public let scheduled: Bool

    public init(address: ComposerDraftAddress?, drafts: Bool, scheduled: Bool) {
        self.address = address
        self.drafts = drafts
        self.scheduled = scheduled
    }
}

/// A provider-saved draft. The opaque ID and address identify the original record together.
public struct SyncedDraft: Codable, Hashable, Sendable, Identifiable {
    public struct ID: Codable, Hashable, Sendable {
        public let address: ComposerDraftAddress
        public let record: String

        public init(address: ComposerDraftAddress, record: String) {
            self.address = address
            self.record = record
        }
    }

    public let id: ID
    public let body: ComposedMessage
    public let modifiedAt: Date?
    /// The provider's opaque value for this content version, when available.
    public let changeToken: String?
    public let canRestore: Bool

    public init(
        id: ID, body: ComposedMessage, modifiedAt: Date? = nil, changeToken: String? = nil,
        canRestore: Bool = true
    ) {
        self.id = id
        self.body = body
        self.modifiedAt = modifiedAt
        self.changeToken = changeToken
        self.canRestore = canRestore
    }

    public func canConsume(with command: ChatCommand, allowingAttachments: Bool = false) -> Bool {
        guard case let .sendMessage(conversation, thread, text, localID?, attachments, _, content) = command
        else { return false }
        return canRestore && id.address == ComposerDraftAddress(conversation: conversation, thread: thread)
            && !id.record.isEmpty && !localID.isEmpty && !text.isEmpty
            && (allowingAttachments || attachments.isEmpty)
            && content?.forwardSource == nil
    }
}

public struct SyncedDraftPage: Codable, Hashable, Sendable {
    public let drafts: [SyncedDraft]
    public let nextCursor: String?

    public init(drafts: [SyncedDraft], nextCursor: String? = nil) {
        self.drafts = drafts
        self.nextCursor = nextCursor
    }
}

/// A write against the version the composer had open. A nil body clears that version.
public struct SyncedDraftChange: Codable, Hashable, Sendable {
    public let address: ComposerDraftAddress
    public let previous: SyncedDraft?
    public let body: ComposedMessage?

    public init(address: ComposerDraftAddress, previous: SyncedDraft?, body: ComposedMessage?) {
        self.address = address
        self.previous = previous
        self.body = body
    }

    public func matches(_ current: SyncedDraft?) -> Bool {
        guard let previous, let current else { return previous == nil && current == nil }
        guard previous.id == current.id else { return false }
        if let token = current.changeToken {
            return previous.changeToken == token
        }
        return previous.canRestore && current.canRestore && previous.changeToken == nil
            && previous.body == current.body && Self.matchesTime(previous.modifiedAt, current.modifiedAt)
    }

    public func validate(capabilities: Capabilities) throws {
        guard !address.conversation.rawValue.isEmpty, address.thread?.rawValue.isEmpty != true,
              previous == nil || previous?.id.address == address,
              body != nil || previous != nil else {
            throw ChatError.decoding("Invalid draft change.")
        }
        guard let body else { return }
        guard !body.text.isEmpty || body.content?.quote != nil else {
            throw ChatError.decoding("An empty draft should be cleared.")
        }
        guard body.content?.forwardSource == nil else {
            throw ChatError.unsupported(capability: "saving a forwarded draft")
        }
        try body.content?.validate(
            text: body.text,
            conversation: address.conversation,
            capabilities: capabilities
        )
        if let quote = body.content?.quote {
            guard !quote.isDeleted, !quote.id.rawValue.isEmpty, !quote.thread.rawValue.isEmpty else {
                throw ChatError.decoding("Invalid draft quote.")
            }
        }
        for mention in body.mentions {
            if case .unknown = mention.target {
                throw ChatError.decoding("Invalid draft mention.")
            }
            if case .unknown = mention.mode {
                throw ChatError.decoding("Invalid draft mention.")
            }
            let span = MessageFormat(style: "", start: mention.start, length: mention.length)
            guard span.range(in: body.text) != nil, Int32(exactly: mention.start) != nil,
                  Int32(exactly: mention.length) != nil else {
                throw ChatError.decoding("Invalid draft mention.")
            }
        }
    }

    private static func matchesTime(_ expected: Date?, _ current: Date?) -> Bool {
        guard let expected, let current else { return expected == nil && current == nil }
        guard let expectedTime = try? RFC3339.string(from: expected),
              let currentTime = try? RFC3339.string(from: current) else { return false }
        return expectedTime == currentTime
    }
}

/// The state observed after an applied change, or the current draft on conflict.
public struct SyncedDraftWriteResult: Codable, Hashable, Sendable {
    public let applied: Bool
    public let current: SyncedDraft?

    public init(applied: Bool, current: SyncedDraft?) {
        self.applied = applied
        self.current = current
    }
}

public extension Capabilities {
    var canReadSyncedDrafts: Bool {
        extendedFlags.contains("syncedDraftReads")
    }

    var canWriteSyncedDrafts: Bool {
        canReadSyncedDrafts && extendedFlags.contains("syncedDraftWrites")
    }

    var canSendSavedDraft: Bool {
        canSendMessages && canReadSyncedDrafts && extendedFlags.contains("sendSavedDraft")
    }

    var canSendSavedDraftWithAttachments: Bool {
        canSendSavedDraft && canSendAttachments && extendedFlags.contains("sendSavedDraftWithAttachments")
    }
}

public extension ChatBackend {
    func send(_: ChatCommand, consuming _: SyncedDraft) async throws -> Bool {
        throw ChatError.unsupported(capability: "sendSavedDraft")
    }

    func syncedDrafts(at _: ComposerDraftAddress?, after _: String?) async throws -> SyncedDraftPage {
        throw ChatError.unsupported(capability: "syncedDraftReads")
    }

    func writeSyncedDraft(
        _: SyncedDraftChange,
        operationID _: String
    ) async throws -> SyncedDraftWriteResult {
        throw ChatError.unsupported(capability: "syncedDraftWrites")
    }
}
