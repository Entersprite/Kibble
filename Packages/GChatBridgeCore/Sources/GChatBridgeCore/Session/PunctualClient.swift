import Foundation

/// Sends Punctual requests with the session's current cookies, and absorbs
/// every rotation the answers carry.
///
/// Availability uses cookies alone. Meet prefix subscriptions additionally
/// require a page-origin proof; the injected builder signs the same isolated
/// snapshot as the Cookie header. Missing proof stops before the transport.
public struct PunctualClient: Sendable {
    let transport: any HTTPTransport
    let credentials: SessionCredentials
    let authorization: (@Sendable (SessionCookies, URL) -> String?)?

    public init(
        transport: any HTTPTransport, credentials: SessionCredentials,
        authorization: (@Sendable (SessionCookies, URL) -> String?)? = nil
    ) {
        self.transport = transport
        self.credentials = credentials
        self.authorization = authorization
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await transport.send(authorised(request))
        await credentials.absorb(response.headers, from: request.url)
        return response
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let stream = try await transport.stream(authorised(request))
        await credentials.absorb(stream.headers, from: request.url)
        return stream
    }

    private func authorised(_ request: HTTPRequest) async throws -> HTTPRequest {
        guard let authorization else { return await credentials.authorising(request) }
        let request = await credentials.authorising(request, authorization: authorization)
        guard request.headers["Authorization"] != nil else { throw PunctualClientError.missingSessionProof }
        return request
    }
}

public enum PunctualClientError: Error, Sendable {
    case missingSessionProof
}
