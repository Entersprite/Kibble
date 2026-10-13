import Foundation

public enum MeetPushBootstrapError: Error, Sendable, Equatable {
    case httpStatus(Int), redirected(Int), invalidShell, signedOut
}

/// The Gmail mole shell can omit standalone Chat configuration. This read-only
/// fallback uses the selected Chat account and its current scoped cookie jar.
public struct MeetPushBootstrap: Sendable {
    private let transport: any HTTPTransport
    private let credentials: SessionCredentials

    public init(transport: any HTTPTransport, credentials: SessionCredentials) {
        self.transport = transport
        self.credentials = credentials
    }

    public func load(endpoints: ChatEndpoints) async throws -> WizGlobalData {
        let request = HTTPRequest(
            url: endpoints.base.appendingPathComponent("app").appendingPathComponent("home"),
            headers: HTTPHeaders([
                ("User-Agent", endpoints.userAgent),
                ("Referer", "https://chat.google.com/")
            ]),
            timeout: .seconds(20), traceLabel: "meet-push-bootstrap",
            followsRedirects: false, maxBodyBytes: 3_000_000
        )
        let response = try await transport.send(credentials.authorising(request))
        await credentials.absorb(response.headers, from: request.url)
        guard !response.isRedirect else { throw MeetPushBootstrapError.redirected(response.status) }
        guard response.status == 200 else { throw MeetPushBootstrapError.httpStatus(response.status) }
        guard let wiz = WizGlobalData(html: String(decoding: response.body, as: UTF8.self)) else {
            throw MeetPushBootstrapError.invalidShell
        }
        guard wiz.isSignedIn else { throw MeetPushBootstrapError.signedOut }
        return wiz
    }
}
