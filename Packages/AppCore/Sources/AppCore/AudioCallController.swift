import ChatAPI
import ChatKit
import Foundation
import Observation

/// Owns one call for the client session, independently of chat window selection:
/// a call to one person, or a call in a group or space. Either kind shares the
/// one service, its device lease and these controls.
@MainActor
@Observable
public final class AudioCallController {
    public internal(set) var call: AudioCallSession?
    /// The current call's devices as the provider reports them, nil while the
    /// roster is not established. One person can have several devices, and a
    /// presentation is a device of its own (`parentID`).
    public internal(set) var participants: [CallParticipantDevice]?
    public internal(set) var windowRequests = 0
    public private(set) var listenerFailure: String?
    public private(set) var isAvailable = false
    public private(set) var isEnding = false
    public private(set) var isUpdatingMute = false
    public private(set) var isRecovering = false
    /// Mirrors the service's own answer after each event, so views observe it.
    public private(set) var supportsExistingJoin = false
    public private(set) var supportsConversationCalls = false
    /// Calls going on in the conversation on screen; stopped with this controller.
    public let discovery = CallDiscoveryMonitor()

    /// Read by `+Starting.swift`; written only here, from the service's events.
    var recipients: [Conversation.ID: AudioCallRecipient] = [:]
    @ObservationIgnored var service: (any AudioCallService)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retiredIDs: Set<UUID> = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var endingSnapshot: AudioCallSession?
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
        refreshSupport()
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
        discovery.stop()
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
        supportsExistingJoin = false
        supportsConversationCalls = false
        listenerFailure = nil
        operationFailure = nil
        call = nil
        participants = nil
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
                guard let self, !Task.isCancelled, generation == scope else { return }
                refreshSupport()
            } catch {
                guard let self, !Task.isCancelled, generation == scope else { return }
                listenerFailure = "Incoming calls are unavailable."
            }
        }
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
        case let .snapshot(snapshot):
            receiveSnapshot(AudioCallSession(snapshot, isJoining: joining(snapshot.id)))
        case let .conversationSnapshot(snapshot):
            receiveSnapshot(AudioCallSession(snapshot, isJoining: joining(snapshot.id)))
        case let .participantsChanged(callID, devices):
            guard call?.id == callID, call?.phase.isTerminal == false, !retiredIDs.contains(callID)
            else { break }
            participants = devices
        case .unknown, .listenerBarrier: break
        }
        refreshSupport()
    }

    private func joining(_ id: UUID) -> Bool {
        call?.id == id && call?.isJoining == true
    }

    private func refreshSupport() {
        let join = existingJoinService?.canJoinExistingCalls ?? false
        let conversations = conversationService?.canCallConversations ?? false
        if supportsExistingJoin != join {
            supportsExistingJoin = join
        }
        if supportsConversationCalls != conversations {
            supportsConversationCalls = conversations
        }
    }

    private func receiveSnapshot(_ snapshot: AudioCallSession) {
        if receiveTerminalSnapshot(snapshot) {
            return
        }
        guard !retiredIDs.contains(snapshot.id) else { return }
        if call?.id == snapshot.id {
            guard call?.phase.isTerminal == false, !isEnding else { return }
            call = snapshot
            if snapshot.phase.isTerminal {
                retire(snapshot.id)
            }
        } else if snapshot.recipient != nil, snapshot.direction == .incoming, snapshot.phase == .incoming,
                  call == nil || call?.phase.isTerminal == true, !isEnding {
            call = snapshot
            participants = nil
            windowRequests += 1
        }
    }

    private func receiveTerminalSnapshot(_ snapshot: AudioCallSession) -> Bool {
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

    /// A finished call keeps no roster: nobody shown is still in it.
    private func retire(_ id: UUID) {
        retiredIDs.insert(id)
        operationTask?.cancel()
        muteTask?.cancel()
        isUpdatingMute = false
        participants = nil
    }

    func runOperation(
        id: UUID,
        restoring incoming: AudioCallSession? = nil,
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
                let message = Self.failureMessage(for: error, joining: call?.isJoining == true)
                call?.phase = .failed
                call?.failureMessage = message
                retiredIDs.insert(id)
                participants = nil
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
        participants = nil
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
        participants = nil
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

extension AudioCallController {
    /// Fixed copy for a refused start or join; the error's own text never shows.
    private static func failureMessage(for error: any Error, joining: Bool) -> String {
        if error as? ServiceFailure == .deviceBusy {
            return "Another call is already using this device."
        }
        return joining ? "The call couldn’t be joined. It may have ended." : "The call could not connect."
    }

    func recordHandoffFailure(id: UUID) {
        guard call?.id == id, call?.phase == .incoming else { return }
        call?.failureMessage = "Couldn’t end the other call."
    }
}
