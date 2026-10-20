import ChatAPI
import ChatKit
import Foundation
import Observation

/// Owns one call for the client session, independently of chat window selection.
@MainActor
@Observable
public final class AudioCallController {
    public private(set) var call: AudioCallSnapshot?
    public private(set) var windowRequests = 0
    public private(set) var listenerFailure: String?
    public private(set) var isAvailable = false
    public private(set) var isEnding = false
    public private(set) var isUpdatingMute = false
    public private(set) var isRecovering = false

    private var recipients: [Conversation.ID: AudioCallRecipient] = [:]
    @ObservationIgnored private var service: (any AudioCallService)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retiredIDs: Set<UUID> = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var endingSnapshot: AudioCallSnapshot?
    @ObservationIgnored var endingTask: Task<Void, Never>?
    @ObservationIgnored private var muteTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var muteRevision = 0
    @ObservationIgnored private var directoryTask: Task<Void, Never>?
    @ObservationIgnored private var directorySource: (@MainActor () -> [AudioCallRecipient])?
    @ObservationIgnored var operationFailure: CallOperationFailure?

    public init() {}

    /// The previous service must be stopped before installing a replacement.
    public func start(
        service: (any AudioCallService)?,
        directory: (@MainActor () -> [AudioCallRecipient])? = nil
    ) {
        guard self.service == nil, stopTask == nil, let service else { return }
        generation += 1
        muteRevision += 1
        let scope = generation
        self.service = service
        directorySource = directory
        followDirectory(service: service, scope: scope)
        isAvailable = true
        eventTask = Task { [weak self] in
            for await event in service.events {
                guard let self, !Task.isCancelled, generation == scope else { return }
                if !isRecovering {
                    receive(event)
                }
            }
        }
        listen(service: service, scope: scope)
    }

    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        generation += 1
        isRecovering = false
        directoryTask?.cancel()
        directoryTask = nil
        directorySource = nil
        let oldService = service
        service = nil
        eventTask?.cancel()
        listenerTask?.cancel()
        operationTask?.cancel()
        muteTask?.cancel()
        endingTask?.cancel()
        eventTask = nil
        listenerTask = nil
        operationTask = nil
        muteTask = nil
        endingTask = nil
        recipients = [:]
        retiredIDs = []
        endingSnapshot = nil
        isAvailable = false
        isEnding = false
        isUpdatingMute = false
        listenerFailure = nil
        operationFailure = nil
        call = nil
        let cleanup = Task {
            if let oldService {
                await oldService.stop()
            }
        }
        stopTask = cleanup
        await cleanup.value
        stopTask = nil
    }

    private func followDirectory(service: any AudioCallService, scope: Int) {
        guard let directorySource else { return }
        directoryTask = Task { [weak self] in
            var previous: [AudioCallRecipient]?
            for await recipients in Observations(directorySource) {
                guard !Task.isCancelled, self?.generation == scope else { return }
                guard recipients != previous else { continue }
                await service.updateRecipients(recipients)
                previous = recipients
            }
        }
    }

    private func listen(service: any AudioCallService, scope: Int) {
        listenerTask = Task { [weak self] in
            guard self?.generation == scope, !Task.isCancelled else { return }
            do {
                try await service.startListening()
            } catch {
                guard let self, !Task.isCancelled, generation == scope else { return }
                listenerFailure = "Incoming calls are unavailable."
            }
        }
    }

    public func canCall(conversation: Conversation, members: [Member], me: Member.ID?) -> Bool {
        guard let recipient = eligibleRecipient(in: conversation, me: me) else { return false }
        return members.first(where: { $0.id == recipient })?.kind == .human
    }

    /// Scene projection already has a keyed directory; avoid copying and
    /// scanning every member for each conversation on every UI update.
    public func canCall(
        conversation: Conversation, directory: [Member.ID: Member], me: Member.ID?
    ) -> Bool {
        guard let recipient = eligibleRecipient(in: conversation, me: me) else { return false }
        return directory[recipient]?.kind == .human
    }

    private func eligibleRecipient(in conversation: Conversation, me: Member.ID?) -> Member.ID? {
        guard isAvailable, !isRecovering, conversation.kind == .directMessage,
              let me, let recipient = recipients[conversation.id],
              Set(conversation.members) == Set([me, recipient.memberID]), me != recipient.memberID
        else { return nil }
        return recipient.memberID
    }

    /// Returns the new call's ID, or nil when no call started: one is already
    /// going on, and its window was raised instead, or this conversation
    /// cannot be called.
    @discardableResult
    public func startCall(in conversation: Conversation, members: [Member], me: Member.ID?) -> UUID? {
        if isEnding || call.map({ !$0.phase.isTerminal }) == true {
            windowRequests += 1
            return nil
        }
        guard canCall(conversation: conversation, members: members, me: me),
              let service, let recipient = recipients[conversation.id] else { return nil }
        let snapshot = AudioCallSnapshot(
            id: UUID(), recipient: recipient, direction: .outgoing, phase: .connecting
        )
        call = snapshot
        windowRequests += 1
        runOperation(id: snapshot.id) { try await service.startOutgoing(to: recipient, callID: snapshot.id) }
        return snapshot.id
    }

    public func accept() {
        guard let call, call.phase == .incoming, !isEnding, let service else { return }
        self.call?.phase = .connecting
        self.call?.failureMessage = nil
        runOperation(id: call.id, restoring: call) { try await service.accept(callID: call.id) }
    }

    public func decline() {
        guard call?.phase == .incoming else { return }
        finish(decline: true)
    }

    public func hangUp() {
        finish(decline: false)
    }

    public func windowClosed() {
        guard let call, !call.phase.isTerminal else { return }
        finish(decline: call.phase == .incoming)
    }

    public func toggleMute() {
        guard let call, !call.phase.isTerminal, call.phase != .incoming,
              !isEnding, let service else { return }
        let scope = generation
        let muted = !call.isMuted
        muteRevision += 1
        let revision = muteRevision
        self.call?.isMuted = muted
        isUpdatingMute = true
        muteTask = Task { [weak self] in
            guard self?.generation == scope, !Task.isCancelled else { return }
            do {
                try await service.setMuted(muted, callID: call.id)
                guard let self, generation == scope, self.call?.id == call.id,
                      muteRevision == revision, self.call?.phase.isTerminal == false,
                      !Task.isCancelled else { return }
                isUpdatingMute = false
            } catch {
                guard let self, generation == scope, self.call?.id == call.id,
                      muteRevision == revision, self.call?.phase.isTerminal == false,
                      !Task.isCancelled else { return }
                self.call?.isMuted = call.isMuted
                self.call?.failureMessage = "Microphone state could not be confirmed."
                isUpdatingMute = false
            }
        }
    }

    private func receive(_ event: AudioCallEvent) {
        switch event {
        case let .recipientsChanged(values):
            recipients = values.reduce(into: [:]) { $0[$1.conversationID] = $1 }
        case let .listenerChanged(isListening):
            listenerFailure = isListening ? nil : "Incoming calls are unavailable."
        case let .snapshot(snapshot): receiveSnapshot(snapshot)
        case .unknown, .listenerBarrier: break
        }
    }

    private func receiveSnapshot(_ snapshot: AudioCallSnapshot) {
        if receiveTerminalSnapshot(snapshot) {
            return
        }
        guard !retiredIDs.contains(snapshot.id) else { return }
        if call?.id == snapshot.id {
            guard call?.phase.isTerminal == false, !isEnding else { return }
            call = snapshot
            if snapshot.phase.isTerminal {
                retiredIDs.insert(snapshot.id)
                operationTask?.cancel()
                muteTask?.cancel()
                isUpdatingMute = false
            }
        } else if snapshot.direction == .incoming, snapshot.phase == .incoming,
                  call == nil || call?.phase.isTerminal == true, !isEnding {
            call = snapshot
            windowRequests += 1
        }
    }

    private func receiveTerminalSnapshot(_ snapshot: AudioCallSnapshot) -> Bool {
        guard call?.id == snapshot.id, snapshot.phase.isTerminal else { return false }
        if isEnding {
            endingSnapshot = snapshot
            return true
        }
        // Terminal information can arrive after the awaited operation returns.
        // Refining the same terminal phase cannot reactivate a retired call.
        guard call?.phase == snapshot.phase else { return false }
        call = snapshot
        return true
    }

    private func runOperation(
        id: UUID,
        restoring incoming: AudioCallSnapshot? = nil,
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let scope = generation
        operationTask?.cancel()
        operationTask = Task { [weak self] in
            guard self?.generation == scope, !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                guard let self, generation == scope, call?.id == id,
                      call?.phase.isTerminal == false, !Task.isCancelled else { return }
                operationFailure = CallOperationFailure(id: id, error: error)
                if error as? ServiceFailure == .deviceBusy, let incoming, call?.phase == .connecting {
                    call = incoming
                    call?.failureMessage = "Another call is already using this device."
                    return
                }
                call?.phase = .failed
                call?.failureMessage = "The call could not connect."
                retiredIDs.insert(id)
                // The service owns cleanup on failed connection operations.
            }
        }
    }

    private func finish(decline: Bool) {
        guard let call, !call.phase.isTerminal, !isEnding, let service else { return }
        let scope = generation
        retiredIDs.insert(call.id)
        endingSnapshot = nil
        self.call?.phase = .ended
        self.call?.failureMessage = nil
        isEnding = true
        operationTask?.cancel()
        muteTask?.cancel()
        isUpdatingMute = false
        endingTask = Task { [weak self] in
            guard self?.generation == scope, !Task.isCancelled else { return }
            do {
                if decline {
                    try await service.decline(callID: call.id)
                } else {
                    try await service.hangUp(callID: call.id)
                }
                guard let self, generation == scope, self.call?.id == call.id else { return }
                if let endingSnapshot {
                    self.call = endingSnapshot
                } else {
                    self.call?.phase = decline ? .declined : .ended
                }
                isEnding = false
            } catch {
                guard let self, generation == scope, self.call?.id == call.id else { return }
                if let endingSnapshot {
                    self.call = endingSnapshot
                } else {
                    self.call?.phase = .failed
                    self.call?.failureMessage = decline
                        ? "Decline could not be confirmed." : "Call cleanup failed."
                }
                isEnding = false
            }
        }
    }
}

public extension AudioCallController {
    var canRecover: Bool {
        isAvailable && !isEnding && !isRecovering && call?.phase.isTerminal != false
    }

    /// Pauses only calls while the host repairs authentication. Account teardown
    /// invalidates the restart even if the host operation finishes late.
    func recover(using repair: @MainActor () async -> Bool) async {
        guard canRecover, let previous = service else { return }
        let scope = generation
        isRecovering = true
        recipients = [:]
        call = nil
        listenerTask?.cancel()
        directoryTask?.cancel()
        do {
            try await previous.prepareRecovery()
        } catch {
            guard generation == scope, !Task.isCancelled else { return }
            isRecovering = false
            listenerFailure = "Call recovery could not start."
            return
        }
        guard generation == scope, !Task.isCancelled else { return }
        let mayRestart = await repair()
        guard generation == scope, !Task.isCancelled else { return }
        if mayRestart {
            do {
                try await previous.finishRecovery()
            } catch {
                guard generation == scope, !Task.isCancelled else { return }
                isRecovering = false
                listenerFailure = "Incoming calls could not restart."
                return
            }
        }
        guard generation == scope, !Task.isCancelled else { return }
        isRecovering = false
        if mayRestart {
            followDirectory(service: previous, scope: scope)
            listen(service: previous, scope: scope)
        }
    }
}
