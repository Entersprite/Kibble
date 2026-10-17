import ChatKit
import Foundation
import GChatBridgeCore

extension LocalBridgeAudioCallService {
    func loadAndListenWithRetry(scope: UUID) async throws {
        var attempt = 0
        while true {
            try checkSession(scope)
            do {
                try await loadAndListen(scope: scope)
                return
            } catch {
                try checkSession(scope)
                guard Self.canRetryStartup(error) else { throw error }
                continuation.yield(.listenerChanged(isListening: false))
                let delay = Self.startupRetryDelay(attempt)
                attempt = min(attempt + 1, 4)
                try await retrySleep(delay)
            }
        }
    }

    func loadCallDirectory(scope: UUID) async throws {
        let loaded = try await trial.loadPeople()
        try checkSession(scope)
        people = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        hasLoadedPeople = true
        if let directoryRecipients {
            let revision = directoryRevision
            let updated = await trial.updatePeople(directoryRecipients)
            try checkSession(scope)
            if directoryRevision == revision {
                people = updated
            }
        }
        continuation.yield(.recipientsChanged(people.values.map(Self.recipient)))
    }

    static func startupRetryDelay(_ attempt: Int) -> Duration {
        .seconds([3, 6, 12, 24, 30][min(max(attempt, 0), 4)])
    }

    static func canRetryStartup(_ error: any Error) -> Bool {
        if error is ClassifiedTransportFailure {
            return true
        }
        if let error = error as? URLError {
            return [
                .timedOut,
                .cannotFindHost,
                .cannotConnectToHost,
                .networkConnectionLost,
                .dnsLookupFailed,
                .notConnectedToInternet
            ].contains(error.code)
        }
        if let error = error as? APIFailure {
            switch error {
            case .transport: return true
            case let .httpStatus(status): return retryableStatus(status)
            default: return false
            }
        }
        if case let BootstrapFailure.unexpectedStatus(status) = error {
            return retryableStatus(status)
        }
        if case let MeetPushBootstrapError.httpStatus(status) = error {
            return retryableStatus(status)
        }
        // An outgoing call may advance the trial generation while the
        // read-only listener configuration is loading. Keep its media intact.
        return error as? MeetDMCallTrialError == .superseded
    }

    private static func retryableStatus(_ status: Int) -> Bool {
        [408, 429].contains(status) || (500 ... 599).contains(status)
    }
}
