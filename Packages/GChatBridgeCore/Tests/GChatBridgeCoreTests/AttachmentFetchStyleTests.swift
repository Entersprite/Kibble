import Foundation
import Testing
@testable import GChatBridgeCore

/// `AttachmentFetch.RequestStyle`: the browser-navigation headers and the
/// optional `content_type` the download probe's ladder varies, because Chat on
/// the web downloads a file by navigating a new tab to it and gets a 200 from
/// `chat.usercontent.google.com` where this client gets 403 (`findings.md`
/// §52.4). The fixtures are `AttachmentFetchTests`'s.
@Suite("Attachment fetch - request style")
struct AttachmentFetchStyleTests {
    private static func download(
        _ style: AttachmentFetch.RequestStyle
    ) async throws -> [HTTPRequest] {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "https://chat.usercontent.google.com/download"),
            AttachmentFetchTests.redirect(to: AttachmentFetchTests.fife),
            HTTPResponse(
                status: 200,
                headers: HTTPHeaders([("Content-Type", "application/pdf")]),
                body: Data([1])
            )
        ])
        _ = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "t", contentType: "application/pdf", variant: .file, style: style
        )
        return await transport.sent
    }

    @Test("the app's style sends no navigation headers and keeps content_type")
    func appStyleIsUnchanged() async throws {
        let sent = try await Self.download(.app)
        #expect(sent.allSatisfy { $0.headers["Sec-Fetch-Mode"] == nil && $0.headers["Referer"] == nil })
        let query = URLComponents(url: sent[0].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains { $0.name == "content_type" })
    }

    /// `Sec-Fetch-Site` is what a browser computes for each hop of a
    /// navigation started on the chat host: the host itself, a sibling under
    /// `google.com`, and anything else.
    @Test("a navigation sends Sec-Fetch headers, with the site computed per hop")
    func navigationHeadersPerHop() async throws {
        let sent = try await Self.download(AttachmentFetch.RequestStyle(navigation: true))
        #expect(sent.map { $0.headers["Sec-Fetch-Site"] } == ["same-origin", "same-site", "cross-site"])
        #expect(sent.allSatisfy {
            $0.headers["Sec-Fetch-Mode"] == "navigate" && $0.headers["Sec-Fetch-Dest"] == "document"
                && $0.headers["Sec-Fetch-User"] == "?1" && $0.headers["Upgrade-Insecure-Requests"] == "1"
                && $0.headers["Accept"]?.hasPrefix("text/html") == true
        })
        #expect(sent.allSatisfy { $0.headers["Referer"] == nil })
    }

    /// A browser's default referrer policy sends only the origin off it,
    /// and nothing to a host outside Google's domain is owed even that.
    @Test("a referer is the chat origin, sent to Google hosts only")
    func refererToGoogleHostsOnly() async throws {
        let sent = try await Self.download(AttachmentFetch.RequestStyle(referer: true))
        #expect(sent.map { $0.headers["Referer"] } == [
            "https://chat.google.com/",
            "https://chat.google.com/",
            nil
        ])
    }

    @Test("content_type can be left out, as mautrix does for DOWNLOAD_URL")
    func contentTypeOmitted() async throws {
        let sent = try await Self.download(AttachmentFetch.RequestStyle(sendsContentType: false))
        let query = URLComponents(url: sent[0].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!query.contains { $0.name == "content_type" })
        #expect(query.contains { $0.name == "attachment_token" })
    }
}

/// What a hop keeps of its URL and of a refusal, for the probe to compare
/// with the browser's download address (`findings.md` §52.5). Names only:
/// a value can be the token.
@Suite("Attachment fetch - shapes")
struct AttachmentFetchShapeTests {
    @Test("each hop keeps its path segments and its query names, never a value")
    func hopShapes() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests
                .redirect(to: "https://chat.usercontent.google.com/download/more?auth=lowercasesecret&id=x"),
            AttachmentFetchTests.image()
        ])
        let fetched = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "lowercasetoken", contentType: "image/png", variant: .preview
        )
        #expect(fetched.hops[0].pathSegments == ["u", "0", "api", "get_attachment_url"])
        #expect(fetched.hops[1].pathSegments == ["download", "more"])
        #expect(fetched.hops[1].queryNames == ["auth", "id"])
        #expect(fetched.hops[0].queryNames == ["url_type", "content_type", "attachment_token", "sz"])
    }

    @Test("a refusal keeps its content type, body size and header names")
    func refusalShape() async throws {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: "https://chat.usercontent.google.com/download"),
            HTTPResponse(
                status: 403,
                headers: HTTPHeaders([("Content-Type", "text/html"), ("X-Thing", "lowercasesecret")]),
                body: Data("nope".utf8)
            )
        ])
        do {
            _ = try await AttachmentFetchTests.fetch(transport).fetch(
                token: "t", contentType: "application/pdf", variant: .file
            )
            Issue.record("expected a refusal")
        } catch {
            #expect(error.reason == .httpStatus(403))
            #expect(error.refusal == AttachmentFetchFailure.Refusal(
                contentType: "text/html", bodyBytes: 4, headerNames: ["content-type", "x-thing"]
            ))
        }
    }
}
