import Foundation

/// Sends Punctual requests with the session's current cookies, and absorbs
/// every rotation the answers carry.
///
/// `ProtoAPIClient` does the same for `/api/`, and adds the xsrf token and the
/// protobuf decoding that Punctual has no use for. Whether cookies alone
/// authenticate Punctual is `[Verify]`: the capture was exported sanitised, so
/// it cannot show whether the browser also sent an `Authorization` header.
public struct PunctualClient: Sendable {
    let transport: any HTTPTransport
    let credentials: SessionCredentials

    public init(transport: any HTTPTransport, credentials: SessionCredentials) {
        self.transport = transport
        self.credentials = credentials
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await transport.send(credentials.authorising(request))
        await credentials.absorb(response.headers, from: request.url)
        return response
    }

    public func stream(_ request: HTTPRequest) async throws -> HTTPStream {
        let stream = try await transport.stream(credentials.authorising(request))
        await credentials.absorb(stream.headers, from: request.url)
        return stream
    }
}
