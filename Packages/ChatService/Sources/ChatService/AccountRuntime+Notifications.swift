import ChatAPI
import ChatKit
import ChatRules
import Foundation

extension AccountRuntime {
    func notificationsChanged() {
        guard notificationHost != nil, storage is any ServiceNotificationStorage,
              !stopped, !quarantinedForSubscription else { return }
        notificationDirty = true
        guard notificationJob == nil else { return }
        let epoch = currentEpoch
        notificationJob = Task { [self] in
            defer { notificationJob = nil }
            while notificationDirty, !Task.isCancelled, !stopped, !quarantinedForSubscription {
                notificationDirty = false
                do {
                    try await drainNotifications(epoch: epoch)
                } catch {
                    guard !Task.isCancelled, !stopped, !quarantinedForSubscription else { return }
                    notificationDirty = true
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }

    private func drainNotifications(epoch: UUID) async throws {
        guard let host = notificationHost,
              let outbox = storage as? any ServiceNotificationStorage else { return }
        let page = try outbox.notifications(for: host.deviceID)
        if page.reset {
            try await host.deliver(notificationFrame(
                "reset",
                payload: .object([:]),
                id: "reset:\(page.checkpoint)"
            ))
            try checkEpoch(epoch)
            try outbox.acknowledgeNotifications(for: host.deviceID, through: page.checkpoint)
            return
        }
        for item in page.items {
            try checkEpoch(epoch)
            let state = await host.state(account: record.id)
            try checkEpoch(epoch)
            if let frame = try notification(for: item, state: state, outbox: outbox) {
                try await host.deliver(frame)
                try checkEpoch(epoch)
            }
            try outbox.acknowledgeNotifications(for: host.deviceID, through: item.sequence)
        }
        if !page.items.isEmpty {
            notificationDirty = true
        }
    }

    private func notification(
        for item: ServiceNotificationItem, state: NotificationDeviceState,
        outbox: any ServiceNotificationStorage
    ) throws -> Data? {
        let id = try storage.checkpoint().streamID.rawValue + ":" + String(item.sequence)
        if let position = item.readPosition {
            return try notificationFrame("withdraw", payload: ServiceCodec.value(HostNotificationWithdrawal(
                conversation: item.conversation, upTo: position
            )), id: id)
        }
        guard let messageID = item.message,
              let facts = try outbox.notificationFacts(messageID) else { return nil }
        guard facts.me == record.selfID else { throw ServiceFailure.overloaded }
        let settings = try policies.policy(for: record).settings
        guard settings.schemaVersion == NotificationSettings.currentSchemaVersion,
              Set(settings.records.map(\.scope)).count == settings.records.count else {
            throw ServiceFailure.policyUnavailable
        }
        let message = facts.message
        let rule = settings.resolve(for: facts.conversation)
        let thread = message.isReply ? NotificationPolicy.ThreadContext(
            isFollowed: facts.thread?.isFollowed ?? false,
            isOnScreen: state.conversation == message.conversationID && state.thread == message.threadID
        ) : nil
        let decision = NotificationPolicy.decide(.init(
            message: message, rule: rule, me: facts.me, viewing: state.conversation,
            alreadyAnnounced: false, paused: state.paused, mentionsMe: message.mentionsMe(facts.me),
            thread: thread
        ))
        guard case let .post(presentation) = decision else { return nil }
        return try notificationFrame("post", payload: ServiceCodec.value(HostNotificationPost(
            message: message, conversation: facts.conversation, members: facts.members, me: record.selfID,
            accountLabel: record.label, isPassive: presentation.isPassive,
            playsSound: presentation.playsSound,
            showsPreview: presentation.showsPreview,
            offersMarkRead: capabilities.canMarkRead && rule.readReceipts && !message.isReply
        )), id: id)
    }

    private func notificationFrame(_ operation: String, payload: JSONValue, id: String) throws -> Data {
        let bytes = try ServiceCodec.encode(HostNotificationFrame(
            service: notificationService, account: record.id, revision: record.currentRevision,
            deliveryID: id, operation: operation, payload: payload
        ))
        guard bytes.count <= 4 * 1024 * 1024 else { throw ServiceFailure.frameTooLarge }
        return bytes
    }

    func withdrawHostNotifications() async {
        guard let notificationHost else { return }
        if let frame = try? notificationFrame("reset", payload: .object([:]), id: "stop:\(instanceID)") {
            try? await notificationHost.deliver(frame)
        }
    }
}
