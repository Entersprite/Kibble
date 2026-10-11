import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Connecting a backend over `SearchTransport`, and waiting for the
/// background work `connect()` starts - by the state it leaves, never a
/// fixed sleep (`CLAUDE.md`, Testing). Shared across every
/// `SearchMessages*Tests.swift` file: `ActivityReportTests.waitForSelf` is
/// the same pattern, duplicated there per that file's own convention: this
/// is one more place genuinely reusing it rather than re-deriving it beats
/// four slightly-different copies drifting apart.
enum SearchBackendSupport {
    static let cookies = SessionCookies(header: "SID=a; COMPASS=b; OSID=c")!

    static func connected(_ transport: SearchTransport) async throws -> LocalBridgeBackend {
        let backend = LocalBridgeBackend(cookies: cookies, transport: transport)
        try await backend.connect()
        try await waitForSelf(backend)
        return backend
    }

    /// `resolveAndEmitSelf` runs behind `connect()`: wait for it by
    /// `presencePoll.selfResolved`, set in its own `defer` block whichever
    /// way the call went.
    static func waitForSelf(_ backend: LocalBridgeBackend) async throws {
        for _ in 0 ..< 400 where await !backend.presencePoll.selfResolved {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await backend.presencePoll.selfResolved)
    }

    static func batchRequests(_ transport: SearchTransport) async -> [HTTPRequest] {
        await transport.sent.filter { $0.url.path.contains("batchexecute") }
    }

    /// Bounded, never a fixed sleep: `resolveUnknownMembers` starts its
    /// lookup without being awaited, so a test of its effect has to poll for
    /// it.
    static func waitFor(
        _ transport: SearchTransport,
        _ done: ([HTTPRequest]) -> Bool
    ) async throws -> [HTTPRequest] {
        for _ in 0 ..< 400 {
            let sent = await transport.sent
            if done(sent) {
                return sent
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await transport.sent
    }
}
