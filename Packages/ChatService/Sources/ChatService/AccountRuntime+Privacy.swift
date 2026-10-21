import ChatAPI
import ChatKit

extension AccountRuntime {
    func authorizeForward(_ command: ChatCommand) throws {
        guard case let .sendMessage(destination, _, _, _, attachments, _, content) = command,
              let source = content?.forwardSource else { return }
        guard capabilities.canForwardMessages else { throw ServiceFailure.unsupportedOperation }
        guard attachments.isEmpty, try storage.conversation(source.conversation) != nil,
              try storage.conversation(destination) != nil else { throw ServiceFailure.notAuthorized }
    }

    /// Resolve the current canonical rule immediately before first dispatch.
    /// Previously completed operations can be inspected without re-dispatching.
    /// No client-supplied settings or conversation kind influence this decision.
    func authorizePrivacy(_ command: ChatCommand) throws {
        let conversation: Conversation.ID
        let isTyping: Bool
        switch command {
        case let .markRead(id, _), let .markThreadRead(id, _, _):
            conversation = id; isTyping = false
        case let .setThreadUnreadMark(id, _, at) where at == nil:
            conversation = id; isTyping = false
        case let .setTyping(id, _, active) where active:
            conversation = id; isTyping = true
        default:
            // Stopping typing must remain possible after consent is withdrawn
            // or policy storage becomes unavailable.
            return
        }
        let settings: NotificationSettings
        do {
            settings = try policies.policy(for: record).settings
            guard settings.schemaVersion == NotificationSettings.currentSchemaVersion,
                  Set(settings.records.map(\.scope)).count == settings.records.count
            else { throw ServiceFailure.policyUnavailable }
        } catch {
            throw ServiceFailure.policyUnavailable
        }
        guard let row = try storage.conversation(conversation) else { throw ServiceFailure.privacyDenied }
        let rule = settings.resolve(for: row)
        guard isTyping ? rule.sharesTyping : rule.readReceipts else { throw ServiceFailure.privacyDenied }
    }
}
