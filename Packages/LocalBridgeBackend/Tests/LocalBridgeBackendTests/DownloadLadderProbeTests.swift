import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// The download probe's header ladder (`findings.md` §52.4), and the content
/// type key every attachment section prints.
struct DownloadLadderProbeTests {
    /// Each rung adds one difference from the app's request, so the first
    /// rung that succeeds names the difference that matters.
    @Test func theRungsAddOneDifferenceEach() {
        #expect(APIProbeReport.downloadLadder.map(\.style) == [
            AttachmentFetch.RequestStyle(navigation: true),
            AttachmentFetch.RequestStyle(navigation: true, referer: true),
            AttachmentFetch.RequestStyle(navigation: true, referer: true, sendsContentType: false),
            AttachmentFetch.RequestStyle(sendsContentType: false),
            AttachmentFetch.RequestStyle(chatHostOnly: ["COMPASS", "OSID", "__Secure-OSID", "OTZ"])
        ])
        #expect(Set(APIProbeReport.downloadLadder.map(\.label)).count == 5)
    }

    /// §52.3 printed `application/json; charset=utf-8` as "unusual": a
    /// charset parameter is part of an ordinary type.
    @Test(arguments: ["application/json; charset=utf-8", "text/html;charset=UTF-8"])
    func aCharsetIsOrdinary(_ type: String) {
        #expect(APIProbeReport.contentTypeKey(type) == type)
    }

    /// Anything else after the type could carry anything, so it is still
    /// only a length.
    @Test(arguments: [
        "application/json; name=secretvalue",
        "application/json; charset=utf-8; x=y",
        "not a type"
    ])
    func anythingElseIsALength(_ type: String) {
        #expect(APIProbeReport.contentTypeKey(type) == "(unusual, \(type.count) chars)")
    }

    /// §52.5's open question: does the browser's download address have the
    /// same path and parameter names as ours? Names and plain words print;
    /// a segment that could be an identifier, every query value and every
    /// header value do not.
    @Test("a refused download prints each hop's address shape and the refusal's shape")
    func addressAndRefusalShapes() {
        let failure = AttachmentFetchFailure(
            reason: .httpStatus(403),
            hops: [
                AttachmentHop(
                    host: "chat.google.com", status: 302, carriedCredentials: true,
                    pathSegments: ["u", "0", "api", "get_attachment_url"],
                    queryNames: ["url_type", "attachment_token"]
                ),
                AttachmentHop(
                    host: "chat.usercontent.google.com", status: 403, carriedCredentials: true,
                    pathSegments: ["download", "lowercasesecret9", "x"],
                    queryNames: ["auth", "lowercase-secret"]
                )
            ],
            refusal: AttachmentFetchFailure.Refusal(
                contentType: "text/html; charset=utf-8", bodyBytes: 1234,
                headerNames: ["content-type", "x_lowercase.secret"]
            )
        )
        let lines = APIProbeReport.attachmentDownloadLines(label: "x", outcome: .failure(failure))
        #expect(lines == [
            "  x: chat.google.com 302 (credentials) → chat.usercontent.google.com 403 (credentials)",
            "    FAILED: HTTP 403",
            "    addresses: chat.google.com /u/0/api/get_attachment_url ?url_type,attachment_token"
                + " → chat.usercontent.google.com /download/…/x ?auth,?",
            "    refusal: content type text/html; charset=utf-8, 1234 bytes, headers content-type,h18"
        ])
        #expect(!lines.joined().contains("secret"))
    }

    /// §52.6 compared names; a re-encoded `Location` differs in a value. Each
    /// redirect's verdict prints in chain order, and a hop that did not
    /// redirect prints nothing.
    @Test("each redirect says whether its Location was requested verbatim")
    func locationFidelity() {
        let failure = AttachmentFetchFailure(
            reason: .httpStatus(403),
            hops: [
                AttachmentHop(
                    host: "chat.google.com",
                    status: 302,
                    carriedCredentials: true,
                    location: .verbatim
                ),
                AttachmentHop(
                    host: "chat.google.com",
                    status: 302,
                    carriedCredentials: true,
                    location: .reencoded
                ),
                AttachmentHop(
                    host: "chat.google.com",
                    status: 302,
                    carriedCredentials: true,
                    location: .relative
                ),
                AttachmentHop(host: "chat.usercontent.google.com", status: 403, carriedCredentials: true)
            ]
        )
        let lines = APIProbeReport.attachmentDownloadLines(label: "x", outcome: .failure(failure))
        #expect(lines.last == "    locations: verbatim, RE-ENCODED, relative")
    }

    @Test("a chain with no redirect prints no locations line")
    func noRedirectNoLocations() {
        let failure = AttachmentFetchFailure(
            reason: .httpStatus(403),
            hops: [AttachmentHop(host: "chat.google.com", status: 403, carriedCredentials: true)]
        )
        let lines = APIProbeReport.attachmentDownloadLines(label: "x", outcome: .failure(failure))
        #expect(!lines.contains { $0.contains("locations") })
    }
}
