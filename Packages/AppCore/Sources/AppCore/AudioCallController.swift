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
    public internal(set) var interaction: CallInteractionState?
    public internal(set) var windowRequests = 0
    public internal(set) var listenerFailure: String?
    public private(set) var isAvailable = false
    public private(set) var isEnding = false
    public internal(set) var isUpdatingMute = false
    public private(set) var isRecovering = false
    /// Mirrors the service's own answer after each event, so views observe it.
    public internal(set) var supportsExistingJoin = false
    public internal(set) var supportsConversationCalls = false
    public internal(set) var supportsMeetingLinks = false
    public internal(set) var supportedMeetingLinkHosts: Set<String> = []
    /// Calls going on in the conversation on screen; stopped with this controller.
    public let discovery = CallDiscoveryMonitor()

    /// Read by `+Starting.swift`; written only here, from the service's events.
    var recipients: [Conversation.ID: AudioCallRecipient] = [:]
    @ObservationIgnored var service: (any AudioCallService)?
    @ObservationIgnored var generation = 0
    public internal(set) var breakoutReturnURL: URL?
    @ObservationIgnored var breakoutTaskToken: UUID?
    @ObservationIgnored var breakoutTask: Task<Void, any Error>?
    @ObservationIgnored var activityTask: Task<Void, any Error>?
    @ObservationIgnored var inviteTask: Task<Void, any Error>?
    @ObservationIgnored var interactionTask: Task<Void, Never>?
    public internal(set) var isUpdatingInteraction = false
    @ObservationIgnored var retiredIDs: Set<UUID> = []
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var listenerTask: Task<Void, Never>?
    @ObservationIgnored var operationTask: Task<Void, Never>?
    @ObservationIgnored var sourceTermination: AudioCallSession?
    @ObservationIgnored var endingSnapshot: AudioCallSession?
    @ObservationIgnored var endingTask: Task<Void, Never>?
    @ObservationIgnored var muteTask: Task<Void, Never>?
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
        interactionTask?.cancel()
        stopActivityWork()
        interactionTask = nil
        isUpdatingInteraction = false
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
        supportsMeetingLinks = false
        supportedMeetingLinkHosts = []
        listenerFailure = nil
        operationFailure = nil
        call = nil
        participants = nil
        interaction = nil
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
                let message = Self.failureMessage(for: error, call: call)
                call?.phase = .failed
                call?.failureMessage = message
                retiredIDs.insert(id)
                participants = nil
                interaction = nil
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
        interaction = nil
        isEnding = true
        operationTask?.cancel()
        muteTask?.cancel()
        interactionTask?.cancel()
        activityTask?.cancel()
        activityTask = nil
        inviteTask?.cancel()
        inviteTask = nil
        interactionTask = nil
        isUpdatingInteraction = false
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
        interaction = nil
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
    private static func failureMessage(for error: any Error, call: AudioCallSession?) -> String {
        if error as? ServiceFailure == .deviceBusy {
            return "Another call is already using this device."
        }
        if (error as? ServiceFailure)?.code == "invalidRequest",
           case let .conversation(target) = call?.target, target.meetingURL != nil {
            return "This meeting link isn’t supported. Copy the meeting’s direct link and try again."
        }
        if call?.isJoining == true {
            return "The call couldn’t be joined. It may have ended."
        }
        return "The call could not connect."
    }

    func recordHandoffFailure(id: UUID) {
        guard call?.id == id, call?.phase == .incoming else { return }
        call?.failureMessage = "Couldn’t end the other call."
    }
}
