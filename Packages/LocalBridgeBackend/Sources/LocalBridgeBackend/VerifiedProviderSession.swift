import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// A provider-verified identity and a sealed candidate credential. Hosts can
/// install it in their vault; credentials never enter the client API.
public struct VerifiedProviderSession: Sendable {
    public let selfID: ChatKit.Member.ID
    private let source: KeychainCredentialStore
    private let capture: CredentialSnapshot

    init(selfID: ChatKit.Member.ID, source: KeychainCredentialStore, capture: CredentialSnapshot) {
        self.selfID = selfID
        self.source = source
        self.capture = capture
    }

    var sourceGeneration: String? {
        capture.generation
    }

    func currentSession() async throws -> StoredSession {
        guard let current = try await source.snapshot(), current.matches(capture) else {
            throw SessionCustodyError.sessionChanged
        }
        return current.session
    }
}

public extension KeychainCredentialStore {
    /// Reads identity using the same bootstrap/self-status path as Meet account
    /// verification, then checks that the capture survived those network awaits.
    func verify(
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints()
    ) async throws -> VerifiedProviderSession {
        guard let capture = try snapshot() else { throw SessionCustodyError.sessionChanged }
        let id = try await MeetWebCredentials.accountID(
            for: capture.session.credential, source: .storedChat,
            transport: transport, endpoints: endpoints
        )
        guard let current = try snapshot(), current.matches(capture) else {
            throw SessionCustodyError.sessionChanged
        }
        return VerifiedProviderSession(selfID: ChatKit.Member.ID(id), source: self, capture: capture)
    }
}
