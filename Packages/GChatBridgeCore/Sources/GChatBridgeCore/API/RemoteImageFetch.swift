import Foundation

/// A picture a message points at - a link preview's or an app card's - from
/// wherever Google said it is (links spec §4.4).
///
/// **It holds no credentials, so it cannot send any.** It is built from a
/// transport alone: no cookie jar, no xsrf token, no endpoints. Every hop goes
/// out with no `Cookie`, `Referer` or `Origin`, and nothing a hop sets is kept,
/// because there is nowhere to keep it. `AttachmentFetch` was not reused for
/// exactly this reason: it holds the session, and its per-host rule would send
/// the chat host's cookies to an image on `chat.google.com`.
///
/// Every hop must be `https`, at most `maxHops` of them, and the answer must be
/// `image/*` and at most `maxBytes`.
public struct RemoteImageFetch: Sendable {
    public static let maxHops = 10
    public static let maxBytes = 10 * 1_048_576
    static let timeout = Duration.seconds(30)

    /// Never carries the URL: an error may be shown or logged.
    public enum Failure: Error, Equatable, Sendable {
        case notHTTPS
        case tooManyRedirects
        case redirectWithoutLocation
        case httpStatus(Int)
        case notAnImage
        case tooLarge
        case transport
    }

    let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    public func image(at url: URL) async throws(Failure) -> Data {
        var next = url
        for _ in 0 ..< Self.maxHops {
            guard next.scheme?.lowercased() == "https" else { throw .notHTTPS }
            let response: HTTPResponse
            do {
                response = try await transport.send(Self.request(for: next))
            } catch is HTTPBodyTooLarge {
                throw .tooLarge
            } catch {
                throw .transport
            }
            switch response.status {
            case 300 ..< 400:
                guard let location = response.headers["Location"],
                      let resolved = URL(string: location, relativeTo: next)?.absoluteURL
                else { throw .redirectWithoutLocation }
                next = resolved
            case 200 ..< 300:
                return try Self.image(from: response)
            default:
                throw .httpStatus(response.status)
            }
        }
        throw .tooManyRedirects
    }

    static func request(for url: URL) -> HTTPRequest {
        HTTPRequest(
            method: .get,
            url: url,
            headers: HTTPHeaders([("Accept", "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8")]),
            timeout: timeout,
            traceLabel: "remote_image",
            followsRedirects: false,
            // The transport stops reading past it (review finding 3).
            maxBodyBytes: maxBytes
        )
    }

    private static func image(from response: HTTPResponse) throws(Failure) -> Data {
        guard response.headers["Content-Type"]?.lowercased().hasPrefix("image/") == true else {
            throw .notAnImage
        }
        if let declared = response.headers["Content-Length"].flatMap({ Int($0) }), declared > maxBytes {
            throw .tooLarge
        }
        guard response.body.count <= maxBytes else { throw .tooLarge }
        return response.body
    }
}
