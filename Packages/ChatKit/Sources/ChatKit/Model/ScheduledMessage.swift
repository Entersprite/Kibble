import Foundation

public struct ScheduledMessageAddress: Codable, Hashable, Sendable {
    public let conversation: Conversation.ID
    public let thread: MessageThread.ID?
    public let queueID: String

    public init(conversation: Conversation.ID, thread: MessageThread.ID?, queueID: String) {
        self.conversation = conversation
        self.thread = thread
        self.queueID = queueID
    }

    public var isValid: Bool {
        !queueID.isEmpty && !conversation.rawValue.isEmpty && thread?.rawValue.isEmpty != true
    }
}

public struct ScheduledMessage: Codable, Hashable, Sendable, Identifiable {
    public let id: ScheduledMessageAddress
    public var body: ComposedMessage
    public var deliveryTime: Date
    public let deliveryFailed: Bool
    public let canEditBody: Bool
    /// Display metadata from the queue. It does not identify or grant access to bytes.
    public let attachmentNames: [String]?
    public let isForward: Bool?

    public init(
        id: ScheduledMessageAddress, body: ComposedMessage, deliveryTime: Date,
        deliveryFailed: Bool = false, canEditBody: Bool = true, attachmentNames: [String]? = nil,
        isForward: Bool? = nil
    ) {
        self.id = id
        self.body = body
        self.deliveryTime = deliveryTime
        self.deliveryFailed = deliveryFailed
        self.canEditBody = canEditBody
        self.attachmentNames = attachmentNames
        self.isForward = isForward
    }

    public var hasContentWithoutCaption: Bool {
        isForward == true || attachmentNames?.isEmpty == false
    }
}

public struct ScheduledMessagesPage: Codable, Hashable, Sendable {
    public let messages: [ScheduledMessage]
    public let nextCursor: String?

    public init(messages: [ScheduledMessage], nextCursor: String? = nil) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

public extension ComposedMessage {
    func validateForScheduling(
        in conversation: Conversation.ID, capabilities: Capabilities, hasAttachments: Bool = false,
        editingCaption: Bool = false
    ) throws {
        let isForward = content?.forwardSource != nil
        guard !isForward || (capabilities.canScheduleForwards && !editingCaption && !hasAttachments) else {
            throw ChatError.unsupported(capability: "scheduled forwarding")
        }
        guard hasAttachments || editingCaption || isForward ||
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatError.decoding("Enter a message before scheduling it.")
        }
        try content?.validate(text: text, conversation: conversation, capabilities: capabilities)
        guard mentions.allSatisfy({ mention in
            let span = MessageFormat(style: "", start: mention.start, length: mention.length)
            if case .unknown = mention.target {
                return false
            }
            if case .unknown = mention.mode {
                return false
            }
            return Int32(exactly: mention.start) != nil && Int32(exactly: mention.length) != nil
                && span.range(in: text) != nil
        }) else { throw ChatError.decoding("Invalid scheduled message mentions.") }
    }
}

public extension Capabilities {
    var canScheduleMessages: Bool {
        extendedFlags.contains("scheduledMessages")
    }

    var canSendScheduledMessagesNow: Bool {
        canScheduleMessages && extendedFlags.contains("sendScheduledMessageNow")
    }

    var canScheduleSavedDraft: Bool {
        canScheduleMessages && canReadSyncedDrafts && extendedFlags.contains("scheduleSavedDraft")
    }

    var canScheduleAttachments: Bool {
        canScheduleMessages && canSendAttachments && extendedFlags.contains("scheduleAttachments")
    }

    var canScheduleForwards: Bool {
        canScheduleMessages && canForwardMessages && extendedFlags.contains("scheduleForwards")
    }
}

public extension ChatBackend {
    func scheduledMessages(after _: String?) async throws -> ScheduledMessagesPage {
        throw ChatError.unsupported(capability: "scheduledMessages")
    }

    func scheduleMessage(
        in _: Conversation.ID, thread _: MessageThread.ID?, body _: ComposedMessage, at _: Date
    ) async throws -> ScheduledMessage {
        throw ChatError.unsupported(capability: "scheduledMessages")
    }

    func scheduleSavedDraft(
        _: SyncedDraft,
        body _: ComposedMessage,
        at _: Date
    ) async throws -> ScheduledMessage {
        throw ChatError.unsupported(capability: "scheduleSavedDraft")
    }

    func scheduleWithAttachments(
        in _: ComposerDraftAddress, body _: ComposedMessage, attachments _: [Attachment],
        at _: Date, converting _: SyncedDraft?
    ) async throws -> ScheduledMessage {
        throw ChatError.unsupported(capability: "scheduleAttachments")
    }

    func editScheduledMessage(
        _: ScheduledMessageAddress,
        body _: ComposedMessage
    ) async throws -> ScheduledMessage {
        throw ChatError.unsupported(capability: "scheduledMessages")
    }

    func rescheduleMessage(_: ScheduledMessageAddress, at _: Date) async throws -> ScheduledMessage {
        throw ChatError.unsupported(capability: "scheduledMessages")
    }

    func cancelScheduledMessage(_: ScheduledMessageAddress) async throws {
        throw ChatError.unsupported(capability: "scheduledMessages")
    }

    func sendScheduledMessageNow(_: ScheduledMessageAddress) async throws {
        throw ChatError.unsupported(capability: "sendScheduledMessageNow")
    }
}
