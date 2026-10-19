import ChatAPI
import ChatKit
import Foundation

extension ChatService {
    static let linkOperations: Set<String> = [
        BeginAccountLink.operation,
        GetAccountLink.operation,
        CompleteAccountLink.operation,
        CancelAccountLink.operation
    ]

    func restoreLinks() throws {
        guard let registry = registry as? any AccountLinkRegistry else { return }
        links = try Dictionary(uniqueKeysWithValues: registry.links().map { ($0.id, $0) })
        guard linkCustody != nil else { return }
        for link in links.values {
            let resumes = ["verified", "installing", "committed", "canceling", "duplicate"]
                .contains(link.phase)
            let expires = link.phase == "pendingCapture" && link.expiresAt <= Date()
            guard resumes || expires else { continue }
            linkTasks[link.id] = Task {
                defer { linkTasks[link.id] = nil }
                return try await advanceLink(link.id, cancel: expires || link.phase == "canceling")
            }
        }
    }

    func routeLink(_ request: ServiceRequest, context: ServiceSessionContext) async throws -> JSONValue {
        guard context.canLinkAccounts else { throw ServiceFailure.notAuthorized }
        guard linkCustody != nil,
              registry is any AccountLinkRegistry else { throw ServiceFailure.unsupportedOperation }
        switch request.operation {
        case BeginAccountLink.operation:
            await expirePendingLinks()
            return try ServiceCodec.value(beginLink(
                request.decodePayload(BeginAccountLink.self),
                context: context
            ))
        case GetAccountLink.operation:
            let id = try request.decodePayload(GetAccountLink.self).linkID
            return try ServiceCodec.value(ownedLink(id, context: context).summary)
        case CompleteAccountLink.operation:
            let id = try request.decodePayload(CompleteAccountLink.self).linkID
            _ = try ownedLink(id, context: context)
            return try await ServiceCodec.value(runLink(id, cancel: false))
        case CancelAccountLink.operation:
            let id = try request.decodePayload(CancelAccountLink.self).linkID
            _ = try ownedLink(id, context: context)
            if let work = linkTasks[id] {
                work.cancel()
                _ = await work.result
            }
            return try await ServiceCodec.value(runLink(id, cancel: true))
        default: throw ServiceFailure.unsupportedOperation
        }
    }

    /// Host-only capture setup. Shared clients only receive AccountLinkSummary.
    public func captureIntent(
        _ id: AccountLinkID,
        context: ServiceSessionContext
    ) throws -> AccountLinkRecord {
        guard context.canLinkAccounts, !shuttingDown else { throw ServiceFailure.notAuthorized }
        let link = try ownedLink(id, context: context)
        guard link.phase == "pendingCapture",
              link.expiresAt > Date() else { throw ServiceFailure.invalidRequest }
        return link
    }

    private func ownedLink(_ id: AccountLinkID, context: ServiceSessionContext) throws -> AccountLinkRecord {
        guard let link = links[id], link.principalID == context.principalID,
              link.deviceID == context.deviceID else { throw ServiceFailure.notAuthorized }
        if let target = link.targetAccountID,
           !context.allowsAccount(target) {
            throw ServiceFailure.notAuthorized
        }
        return link
    }

    private func expirePendingLinks() async {
        let expired = links.values.filter { $0.phase == "pendingCapture" && $0.expiresAt <= Date() }
        for link in expired where linkTasks[link.id] == nil {
            _ = try? await runLink(link.id, cancel: true)
        }
    }

    private func beginLink(
        _ payload: BeginAccountLink,
        context: ServiceSessionContext
    ) throws -> AccountLinkSummary {
        if let prior = links.values.first(where: {
            $0.operationID == payload.operationID && $0.principalID == context.principalID && $0
                .deviceID == context.deviceID
        }) {
            guard prior.targetAccountID == payload.targetAccountID
            else { throw ServiceFailure.operationConflict }
            return prior.summary
        }
        let active = links.values.filter {
            $0.principalID == context.principalID && !["completed", "canceled", "alreadyConnected"]
                .contains($0.phase)
        }
        guard active.count < 8 else { throw ServiceFailure.overloaded }
        var target: AccountRecord?
        if let id = payload.targetAccountID {
            guard context.allowsAccount(id), let record = records[id],
                  record.principalID == context.principalID,
                  !record.isRemoving else { throw ServiceFailure.notAuthorized }
            target = record
        }
        let link = AccountLinkRecord(
            id: AccountLinkID(UUID().uuidString), operationID: payload.operationID,
            principalID: context.principalID, deviceID: context.deviceID, targetAccountID: target?.id,
            accountID: target?.id ?? ConnectedAccountID(UUID().uuidString), generation: UUID().uuidString,
            previousGeneration: target?.credentialGeneration, expiresAt: Date().addingTimeInterval(1200),
            label: target?.label ?? "Account"
        )
        try saveLink(link)
        return link.summary
    }

    private func runLink(_ id: AccountLinkID, cancel: Bool) async throws -> AccountLinkSummary {
        guard linkTasks[id] == nil else { throw ServiceFailure.overloaded }
        let work = Task {
            defer { linkTasks[id] = nil }
            return try await advanceLink(id, cancel: cancel)
        }
        linkTasks[id] = work
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func saveLink(_ link: AccountLinkRecord) throws {
        guard let registry = registry as? any AccountLinkRegistry
        else { throw ServiceFailure.unsupportedOperation }
        try registry.saveLink(link)
        links[link.id] = link
    }

    private func advanceLink(_ id: AccountLinkID, cancel: Bool) async throws -> AccountLinkSummary {
        guard var link = links[id], let custody = linkCustody else { throw ServiceFailure.invalidRequest }
        switch link.phase {
        case "completed", "canceled", "alreadyConnected": return link.summary
        case "committed": return try await finalizeLink(link, custody: custody)
        case "duplicate": return try await finalizeDuplicate(link, custody: custody)
        case "pendingCapture", "verified", "installing", "canceling": break
        default: throw ServiceFailure.unsupportedOperation
        }
        if cancel || link.phase == "canceling" || link.expiresAt <= Date() {
            return try await cancelLink(link, custody: custody)
        }
        link = try await verifyLink(link, custody: custody)
        if let existing = duplicateAccount(link) {
            return try await resolveDuplicate(link, existing: existing, custody: custody)
        }
        return try await installLink(link, custody: custody)
    }

    private func verifyLink(
        _ original: AccountLinkRecord,
        custody: any AccountLinkCustody
    ) async throws -> AccountLinkRecord {
        var link = original
        if link.phase == "pendingCapture" {
            let identity = try await custody.verify(link)
            try checkLinkActive()
            if let target = link.targetAccountID {
                guard records[target]?.selfID == identity.selfID
                else { throw ServiceFailure.operationConflict }
            }
            link.selfID = identity.selfID
            link.label = identity.label
            link.phase = "verified"
            try saveLink(link)
        }
        return link
    }

    private func installLink(
        _ link: AccountLinkRecord,
        custody: any AccountLinkCustody
    ) async throws -> AccountLinkSummary {
        guard !changing.contains(link.accountID) else { throw ServiceFailure.overloaded }
        changing.insert(link.accountID)
        defer { changing.remove(link.accountID) }
        try checkLinkActive()
        let account = try linkedAccount(link)
        if let runtime = runtimes[link.accountID] {
            await runtime.stop()
            runtimes[link.accountID] = nil
        }
        do {
            try checkLinkActive()
            var installing = link
            installing.phase = "installing"
            try saveLink(installing)
            try await custody.install(installing)
            try checkLinkActive()
            if let existing = duplicateAccount(installing) {
                return try await resolveDuplicate(installing, existing: existing, custody: custody)
            }
            guard let registry = registry as? any AccountLinkRegistry
            else { throw ServiceFailure.unsupportedOperation }
            try registry.commitLink(installing, account: account)
            records[account.id] = account
            installing.phase = "committed"
            links[link.id] = installing
            try await startLinkedAccount(account)
            return try await finalizeLink(installing, custody: custody)
        } catch {
            if let current = records[link.accountID] {
                try? await startLinkedAccount(current)
            }
            throw error
        }
    }

    private func duplicateAccount(_ link: AccountLinkRecord) -> ConnectedAccountID? {
        guard link.targetAccountID == nil else { return nil }
        return records.values.first { $0.principalID == link.principalID && $0.selfID == link.selfID }?.id
    }

    private func resolveDuplicate(
        _ link: AccountLinkRecord, existing: ConnectedAccountID, custody: any AccountLinkCustody
    ) async throws -> AccountLinkSummary {
        var duplicate = link
        duplicate.resolvedAccountID = existing
        duplicate.phase = "duplicate"
        try saveLink(duplicate)
        return try await finalizeDuplicate(duplicate, custody: custody)
    }

    private func finalizeDuplicate(
        _ link: AccountLinkRecord,
        custody: any AccountLinkCustody
    ) async throws -> AccountLinkSummary {
        try await custody.discardStaging(link)
        try await custody.eraseGeneration(account: link.accountID, generation: link.generation)
        var resolved = link
        resolved.phase = "alreadyConnected"
        try saveLink(resolved)
        return resolved.summary
    }

    private func linkedAccount(_ link: AccountLinkRecord) throws -> AccountRecord {
        guard let identity = link.selfID else { throw ServiceFailure.invalidRequest }
        if let target = link.targetAccountID {
            guard var current = records[target], !current.isRemoving,
                  current.credentialGeneration == link.previousGeneration,
                  current.selfID == identity else { throw ServiceFailure.revisionConflict }
            current.credentialGeneration = link.generation
            return current
        }
        guard !records.values
            .contains(where: { $0.principalID == link.principalID && $0.selfID == identity }) else {
            throw ServiceFailure.operationConflict
        }
        return AccountRecord(
            id: link.accountID,
            principalID: link.principalID,
            selfID: identity,
            label: link.label,
            credentialGeneration: link.generation
        )
    }

    private func startLinkedAccount(_ account: AccountRecord) async throws {
        guard account.isEnabled, runtimes[account.id] == nil, !shuttingDown else { return }
        let runtime = try makeRuntime(account)
        runtimes[account.id] = runtime
        await runtime.start()
    }

    private func finalizeLink(
        _ link: AccountLinkRecord,
        custody: any AccountLinkCustody
    ) async throws -> AccountLinkSummary {
        try await custody.discardStaging(link)
        if let previous = link.previousGeneration {
            try await custody.eraseGeneration(account: link.accountID, generation: previous)
        }
        var completed = link
        completed.phase = "completed"
        try saveLink(completed)
        return completed.summary
    }

    private func cancelLink(
        _ link: AccountLinkRecord,
        custody: any AccountLinkCustody
    ) async throws -> AccountLinkSummary {
        var canceling = link
        canceling.phase = "canceling"
        try saveLink(canceling)
        try await custody.discardStaging(canceling)
        try await custody.eraseGeneration(account: link.accountID, generation: link.generation)
        canceling.phase = "canceled"
        try saveLink(canceling)
        return canceling.summary
    }

    private func checkLinkActive() throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw ServiceFailure.overloaded }
    }
}
