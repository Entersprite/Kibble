import ChatAPI
import ChatKit
import Foundation

/// Complete call snapshots can race command replies; older positions cannot rewind state.
struct ServiceCallStateProjection {
    private var previous: ServiceCallState?
    private var retiredStreams: Set<String> = []
    var version: String? {
        previous?.version
    }

    var currentState: ServiceCallState? {
        previous
    }

    mutating func accept(_ state: ServiceCallState) throws -> [AudioCallEvent] {
        let admission = try admit(state)
        guard admission.accepted else { return [] }
        var events = admission.events
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
        if case .unknown = state.lastEvent, let event = state.lastEvent {
            events.append(event)
        }
        previous = state
        return events
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
