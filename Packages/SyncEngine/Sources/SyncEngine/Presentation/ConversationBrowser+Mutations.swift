import ChatKit

/// The open panel's changes. Its own file for `ConversationBrowser.swift`'s length.
public extension ConversationBrowser {
    /// The open panel's change on its way, shown at once. Another panel's change is not shown here.
    var pendingMutation: ConversationMutation? {
        guard let pendingChange, pendingChange.conversation == panelTarget else { return nil }
        return pendingChange.mutation
    }

    func mutate(_ mutation: ConversationMutation) {
        guard let details, !isSubmitting, !isLoadingAllParticipants, !stopped, !needsReconciliation
        else { return }
        retirePanelReadsForMutation()
        isSubmitting = true
        pendingChange = (details.conversation.id, mutation)
        panelError = nil
        let generation = generation
        writeTask = Task { [weak self, engine] in
            do {
                let result = try await engine.mutateConversation(
                    mutation, in: details.conversation.id, operationID: ClientOperationID.make(),
                    expectedRevision: details.revision
                )
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                pendingChange = nil
                applyManagementResult(result, mutation: mutation, in: details.conversation.id)
            } catch {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
                isSubmitting = false
                pendingChange = nil
                // Another panel's failure is not this one's to show.
                guard panelTarget == details.conversation.id else { return }
                recoverMetadata(mutation, in: details.conversation.id, error: Self.message(error))
            }
        }
    }

    /// Several people's changes as one submission, sent one after another:
    /// the panel takes one write at a time. Each write carries the revision
    /// the last one confirmed. The first refusal or unconfirmed answer stops
    /// the rest, and the panel says how many went through. One reload
    /// follows, for the same conversation only.
    func mutateEach(_ mutations: [ConversationMutation]) {
        guard mutations.count > 1 else {
            mutations.first.map(mutate)
            return
        }
        guard let details, let id = panelTarget, details.conversation.id == id, !isSubmitting,
              !isLoadingAllParticipants, !stopped, !needsReconciliation else { return }
        retirePanelReadsForMutation()
        isSubmitting = true
        pendingChange = (id, mutations[0])
        panelError = nil
        let generation = generation
        writeTask = Task { [weak self, engine] in
            var batch = BatchOutcome(revision: details.revision)
            for mutation in mutations {
                guard let self, !Task.isCancelled, !stopped, self.generation == generation,
                      panelTarget == id else { break }
                if batch.revisionLost {
                    batch.failure = .noRevision
                    break
                }
                pendingChange = (id, mutation)
                do {
                    let result = try await engine.mutateConversation(
                        mutation, in: id, operationID: ClientOperationID.make(),
                        expectedRevision: batch.revision
                    )
                    guard batch.record(result, of: mutation) else { break }
                    guard !Task.isCancelled, !stopped, self.generation == generation,
                          panelTarget == id else { break }
                    retainConfirmedRole(mutation, result: result)
                } catch {
                    batch.failure = .refused(Self.message(error))
                    break
                }
            }
            guard let self, !Task.isCancelled, !stopped, self.generation == generation else { return }
            isSubmitting = false
            pendingChange = nil
            finish(batch, of: mutations, in: id)
        }
    }

    private func finish(_ batch: BatchOutcome, of mutations: [ConversationMutation], in id: Conversation.ID) {
        guard let last = batch.last else {
            // Nothing went through: as a single change's failure, on its own panel only.
            guard panelTarget == id else { return }
            switch batch.failure {
            case let .refused(message):
                needsReconciliation = true
                panelError = message
            case .unconfirmed, .noRevision, nil:
                needsReconciliation = true
                panelError = "The change could not be confirmed. Reload before trying again."
            }
            return
        }
        applyManagementResult(last.result, mutation: last.mutation, in: id)
        guard panelTarget == id, let failure = batch.failure else { return }
        let reason = switch failure {
        case let .refused(message): message
        case .unconfirmed: "The next change could not be confirmed. Reload before trying again."
        case .noRevision: "Reload to change the rest."
        }
        panelError = "\(Self.progress(batch.changed, of: mutations.count, mutations[0])) \(reason)"
    }

    /// "Changed 1 of 3 people.", or the words for removals and approvals.
    static func progress(_ done: Int, of total: Int, _ mutation: ConversationMutation) -> String {
        switch mutation {
        case .removePerson: "Removed \(done) of \(total) people."
        case .approveRequest: "Approved \(done) of \(total) requests."
        case .rejectRequest: "Declined \(done) of \(total) requests."
        default: "Changed \(done) of \(total) people."
        }
    }

    private func applyManagementResult(
        _ result: ConversationMutationResult,
        mutation: ConversationMutation,
        in id: Conversation.ID
    ) {
        guard result.isConfirmed else {
            guard panelTarget == id else { return }
            recoverMetadata(mutation, in: id, error: "The change could not be confirmed.")
            return
        }
        if [.leave, .deleteSpace, .declineInvitation, .block].contains(mutation) {
            closePanel()
        } else if details?.conversation.id == id {
            retainConfirmedRole(mutation, result: result)
            if let updated = result.details {
                details = updated
            }
            if !result.failedMembers.isEmpty {
                notice = "\(result.failedMembers.count) people could not be updated."
            }
            if result.details == nil || result.details?.membership == .joined {
                if mutation.editsMetadata, result.details != nil {
                    needsReconciliation = false
                    if case .settings = mutation {
                        refreshSettingsParticipants(id)
                    }
                } else {
                    openDetails(id)
                }
                reloadInfo(after: mutation)
            }
        }
        if page == "space" || page == "spaceSpam" {
            search(query, scope: scope)
        }
    }

    /// Reconcile an uncertain edit with a read, never another write. The form
    /// keeps its draft and error while fresh details unblock the next explicit Save.
    private func recoverMetadata(_ mutation: ConversationMutation, in id: Conversation.ID, error: String) {
        needsReconciliation = true
        if mutation.editsMetadata {
            openDetails(id)
        }
        panelError = error
    }
}

/// How a batch of people's changes went.
struct BatchOutcome {
    enum Failure: Equatable {
        case refused(String), unconfirmed, noRevision
    }

    var revision: String?
    var changed = 0
    var last: (result: ConversationMutationResult, mutation: ConversationMutation)?
    var failure: Failure?
    private(set) var revisionLost = false
    private var failedMembers: [Member.ID] = []

    /// Records an answer; returns whether the next change may follow.
    mutating func record(_ result: ConversationMutationResult, of mutation: ConversationMutation) -> Bool {
        guard result.isConfirmed else {
            failure = .unconfirmed
            return false
        }
        changed += 1
        failedMembers += result.failedMembers
        var merged = result
        merged.failedMembers = failedMembers
        last = (merged, mutation)
        if let next = result.details?.revision {
            revision = next
        } else if revision != nil {
            // The next write would have nothing current to check against.
            revisionLost = true
        }
        return true
    }
}

private extension ConversationMutation {
    var editsMetadata: Bool {
        switch self {
        case .settings, .details, .identity, .guidelines, .emoji: true
        default: false
        }
    }
}
