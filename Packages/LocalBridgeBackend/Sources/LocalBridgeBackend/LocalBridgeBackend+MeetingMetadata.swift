import ChatKit
import Foundation
import GChatBridgeCore

struct MeetingMetadataHydration {
    struct Key: Equatable, Sendable {
        let revision: Int64
        let title: String?
        let integrations: [SpaceIntegrationPayload]
    }

    struct Job: Sendable {
        let id: Conversation.ID
        let key: Key
    }

    struct Cached {
        let key: Key
        let meeting: MeetingOccurrence?
        let checkedAt: Date

        func isFresh(for candidate: Key, now: Date) -> Bool {
            let age = now.timeIntervalSince(checkedAt)
            // Ordinary message activity may advance the group revision without
            // changing any meeting metadata. Title/integration changes invalidate.
            return key.title == candidate.title && key.integrations == candidate.integrations &&
                age >= 0 && age < (meeting == nil ? 21600 : 86400)
        }
    }

    var targets: [Conversation.ID: Key] = [:]
    var cache: [Conversation.ID: Cached] = [:]
    var pending: [Job] = []
    var inFlight: [Conversation.ID: Key] = [:]
    var task: Task<Void, Never>?
    var loadedCache = false
    var loading = false
    var announcedEmpty: Set<Conversation.ID> = []
}

extension LocalBridgeBackend {
    /// List summaries may carry warning flags but omit the calendar payload.
    /// Enrich only visible meeting chats, at most six detail requests at a time.
    func hydrateMeetingMetadata(in conversations: [Conversation]) -> [Conversation] {
        let now = meetingMetadataNow()
        if !meetingMetadata.loadedCache {
            meetingMetadata.cache = meetingMetadataCacheFile?.load(now: now) ?? meetingMetadata.cache
            meetingMetadata.loadedCache = true
        }
        let eligible = conversations.filter { $0.kind == .meetChat }
        let ids = Set(eligible.map(\.id))
        meetingMetadata.cache = meetingMetadata.cache.filter { ids.contains($0.key) }
        meetingMetadata.announcedEmpty.formIntersection(ids)
        meetingMetadata.targets = [:]
        meetingMetadata.pending = []
        for conversation in eligible.sorted(by: {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }) {
            guard let item = conversationDetails[conversation.id] else { continue }
            let key = MeetingMetadataHydration.Key(
                revision: item.groupRevision.timestamp, title: conversation.title,
                integrations: item.spaceIntegrationPayloads
            )
            meetingMetadata.targets[conversation.id] = key
            if let meeting = conversation.meeting {
                meetingMetadata.cache[conversation.id] = .init(key: key, meeting: meeting, checkedAt: now)
            } else if meetingMetadata.cache[conversation.id]?.isFresh(for: key, now: now) != true,
                      meetingMetadata.inFlight[conversation.id] != key {
                meetingMetadata.pending.append(.init(id: conversation.id, key: key))
            }
        }
        replayCachedMeetingAbsences(in: ids)
        updateMeetingMetadataLoading()
        if !meetingMetadata.pending.isEmpty, meetingMetadata.task == nil {
            let generation = directoryGeneration
            meetingMetadata.task = Task { [weak self] in
                await self?.runMeetingMetadata(generation: generation)
            }
        }
        let result = conversations.map { conversation in
            var value = conversation
            if value.kind == .meetChat, value.meeting == nil {
                value.meeting = meetingMetadata.cache[value.id]?.meeting
            }
            return value
        }
        let known = result.count { $0.meeting != nil }
        let queued = meetingMetadata.pending.count
        diagnostics.record(.meetingMetadata(visible: eligible.count, ready: known, queued: queued))
        return result
    }

    private func replayCachedMeetingAbsences(in ids: Set<Conversation.ID>) {
        // A saved explicit absence must also clear an older replica value if
        // the process exited after saving the lookup but before reducing its event.
        for id in ids where meetingMetadata.cache[id]?.meeting == nil && meetingMetadata.cache[id] != nil {
            if meetingMetadata.announcedEmpty.insert(id).inserted {
                emit(.meetingMetadataChanged(conversationID: id, meeting: nil))
            }
        }
    }

    private func runMeetingMetadata(generation: Int) async {
        await withTaskGroup(of: Void.self) { group in
            func enqueue() {
                guard let job = nextMeetingMetadataJob(generation: generation) else { return }
                group.addTask { [weak self] in await self?.fetchMeetingMetadata(job, generation: generation) }
            }
            for _ in 0 ..< 6 {
                enqueue()
            }
            var completed = 0
            while await group.next() != nil {
                guard !Task.isCancelled, generation == directoryGeneration, isConnected else {
                    group.cancelAll()
                    continue
                }
                completed += 1
                if completed.isMultiple(of: 6) {
                    saveMeetingMetadataCache()
                }
                enqueue()
            }
        }
        if generation == directoryGeneration {
            saveMeetingMetadataCache()
            meetingMetadata.task = nil
            updateMeetingMetadataLoading()
        }
    }

    private func nextMeetingMetadataJob(generation: Int) -> MeetingMetadataHydration.Job? {
        guard !Task.isCancelled, generation == directoryGeneration, isConnected,
              let index = meetingMetadata.pending
              .firstIndex(where: { meetingMetadata.inFlight[$0.id] == nil })
        else { return nil }
        let job = meetingMetadata.pending.remove(at: index)
        meetingMetadata.inFlight[job.id] = job.key
        return job
    }

    func updateMeetingMetadataLoading() {
        let unresolved = meetingMetadata.pending.map(\.id) + Array(meetingMetadata.inFlight.keys)
        let loading = unresolved
            .contains { meetingMetadata.targets[$0] != nil && meetingMetadata.cache[$0] == nil }
        guard meetingMetadata.loading != loading else { return }
        meetingMetadata.loading = loading
        emit(.meetingMetadataLoadingChanged(isLoading: loading))
    }

    private func fetchMeetingMetadata(_ job: MeetingMetadataHydration.Job, generation: Int) async {
        defer {
            if generation == directoryGeneration {
                meetingMetadata.inFlight[job.id] = nil
                updateMeetingMetadataLoading()
            }
        }
        guard !Task.isCancelled, generation == directoryGeneration,
              meetingMetadata.targets[job.id] == job.key, isConnected,
              let client = apiClient, let group = ChannelEventMapping.groupID(for: job.id) else { return }
        do {
            let response = try await client.call(
                .managementDetails,
                ConversationManagementRequests.details(group)
            )
            guard !Task.isCancelled, generation == directoryGeneration, isConnected,
                  meetingMetadata.targets[job.id] == job.key, !hiddenConversations.contains(job.id),
                  response.hasGroup, response.group.groupID == group else { return }
            let meeting = MeetingMapping.occurrence(in: response.group.spaceIntegrationPayloads)
            meetingMetadata.cache[job.id] = .init(
                key: job.key,
                meeting: meeting,
                checkedAt: meetingMetadataNow()
            )
            if meeting == nil {
                meetingMetadata.announcedEmpty.insert(job.id)
            }
            emit(.meetingMetadataChanged(conversationID: job.id, meeting: meeting))
            diagnostics.record(.meetingDetail(supported: meeting != nil))
        } catch {
            guard !Task.isCancelled, generation == directoryGeneration else { return }
            diagnostics.record(.meetingDetailFailed)
        }
    }
}
