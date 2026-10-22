import ChatKit
import ChatPersistence
import Foundation

extension ChatSessionModel {
    func markSelectedReadIfNeeded() {
        // A row from the saved copy may since have been edited, deleted or
        // read elsewhere; nothing is marked read until the newest page confirms.
        guard unconfirmedMessageIDs.isEmpty else { return }
        if selectedMeetingSeries != nil {
            markVisibleMeetingMessagesRead()
        } else {
            markSingleConversationReadIfNeeded()
        }
    }

    /// Grouping never turns opening one series into a bulk read operation.
    /// Each mark covers only server messages actually reported by the viewport.
    func markVisibleMeetingMessagesRead() {
        guard isActive, capabilities.canMarkRead, unconfirmedMessageIDs.isEmpty,
              let series = meetingSeries else { return }
        let allowed = Set(series.occurrences.map(\.id))
        let viewed = messages.filter {
            allowed.contains($0.conversationID) && meetingWork.visible.contains($0.id) &&
                !$0.id.rawValue.hasPrefix("local/")
        }
        for (conversation, items) in Dictionary(grouping: viewed, by: \.conversationID) {
            guard let position = items.map(\.createdAt).max(),
                  !unreadHolds.contains(conversation), conversationActionTasks[conversation] == nil,
                  markTasks[conversation] == nil,
                  (published[conversation].map { position > $0 } ?? true) || isManuallyUnread(conversation),
                  !skipsBehindServerPosition(position, in: conversation) else { continue }
            let generation = (markGeneration[conversation] ?? 0) + 1
            markGeneration[conversation] = generation
            markTasks[conversation] = Task { @MainActor [weak self, debounce = markReadDebounce] in
                defer { self?.clearMarkTask(for: conversation, ifStillGeneration: generation) }
                do { try await Task.sleep(for: debounce) } catch { return }
                guard !Task.isCancelled, let self, isActive, capabilities.canMarkRead,
                      !unreadHolds.contains(conversation), conversationActionTasks[conversation] == nil,
                      conversations.contains(where: { $0.id == conversation }),
                      !skipsBehindServerPosition(position, in: conversation, generation: generation)
                else { return }
                let accepted = await engine.submit(.markRead(
                    conversationID: conversation,
                    upTo: readPositionClearingUnreadMark(position, in: conversation)
                ))
                guard !Task.isCancelled, markGeneration[conversation] == generation else { return }
                if accepted {
                    published[conversation] = position
                }
                clearMarkTask(for: conversation, ifStillGeneration: generation)
                if accepted, messages.contains(where: {
                    $0.conversationID == conversation && meetingWork.visible.contains($0.id) &&
                        !$0.id.rawValue.hasPrefix("local/") && $0.createdAt > position
                }) {
                    markVisibleMeetingMessagesRead()
                }
            }
        }
    }
}
