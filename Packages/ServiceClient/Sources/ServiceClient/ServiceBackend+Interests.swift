import ChatAPI
import ChatKit
import Foundation

struct ClientHintIntent: Sendable {
    let sequence: UInt64
    let command: ChatCommand
}

struct ClientAttachmentOpening: Sendable {
    let id: UUID
    let generation: UUID
    let task: Task<ClientAttachment, any Error>
}

struct ClientDesiredInterests: Sendable {
    var sequence: UInt64 = 0
    var presence: ClientHintIntent?
    var conversation: ClientHintIntent?
    var activity: ClientHintIntent?
    var members: [Conversation.ID: ClientHintIntent] = [:]

    mutating func remember(_ command: ChatCommand) throws -> ClientHintIntent {
        guard sequence < UInt64.max else { throw ServiceFailure.overloaded }
        sequence += 1
        let intent = ClientHintIntent(sequence: sequence, command: command)
        switch command {
        case let .watchPresence(ids):
            guard ids.count <= 512 else { throw ServiceFailure.overloaded }
            presence = intent
        case .watchConversationActivity: conversation = intent
        case .reportActivity: activity = intent
        case let .loadMembers(id):
            guard members[id] != nil || members.count < 64 else { throw ServiceFailure.overloaded }
            members[id] = intent
        default: break
        }
        return intent
    }

    var replay: [ClientHintIntent] {
        [presence, conversation, activity].compactMap(\.self) + Array(members.values)
    }
}

extension ServiceBackend {
    func sendClientHint(_ command: ChatCommand) async throws {
        let intent = try desiredInterests.remember(command)
        // Current hints may be lost while detached. Only safe receive/device
        // intent and pending member discovery are replayed; typing never is.
        guard consumer != nil || connecting else { return }
        let generation = connectionGeneration
        let attached = try await openClientAttachment(generation: generation)
        try await sendClientIntent(intent, attachment: attached.id, generation: generation)
    }

    func openClientAttachment(generation: UUID) async throws -> ClientAttachment {
        guard generation == connectionGeneration else { throw CancellationError() }
        if let attachment, attachment.expiresAt.timeIntervalSinceNow > 0 {
            return attachment
        }
        attachment = nil
        let opening: ClientAttachmentOpening
        if let current = attachmentOpening, current.generation == generation {
            opening = current
        } else {
            guard attachmentGeneration < UInt64.max else { throw ServiceFailure.overloaded }
            attachmentGeneration += 1
            let revision = attachmentGeneration
            opening = ClientAttachmentOpening(id: UUID(), generation: generation, task: Task {
                try await self.call(AttachAccountClient(generation: String(revision)), timeout: 5)
            })
            attachmentOpening = opening
        }
        do {
            let result = try await opening.task.value
            guard generation == connectionGeneration else {
                _ = try? await call(DetachAccountClient(attachmentID: result.id), timeout: 5)
                throw CancellationError()
            }
            try Task.checkCancellation()
            attachment = result
            if attachmentOpening?.id == opening.id {
                attachmentOpening = nil
            }
            return result
        } catch {
            if attachmentOpening?.id == opening.id, !Task.isCancelled {
                attachmentOpening = nil
            }
            throw error
        }
    }

    func startAttachmentRenewal(generation: UUID) {
        attachmentRenewal?.cancel()
        attachmentRenewal = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self else { return }
                await renewClientAttachment(generation: generation)
            }
        }
    }

    private func renewClientAttachment(generation: UUID) async {
        guard generation == connectionGeneration, let current = attachment else { return }
        do {
            let renewed = try await call(
                AttachAccountClient(generation: String(attachmentGeneration)),
                timeout: 5
            )
            guard generation == connectionGeneration, attachment?.id == current.id else { return }
            guard renewed.id == current.id else { throw ServiceFailure.invalidResponse }
            attachment = renewed
        } catch {
            if generation == connectionGeneration, attachment?.id == current.id {
                attachment = nil
            }
        }
    }

    func restoreClientInterests(attachment: ClientAttachmentID, generation: UUID) {
        interestRestoration?.cancel()
        let intents = desiredInterests.replay
        interestRestoration = Task { [weak self] in
            for intent in intents {
                guard !Task.isCancelled, let self else { return }
                try? await sendClientIntent(intent, attachment: attachment, generation: generation)
            }
        }
    }

    private func sendClientIntent(
        _ intent: ClientHintIntent, attachment: ClientAttachmentID, generation: UUID
    ) async throws {
        try Task.checkCancellation()
        guard generation == connectionGeneration,
              self.attachment?.id == attachment else { throw CancellationError() }
        do {
            _ = try await call(SendHint(
                command: intent.command, attachmentID: attachment, sequence: String(intent.sequence)
            ), timeout: 10)
            if generation == connectionGeneration, case let .loadMembers(id) = intent.command,
               desiredInterests.members[id]?.sequence == intent
               .sequence {
                desiredInterests.members[id] = nil
            }
        } catch {
            if error as? ServiceFailure == .clientAttachmentExpired,
               generation == connectionGeneration, self.attachment?.id == attachment {
                self.attachment = nil
            }
            throw error
        }
    }
}
