import Foundation
import SwiftProtobuf

/// A response nobody has tried to decode yet.
public struct RawAPIResponse: Sendable, Hashable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

/// The `/api/` request family, made against a live credential.
///
/// An actor because it owns two pieces of mutable state that must not race: the
/// `c` counter, and the record of which encoding the last response arrived in.
///
/// ## What it can and cannot claim
///
/// One method here has been verified end to end against live traffic -
/// `get_self_user_status` (§3.6). The others are shapes taken from the proto and
/// the reference. That distinction is recorded on each `APIMethod`, not here,
/// because it belongs next to the name a caller types.
public actor ProtoAPIClient {
    private let transport: any HTTPTransport
    private let requests: APIRequests
    private let credentials: SessionCredentials
    private let xsrfToken: String?
    private var counter: Int

    /// Which encoding the last response arrived in, or `nil` before the first
    /// one. Evidence, not control flow: §3.6 contradicts the reference on this
    /// and the next contradiction should be a measurement rather than an
    /// argument.
    public private(set) var lastEncoding: APIResponseEncoding?
    /// The last call refused with a status other than 200, and what came
    /// with it. Evidence, not control flow, as `lastEncoding` is: the status
    /// alone named no reason for a 400 (session 62).
    public private(set) var lastRefusal: APIRefusal?

    public init(
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        credentials: SessionCredentials,
        xsrfToken: String?,
        apiKey: String = APIRequests.defaultAPIKey,
        initialCounter: Int = 0
    ) {
        self.transport = transport
        self.credentials = credentials
        self.xsrfToken = xsrfToken
        requests = APIRequests(endpoints: endpoints, apiKey: apiKey)
        counter = initialCounter
    }

    /// One typed call.
    public func call<Request, Response>(
        _ method: APIMethod<Request, Response>,
        _ request: Request
    ) async throws -> Response {
        let body: Data = try request.serializedBytes()
        let raw = try await callRaw(method.name, body: body)
        let candidates = APIResponseBody.candidates(raw.body)
        guard !candidates.isEmpty else { throw APIFailure.emptyBody }

        var detail = "no candidate parsed"
        for candidate in candidates {
            do {
                let decoded = try Response(serializedBytes: candidate.bytes)
                lastEncoding = candidate.encoding
                return decoded
            } catch {
                detail = String(describing: error)
            }
        }
        throw APIFailure.undecodable(encodings: candidates.map(\.encoding), detail: detail)
    }

    /// One call, bytes in and bytes out.
    ///
    /// The probe path. A typed decode would discard a field the vendored proto
    /// cannot name, which is precisely what the probe is looking for (§12.1.1).
    public func callRaw(_ name: String, body: Data) async throws -> RawAPIResponse {
        counter += 1
        let request = requests.request(
            method: name,
            counter: counter,
            body: body,
            xsrfToken: xsrfToken
        )
        let response: HTTPResponse
        do {
            // `credentials.authorising` is where "put the Cookie header on"
            // lives - the same call `ChannelSession` makes - so the channel and
            // this client never carry two divergent ideas of what authorising a
            // request means.
            response = try await transport.send(credentials.authorising(request))
        } catch let classified as ClassifiedTransportFailure {
            throw APIFailure.transport(classified.reason)
        } catch {
            // Whatever this was, this package cannot classify it - only an
            // `HTTPTransport` that actually touches a socket can, by throwing
            // `ClassifiedTransportFailure` instead. `nil` carries that "no
            // classification available" fact without ever interpolating
            // `error` itself, which is where a live transport failure's URL -
            // `key=` and `c=` included - would otherwise leak in.
            throw APIFailure.transport(nil)
        }
        // Absorbed before the status is judged: a response that rotated a cookie
        // and then failed still rotated the cookie, and dropping it would leave
        // the jar behind the server.
        await credentials.absorb(response.headers, from: request.url)
        guard response.status == 200 else {
            lastRefusal = APIRefusal(method: name, status: response.status, body: response.body)
            throw APIFailure.httpStatus(response.status)
        }
        return RawAPIResponse(status: response.status, body: response.body)
    }
}

/// A call refused with a status other than 200: which, and what came back.
public struct APIRefusal: Sendable, Hashable {
    public let method: String
    public let status: Int
    public let body: Data
}
