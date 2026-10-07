import Foundation
import Testing
@testable import GChatBridgeCore

/// Answers from a table by URL, and records every request.
private actor TableTransport: HTTPTransport {
    struct NoStream: Error {}
    private let table: [String: HTTPResponse]
    private(set) var sent: [HTTPRequest] = []

    init(_ table: [String: HTTPResponse]) {
        self.table = table
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        return table[request.url.absoluteString]
            ?? HTTPResponse(status: 404, headers: HTTPHeaders([]), body: Data())
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// Refuses every request the way a transport refuses an oversized body.
private struct OversizeTransport: HTTPTransport {
    struct NoStream: Error {}

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw HTTPBodyTooLarge(limit: request.maxBodyBytes ?? 0)
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// `RemoteImageFetch` (links spec §4.4): no credentials on any hop, `https`
/// only, an image only, and a size cap.
@Suite(.timeLimit(.minutes(1)))
struct RemoteImageFetchTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47])

    private static func image(
        _ type: String = "image/png",
        body: Data = png,
        length: Int? = nil
    ) -> HTTPResponse {
        var headers = [("Content-Type", type)]
        if let length {
            headers.append(("Content-Length", String(length)))
        }
        return HTTPResponse(status: 200, headers: HTTPHeaders(headers), body: body)
    }

    private static func redirect(to location: String) -> HTTPResponse {
        HTTPResponse(status: 302, headers: HTTPHeaders([("Location", location)]), body: Data())
    }

    @Test func followsRedirectsAndSendsNoCredentialHeaders() async throws {
        let transport = TableTransport([
            "https://acme.example/a.png": Self.redirect(to: "https://cdn.acme.example/a.png"),
            "https://cdn.acme.example/a.png": Self.image()
        ])
        let data = try await RemoteImageFetch(transport: transport)
            .image(at: #require(URL(string: "https://acme.example/a.png")))
        #expect(data == Self.png)
        let sent = await transport.sent
        #expect(sent.count == 2)
        for request in sent {
            #expect(!request.followsRedirects)
            for name in ["Cookie", "Referer", "Origin", "x-framework-xsrf-token", "Authorization"] {
                #expect(request.headers[name] == nil)
            }
        }
    }

    @Test func anHTTPHopIsRefusedFirstOrLater() async throws {
        let fetch = RemoteImageFetch(transport: TableTransport([
            "https://acme.example/a.png": Self.redirect(to: "http://acme.example/a.png")
        ]))
        await #expect(throws: RemoteImageFetch.Failure.notHTTPS) {
            _ = try await fetch.image(at: #require(URL(string: "http://acme.example/a.png")))
        }
        await #expect(throws: RemoteImageFetch.Failure.notHTTPS) {
            _ = try await fetch.image(at: #require(URL(string: "https://acme.example/a.png")))
        }
    }

    @Test func somethingOtherThanAnImageIsRefused() async throws {
        let fetch = RemoteImageFetch(transport: TableTransport([
            "https://acme.example/a": Self.image("text/html", body: Data("<html>".utf8))
        ]))
        await #expect(throws: RemoteImageFetch.Failure.notAnImage) {
            _ = try await fetch.image(at: #require(URL(string: "https://acme.example/a")))
        }
    }

    @Test func anImageOverTheCapIsRefusedByItsLengthOrItsBody() async throws {
        let declared = RemoteImageFetch(transport: TableTransport([
            "https://acme.example/big.png": Self.image(length: RemoteImageFetch.maxBytes + 1)
        ]))
        await #expect(throws: RemoteImageFetch.Failure.tooLarge) {
            _ = try await declared.image(at: #require(URL(string: "https://acme.example/big.png")))
        }
        let undeclared = RemoteImageFetch(transport: TableTransport([
            "https://acme.example/big.png": Self.image(body: Data(count: RemoteImageFetch.maxBytes + 1))
        ]))
        await #expect(throws: RemoteImageFetch.Failure.tooLarge) {
            _ = try await undeclared.image(at: #require(URL(string: "https://acme.example/big.png")))
        }
    }

    /// Review finding 3: the cap goes to the transport, which stops reading
    /// past it, and its refusal is `.tooLarge`.
    @Test func theCapTravelsWithTheRequestAndARefusalIsTooLarge() async throws {
        #expect(try RemoteImageFetch.request(for: #require(URL(string: "https://acme.example/a.png")))
            .maxBodyBytes
            == RemoteImageFetch.maxBytes)
        await #expect(throws: RemoteImageFetch.Failure.tooLarge) {
            _ = try await RemoteImageFetch(transport: OversizeTransport())
                .image(at: #require(URL(string: "https://acme.example/huge.png")))
        }
    }

    @Test func aRedirectLoopStopsAtTheHopLimit() async throws {
        let fetch = RemoteImageFetch(transport: TableTransport([
            "https://acme.example/a": Self.redirect(to: "https://acme.example/a")
        ]))
        await #expect(throws: RemoteImageFetch.Failure.tooManyRedirects) {
            _ = try await fetch.image(at: #require(URL(string: "https://acme.example/a")))
        }
    }

    @Test func aRefusingStatusIsReported() async throws {
        let fetch = RemoteImageFetch(transport: TableTransport([:]))
        await #expect(throws: RemoteImageFetch.Failure.httpStatus(404)) {
            _ = try await fetch.image(at: #require(URL(string: "https://acme.example/gone.png")))
        }
    }
}
