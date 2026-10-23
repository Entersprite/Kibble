import ChatAPI
import ChatKit
import Foundation

/// Complete call snapshots can race command replies; older positions cannot rewind state.
struct ServiceCallStateProjection {
    private var previous: ServiceCallState?
    private var retiredStreams: Set<String> = []
    private var connectionUnavailable = false
    var isConnectionUnavailable: Bool {
        connectionUnavailable
    }

    var version: String? {
        previous?.version
    }

    var currentState: ServiceCallState? {
        previous
    }

    mutating func accept(_ state: ServiceCallState) throws -> [AudioCallEvent] {
        guard state.call == nil || state.conversationCall == nil else { throw ServiceFailure.invalidResponse }
        let admission = try admit(state)
        guard admission.accepted else { return restoreConnection(after: []) }
        var events = admission.events
        // Reads carry complete state. An end and the following ring can occur
        // between reads, so retire the superseded presentation before the new one.
        if var call = previous?.call, !call.phase.isTerminal, call.id != state.call?.id {
            call.phase = .ended
            call.failureMessage = nil
            call.endReason = nil
            events.append(.snapshot(call))
        }
        if var call = previous?.conversationCall, !call.phase.isTerminal,
           call.id != state.conversationCall?.id {
            call.phase = .ended
            call.failureMessage = nil
            call.endReason = nil
            events.append(.conversationSnapshot(call))
        }
        if let call = state.conversationCall, previous?.conversationCall != call {
            events.append(.conversationSnapshot(call))
        }
        if previous?.recipients != state.recipients {
            events.append(.recipientsChanged(state.recipients))
        }
        if !state.isListenerStarting,
           previous?.isListening != state.isListening || previous?.isListenerStarting == true {
            events.append(.listenerChanged(isListening: state.isListening))
        }
        if let call = state.call, previous?.call != call {
            events.append(.snapshot(call))
        }
        if let id = state.currentCallID, state.currentPhase?.isTerminal == false,
           previous?.participants != state.participants {
            events.append(.participantsChanged(callID: id, participants: state.participants))
        }
        if case .unknown = state.lastEvent, let event = state.lastEvent {
            events.append(event)
        }
        previous = state
        return restoreConnection(after: events)
    }

    mutating func connectionFailed() -> [AudioCallEvent] {
        guard !connectionUnavailable else { return [] }
        connectionUnavailable = true
        return [.listenerChanged(isListening: false)]
    }

    private mutating func restoreConnection(after events: [AudioCallEvent]) -> [AudioCallEvent] {
        guard connectionUnavailable else { return events }
        connectionUnavailable = false
        let includesListener = events.contains {
            switch $0 {
            case .listenerChanged: true
            default: false
            }
        }
        guard let previous, !previous.isListenerStarting, !includesListener else { return events }
        return events + [.listenerChanged(isListening: previous.isListening)]
    }

    private mutating func admit(_ state: ServiceCallState) throws
        -> (accepted: Bool, events: [AudioCallEvent]) {
        let position = try callPosition(state.version)
        guard let previous else { return (true, []) }
        let old = try callPosition(previous.version)
        if old.stream == position.stream {
            guard position.sequence >= old.sequence else { return (false, []) }
            if previous.version == state.version {
                guard previous == state else { throw ServiceFailure.invalidResponse }
                return (false, [])
            }
            return (true, [])
        }
        guard !retiredStreams.contains(position.stream) else { return (false, []) }
        guard retiredStreams.count < 64 else { throw ServiceFailure.overloaded }
        retiredStreams.insert(old.stream)
        self.previous = nil
        if var call = previous.call, !call.phase.isTerminal {
            call.phase = .failed; call.failureMessage = "The call connection ended."
            return (true, [.snapshot(call)])
        }
        if var call = previous.conversationCall, !call.phase.isTerminal {
            call.phase = .failed
            call.failureMessage = "The call connection ended."
            return (true, [.conversationSnapshot(call)])
        }
        return (true, [])
    }

    private func callPosition(_ version: String) throws -> (stream: String, sequence: UInt64) {
        let parts = version.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
              let sequence = UInt64(parts[1]), String(sequence) == parts[1] else {
            throw ServiceFailure.invalidResponse
        }
        return (String(parts[0]), sequence)
    }
}
