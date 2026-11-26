import ChatKit
import Foundation

public extension ChatSessionModel {
    func showScheduledMessages() {
        guard capabilities.canScheduleMessages, !schedules.showingList else { return }
        clearSelection()
        schedules.showingList = true
        refreshScheduledMessages()
    }

    func refreshScheduledMessages() {
        guard schedules.showingList, schedules.pending.isEmpty else { return }
        loadScheduledMessages(after: nil)
    }

    func loadMoreScheduledMessages() {
        guard schedules.showingList, schedules.pending.isEmpty, !schedules.isLoading,
              let cursor = schedules.cursor else { return }
        loadScheduledMessages(after: cursor)
    }

    @discardableResult
    func scheduleMessage(
        _ body: ComposedMessage, draft: ComposedMessage, at time: Date, to destination: MessageAddress,
        prepareDraft: @escaping @MainActor () async throws -> SyncedDraft? = { nil },
        finishDraft: @escaping @MainActor (SyncedDraft?) -> Void = { _ in },
        confirmed: @escaping @MainActor () -> Void
    ) -> Bool {
        let key = StagingKey(conversation: destination.conversation, thread: destination.thread)
        let staged = composerFiles.staged[key] ?? []
        guard capabilities.canScheduleMessages, isClientTransportAvailable,
              selected == destination.conversation, destination.message == nil,
              destination.thread == nil || threads.openThread == destination.thread,
              staged.isEmpty || capabilities.canScheduleAttachments && staged.allSatisfy({ !$0.isUploading }),
              schedules.submissions.insert(destination).inserted else { return false }
        let batch = reserveStagedFiles(in: key)
        schedules.creates[destination] = Task { [weak self, engine] in
            guard let self else { return }
            var converted: SyncedDraft?
            var accepted = false
            defer {
                if !accepted, !Task.isCancelled {
                    restoreStagedFiles(batch, in: key)
                }
                finishDraft(converted)
                schedules.creates[destination] = nil
                schedules.submissions.remove(destination)
            }
            do {
                let outside = await nonMembers(in: body, conversation: destination.conversation)
                let deliver = body.forScheduledDelivery(withoutAdding: Set(outside.people))
                try Task.checkCancellation()
                var uploads: [Attachment] = []
                for item in batch {
                    let uploaded = try await uploadStagedFile(item.attachment, in: key)
                    uploads.append(uploaded)
                }
                let baseline = try await prepareDraft()
                _ = try await engine.changeSchedule(
                    .create(destination, deliver, time, converting: baseline, attachments: uploads)
                )
                converted = baseline
                guard !Task.isCancelled else { return }
                accepted = true
                removeStagedFiles(batch, in: key)
                schedules.receipts[destination] = .init(id: UUID(), body: draft)
                confirmed()
                refreshScheduledMessages()
            } catch where !Task.isCancelled {
                lastError =
                    .unknown("Scheduling could not be confirmed. Check Scheduled before trying again.")
            } catch {}
        }
        return true
    }

    func editScheduledMessage(
        _ address: ScheduledMessageAddress, body: ComposedMessage,
        finished: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        changeScheduledMessage(address, change: .edit(address, body), finished: finished)
    }

    func rescheduleMessage(
        _ address: ScheduledMessageAddress, at time: Date, finished: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        changeScheduledMessage(address, change: .move(address, time), finished: finished)
    }

    func cancelScheduledMessage(_ address: ScheduledMessageAddress) {
        _ = changeScheduledMessage(address, change: .cancel(address)) { _ in }
    }

    func sendScheduledMessageNow(_ address: ScheduledMessageAddress) {
        guard capabilities.canSendScheduledMessagesNow else { return }
        _ = changeScheduledMessage(address, change: .sendNow(address)) { _ in }
    }
}

extension ChatSessionModel {
    func invalidateScheduledMessages() {
        guard capabilities.canScheduleMessages, schedules.showingList else { return }
        if schedules.isLoading {
            schedules.refreshAfterLoad = true
        } else {
            refreshScheduledMessages()
        }
    }
}

private extension ChatSessionModel {
    func loadScheduledMessages(after cursor: String?) {
        schedules.cancelLoad()
        let id = schedules.loadID
        schedules.isLoading = true
        schedules.readFailed = false
        schedules.load = Task { [weak self, engine] in
            let page = try? await engine.scheduledPage(after: cursor)
            guard let self, !Task.isCancelled, schedules.loadID == id, schedules.showingList else { return }
            schedules.load = nil
            schedules.isLoading = false
            if schedules.refreshAfterLoad {
                refreshScheduledMessages()
                return
            }
            guard let page else {
                schedules.readFailed = true
                return
            }
            if cursor == nil {
                schedules.messages = []
            }
            var seen = Set(schedules.messages.map(\.id))
            schedules.messages += page.messages.filter { seen.insert($0.id).inserted }
            schedules.cursor = page.nextCursor
        }
    }

    func changeScheduledMessage(
        _ address: ScheduledMessageAddress, change: ScheduleChange,
        finished: @escaping @MainActor (Bool) -> Void
    ) -> Bool {
        guard capabilities.canScheduleMessages, isClientTransportAvailable,
              schedules.pending.insert(address).inserted else { return false }
        schedules.cancelLoad()
        schedules.writes[address] = Task { [weak self, engine] in
            let result: Result<ScheduledMessage?, any Error>
            do {
                result = try await .success(engine.changeSchedule(change))
            } catch {
                result = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            schedules.writes[address] = nil
            schedules.pending.remove(address)
            switch result {
            case let .success(message):
                if let index = schedules.messages.firstIndex(where: { $0.id == address }) {
                    if let message {
                        schedules.messages[index] = message
                    } else {
                        schedules.messages.remove(at: index)
                    }
                }
                finished(true)
            case .failure:
                lastError = .unknown("The scheduled message change could not be confirmed.")
                finished(false)
            }
            refreshScheduledMessages()
        }
        return true
    }
}

private extension ComposedMessage {
    func forScheduledDelivery(withoutAdding people: Set<Member.ID>) -> ComposedMessage {
        var message = self
        for index in message.mentions.indices {
            if case let .user(id) = message.mentions[index].target, people.contains(id) {
                message.mentions[index].mode = .withoutAdding
            }
        }
        return message
    }
}
