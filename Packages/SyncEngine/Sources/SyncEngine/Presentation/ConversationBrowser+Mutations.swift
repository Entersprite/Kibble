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
                needsReconciliation = true
                panelError = Self.message(error)
            }
        }
    }

    private func applyManagementResult(
        _ result: ConversationMutationResult,
        mutation: ConversationMutation,
        in id: Conversation.ID
    ) {
        guard result.isConfirmed else {
            needsReconciliation = true
            panelError = "The change could not be confirmed. Reload before trying again."
            return
        }
        if [.leave, .deleteSpace, .declineInvitation, .block].contains(mutation) {
            closePanel()
        } else if details?.conversation.id == id {
            if let updated = result.details {
                details = updated
            }
            if !result.failedMembers.isEmpty {
                notice = "\(result.failedMembers.count) people could not be updated."
            }
            if result.details == nil || result.details?.membership == .joined {
                openDetails(id)
                reloadInfo(after: mutation)
            }
        }
        if page == "space" || page == "spaceSpam" {
            search(query, scope: scope)
        }
    }
}
