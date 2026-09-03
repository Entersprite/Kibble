import Foundation
import Testing
@testable import ChatKit

/// Why a connection is not working, as a wire type.
///
/// The `.unknown` cases are the point: a server that learns a new issue
/// category must not brick a client that has not. See CLAUDE.md's wire rules -
/// "an unknown discriminator decodes to `.unknown` and never throws, and
/// re-encodes verbatim."
struct ConnectionIssueTests {
    private func roundTrip(_ issue: ConnectionIssue) throws -> ConnectionIssue {
        let data = try JSONEncoder().encode(issue)
        return try JSONDecoder().decode(ConnectionIssue.self, from: data)
    }

    @Test func everyCaseSurvivesARoundTrip() throws {
        let all: [ConnectionIssue] = [
            .noInternet, .nameResolution, .refused, .intercepted,
            .unresponsive, .dropped, .rateLimited,
            .serverError(status: 503), .unknown("somethingNew")
        ]
        for issue in all {
            #expect(try roundTrip(issue) == issue)
        }
    }

    @Test func anUnknownDiscriminatorDecodesRatherThanThrowing() throws {
        let json = Data(#"{"type":"quantumTunnelCollapse"}"#.utf8)
        let decoded = try JSONDecoder().decode(ConnectionIssue.self, from: json)
        #expect(decoded == .unknown("quantumTunnelCollapse"))
    }

    /// Verbatim, not merely non-throwing: a client that re-emits what it did
    /// not understand keeps a hosted tier's frames intact on the way back.
    @Test func anUnknownDiscriminatorReEncodesVerbatim() throws {
        let decoded = ConnectionIssue.unknown("quantumTunnelCollapse")
        let data = try JSONEncoder().encode(decoded)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "quantumTunnelCollapse")
    }

    @Test func theServerErrorStatusIsCarried() throws {
        #expect(try roundTrip(.serverError(status: 500)) == .serverError(status: 500))
        #expect(try roundTrip(.serverError(status: 503)) != .serverError(status: 500))
    }
}

struct ConnectionStateWireTests {
    @Test func anUnknownStateDecodesRatherThanThrowing() throws {
        let json = Data(#"{"type":"hibernating"}"#.utf8)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: json)
        #expect(decoded == .unknown("hibernating"))
    }

    /// The whole point of the `.unknown` addition: this used to throw.
    @Test func anUnknownStateReEncodesVerbatim() throws {
        let data = try JSONEncoder().encode(ConnectionState.unknown("hibernating"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["type"] as? String == "hibernating")
        #expect(object?.count == 1)
    }

    /// A peer that predates `issue`/`detail` still decodes - "assume less".
    @Test func aFrameWithoutAnIssueStillDecodes() throws {
        let json = Data(#"{"type":"reconnecting","attempt":3}"#.utf8)
        let decoded = try JSONDecoder().decode(ConnectionState.self, from: json)
        #expect(decoded == .reconnecting(attempt: 3, issue: nil, detail: nil))
    }

    /// And a nil issue omits the key rather than writing null, which is what
    /// keeps FixtureBackend's frames byte-identical.
    @Test func aNilIssueOmitsTheKey() throws {
        let data = try JSONEncoder().encode(
            ConnectionState.reconnecting(attempt: 1, issue: nil, detail: nil)
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["issue"] == nil)
        #expect(object?.count == 2)
    }

    @Test func anIssueRoundTrips() throws {
        let state = ConnectionState.reconnecting(
            attempt: 2, issue: .intercepted, detail: "NSURLErrorDomain -1200"
        )
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(ConnectionState.self, from: data) == state)
    }
}
