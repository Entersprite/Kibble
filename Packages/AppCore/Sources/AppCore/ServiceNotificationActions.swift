import ChatAPI
import ChatKit
import Foundation
import ServiceClient

/// Notification buttons act through the service even without a client replica.
@MainActor
public final class ServiceNotificationActions {
    private let service: ServiceInstanceID
    private let client: AccountClient
    private let device: String
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    public var onFailure: (() -> Void)?

    public init(service: ServiceInstanceID, client: AccountClient, device: String) {
        self.service = service; self.client = client; self.device = device
    }

    public func handle(_ response: AccountNotificationResponse) -> Bool {
        switch response.response {
        case .open, .openMessage: return false
        case .markRead, .mute: break
        }
        guard !stopped, response.scope.service == service else { return true }
        guard jobs.count < 16 else { onFailure?(); return true }
        let id = UUID()
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            defer { jobs[id] = nil }
            do {
                try await perform(response)
            } catch {
                if !Task.isCancelled {
                    onFailure?()
                }
            }
        }
        return true
    }

    public func stop() async {
        stopped = true
        let pending = Array(jobs.values)
        pending.forEach { $0.cancel() }
        for job in pending {
            await job.value
        }
        jobs = [:]
    }

    private func perform(_ response: AccountNotificationResponse) async throws {
        try await waitForAccount(response.scope)
        let scope = response.scope
        switch response.response {
        case let .markRead(conversation):
            let page = try await client.call(
                LoadMessages(conversationID: conversation),
                account: scope.account,
                revision: scope.revision
            )
            try Task.checkCancellation()
            guard let position = page.messages.filter({ !$0.isReply && !$0.isDeleted }).map(\.createdAt).max()
            else { return }
            _ = try await client.call(
                SendCommand(operationID: .init(ClientOperationID.make()), command: .markRead(
                    conversationID: conversation, upTo: position
                )),
                account: scope.account,
                revision: scope.revision
            )
        case let .mute(conversation): try await mute(conversation, scope: scope)
        case .open, .openMessage: break
        }
    }

    private func waitForAccount(_ scope: AccountNotificationScope) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard let account = try await client.accounts().first(where: { $0.id == scope.account }),
                  account.revision == scope.revision else { throw ServiceFailure.staleAccount }
            guard account.isEnabled, !account.isRemoving, account.authenticationState == nil else {
                throw ServiceFailure.accountDisabled
            }
            if account.isReady {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ServiceFailure.overloaded
    }

    private func mute(_ conversation: Conversation.ID, scope: AccountNotificationScope) async throws {
        for _ in 0 ..< 3 {
            let policy = try await client.call(
                GetAccountPolicy(),
                account: scope.account,
                revision: scope.revision
            )
            var settings = policy.settings
            guard settings.schemaVersion == NotificationSettings.currentSchemaVersion else {
                throw ServiceFailure.policyUnavailable
            }
            var rule = settings.rule(for: .conversation(conversation)) ?? NotificationRule()
            rule.delivery = .off
            settings.setRule(rule, for: .conversation(conversation), at: Date(), by: device)
            do {
                _ = try await client.call(
                    SetAccountPolicy(settings: settings, expectedRevision: policy.revision),
                    account: scope.account,
                    revision: scope.revision
                )
                return
            } catch let error as ServiceFailure where error == .revisionConflict { continue }
        }
        throw ServiceFailure.overloaded
    }
}
