import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeBackend {
    func sendReference(
        _ content: MessageContent?,
        in destination: Conversation.ID,
        localID: String
    ) async throws -> SendReplyTarget? {
        guard let source = content?.forwardSource else {
            return try MessageContentMapping.target(content?.quote, in: destination)
        }
        guard let client = apiClient,
              let group = ChannelEventMapping.groupID(for: source.conversation),
              !source.thread.rawValue.isEmpty, !source.id.rawValue.isEmpty else {
            throw ChatError.decoding("The original message cannot be addressed.")
        }
        let generation = directoryGeneration
        var request = ListMessagesRequest()
        request.requestHeader = APIRequestHeader.make()
        request.parentID.topicID.groupID = group
        request.parentID.topicID.topicID = source.thread.rawValue
        request.pageSize = Self.threadPageSize
        let response = try await client.call(.listMessages, request)
        try Task.checkCancellation()
        guard generation == directoryGeneration else { throw CancellationError() }
        guard let original = response.messages.first(where: {
            $0.id.messageID == source.id.rawValue && $0.id.parentID == request.parentID && $0.deleteTime == 0
        }), original.messageType != .systemMessage else {
            throw ChatError
                .decoding("The original message is unavailable. Refresh its conversation and try again.")
        }
        ownForwards.remember(OwnForwardSnapshots.snapshot(of: original), for: localID)
        var reference = SendReplyTarget()
        reference.id = original.id
        reference.createTime = original.hasLastUpdateTime ? original.lastUpdateTime : original.createTime
        reference.referenceType = 2
        return reference
    }

    /// The echo of a forward this session sent, with the source it was
    /// checked against when the echo arrives without one. The echo carries
    /// the send's local id; anything else passes through unchanged.
    func completingOwnForward(_ event: ChatEvent) -> ChatEvent {
        switch event {
        case let .messageReceived(message):
            .messageReceived(completingOwnForward(message))
        case let .messageUpdated(message):
            .messageUpdated(completingOwnForward(message))
        default:
            event
        }
    }

    private func completingOwnForward(_ message: ChatKit.Message) -> ChatKit.Message {
        guard !message.isDeleted, message.content?.forwarded == nil, let localID = message.localID,
              let snapshot = ownForwards.snapshot(for: localID) else { return message }
        var completed = message
        var content = message.content ?? MessageContent()
        content.quote = nil
        content.forwarded = snapshot
        completed.content = content
        return completed
    }
}

/// The sources of this session's own forwards, by local id, as the provider
/// returned them when the forward was checked. Bounded: an entry is needed
/// only until its echo arrives, and the oldest go first.
struct OwnForwardSnapshots {
    static let limit = 64

    private var entries: [String: ForwardedMessage] = [:]
    private var order: [String] = []

    mutating func remember(_ snapshot: ForwardedMessage?, for localID: String) {
        guard let snapshot, !localID.isEmpty else { return }
        if entries.updateValue(snapshot, forKey: localID) == nil {
            order.append(localID)
        }
        while order.count > Self.limit {
            entries[order.removeFirst()] = nil
        }
    }

    func snapshot(for localID: String) -> ForwardedMessage? {
        entries[localID]
    }

    mutating func forgetAll() {
        entries = [:]
        order = []
    }

    /// The display snapshot of a source message read from the provider.
    static func snapshot(of original: GChatBridgeCore.Message) -> ForwardedMessage? {
        guard let mapped = ChannelEventMapping.domainMessage(original), !mapped.isDeleted else { return nil }
        var source = MessageQuote(message: mapped)
        source.text = mapped.text
        let name = original.creator.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return ForwardedMessage(
            source: source,
            senderName: name.isEmpty ? nil : String(name.prefix(200)),
            senderAvatarURL: ChannelEventMapping.webURL(original.creator.avatarURL).flatMap {
                $0.scheme?.lowercased() == "https" ? $0 : nil
            },
            mentions: mapped.mentions, formatting: mapped.content?.formatting ?? [],
            customEmoji: mapped.content?.customEmoji ?? [],
            attachments: mapped.attachments, links: mapped.links
        )
    }
}
