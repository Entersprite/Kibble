import ChatAPI
import Foundation

extension AccountWorkspace {
    func schedule(_ account: AccountSummary, previous: AccountSummary?, force: Bool = false) {
        let intent = AccountClientIntent(account)
        guard force || intents[account.id] != intent else { return }
        intents[account.id] = intent
        replaceJob(account.id, target: account, previous: previous)
    }

    func scheduleRemoval(_ account: AccountSummary) {
        intents[account.id] = nil
        replaceJob(account.id, target: nil, previous: account)
    }

    private func replaceJob(_ id: ConnectedAccountID, target: AccountSummary?, previous: AccountSummary?) {
        let generation = UUID()
        generations[id] = generation
        let prior = jobs[id]
        prior?.cancel()
        jobs[id] = Task { [weak self] in
            await prior?.value
            guard let self, isCurrent(id, generation) else { return }
            defer {
                if self.generations[id] == generation {
                    self.jobs[id] = nil
                    if target == nil, self.cleanupRecords[id] == nil {
                        self.generations[id] = nil
                        self.cleanedBindings[id] = nil
                        self.accountErrors[id] = nil
                    }
                }
            }
            await transition(id, target: target, previous: previous, generation: generation)
        }
    }

    private func transition(
        _ id: ConnectedAccountID, target: AccountSummary?, previous: AccountSummary?, generation: UUID
    ) async {
        let session = sessions.removeValue(forKey: id) ?? cleanupSessions[id]
        let record = session?.account ?? cleanupRecords[id] ?? previous ?? target
        let authenticationErase = ["erasing", "required"].contains(target?.authenticationState ?? "")
        let replaced = record?.revision != nil && target != nil && record?.revision != target?.revision
        let erase = target == nil || target?
            .isRemoving == true || authenticationErase || replaced || cleanupRecords[id] != nil
        do {
            let alreadyCleaned = record?.revision.map { cleanedBindings[id] == $0 } ?? false
            if erase, let record, !alreadyCleaned {
                cleanupRecords[id] = record
                if let session {
                    cleanupSessions[id] = session
                    try await session.environment.detachClient(erasingPrivateData: true)
                } else {
                    try await host.eraseReplica(for: record)
                }
                cleanedBindings[id] = record.revision
                cleanupSessions[id] = nil
                cleanupRecords[id] = nil
            } else if let session {
                try await session.environment.detachClient(erasingPrivateData: false)
            }
            guard isCurrent(id, generation), let target, canRun(target) else { return }
            try await createSession(target, generation: generation)
            if isCurrent(id, generation) {
                accountErrors[id] = nil
            }
        } catch {
            guard generations[id] == generation else { return }
            accountErrors[id] = erase ? "Private data cleanup could not finish. Retry before signing in." :
                "This account could not start. Try again."
        }
    }

    private func createSession(_ account: AccountSummary, generation: UUID) async throws {
        let environment = try await host.makeEnvironment(for: account)
        environment.setActive(false)
        environment.setWindowOpen(false)
        environment.setDeviceActive(deviceActive)
        guard isCurrent(account.id, generation) else {
            try await environment.detachClient(erasingPrivateData: false)
            return
        }
        await environment.start()
        guard isCurrent(account.id, generation) else {
            try await environment.detachClient(erasingPrivateData: false)
            return
        }
        sessions[account.id] = AccountClientSession(account: account, environment: environment)
        environment.policyRevisionChanged(accounts.first { $0.id == account.id }?.policyRevision)
        applyViewing()
    }

    private func isCurrent(_ id: ConnectedAccountID, _ generation: UUID) -> Bool {
        !stopped && !Task.isCancelled && generations[id] == generation
    }
}
