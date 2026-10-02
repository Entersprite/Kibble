import Foundation
import Testing
@testable import GChatBridgeCore

/// Whether the address a redirect named is the address the next hop asked
/// for. §52.6 compared the browser's download address with ours by parameter
/// names only; a `Location` that `URL(string:)` re-encodes would differ in a
/// value, which no names-only comparison can see.
@Suite("Attachment fetch: redirect locations")
struct AttachmentFetchLocationTests {
    static func hops(after location: String) async throws -> [AttachmentHop] {
        let transport = FakeHTTPTransport(responses: [
            AttachmentFetchTests.redirect(to: location),
            AttachmentFetchTests.image("PDF", contentType: "application/pdf")
        ])
        let fetched = try await AttachmentFetchTests.fetch(transport).fetch(
            token: "t", contentType: "application/pdf", variant: .file
        )
        return fetched.hops
    }

    @Test("an absolute Location that parses unchanged is verbatim")
    func verbatim() async throws {
        let hops = try await Self.hops(
            after: "https://chat.usercontent.google.com/download?attachment_token=ab%2Bc-_&authuser=0"
        )
        #expect(hops.map(\.location) == [.verbatim, nil])
    }

    @Test("an absolute Location that URL(string:) has to encode is re-encoded")
    func reencoded() async throws {
        let hops = try await Self
            .hops(after: "https://chat.usercontent.google.com/download?attachment_token=a|b")
        #expect(hops.map(\.location) == [.reencoded, nil])
    }

    @Test("a relative Location is reported as relative, not compared")
    func relative() async throws {
        let hops = try await Self.hops(after: "/download?attachment_token=ab")
        #expect(hops.map(\.location) == [.relative, nil])
    }
}
