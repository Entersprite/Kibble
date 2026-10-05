import ChatKit
import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

/// Answers the upload's two requests from a script, in order.
private actor ScriptedUploadTransport: HTTPTransport {
    struct NoStream: Error {}
    struct Exhausted: Error {}

    private var responses: [HTTPResponse]

    init(_ responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_: HTTPRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else { throw Exhausted() }
        return responses.removeFirst()
    }

    func stream(_: HTTPRequest) async throws -> HTTPStream {
        throw NoStream()
    }
}

/// `--probe=upload`'s report: what each exchange looked like, and never a
/// value Google or the session supplied.
@Suite("Upload probe")
struct UploadProbeTests {
    /// Lowercase on purpose: a sentinel the report's own rules would mask
    /// anyway proves nothing (`CLAUDE.md`, the leak-test rule).
    static let tokenSecret = "lowercaseuploadtokensecret"
    static let uploadIDSecret = "lowercaseuploadidsecret"
    static let cookieSecret = "lowercasecookiesecret"

    private static func group() -> GroupId {
        var group = GroupId()
        var dm = DmId()
        dm.dmID = "lowercasedmidsecret"
        group.dmID = dm
        return group
    }

    private static func run(_ responses: [HTTPResponse]) async throws -> (Bool, String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try UploadProbeReport.png.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let credentials = SessionCredentials(SessionCookies(cookies: [
            SessionCookies.Cookie(name: "SID", value: cookieSecret, domain: ".google.com", path: "/")
        ])!)
        var lines: [String] = []
        let worked = await UploadProbeReport.appendRung(
            UploadProbeReport.rungs(ChatEndpoints())[0],
            file: UploadFile(
                url: file, name: UploadProbeReport.fileName, contentType: "image/png",
                byteCount: UploadProbeReport.png.count
            ),
            group: group(),
            session: UploadProbeReport.Session(
                transport: ScriptedUploadTransport(responses), credentials: credentials,
                xsrfToken: "lowercasexsrfsecret"
            ),
            lines: &lines
        )
        return (worked, lines.joined(separator: "\n"))
    }

    private static func started() -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: HTTPHeaders([
                ("x-goog-upload-url", "https://chat.google.com/uploads?upload_id=\(uploadIDSecret)"),
                ("x-goog-upload-status", "active"),
                ("x-goog-upload-chunk-granularity", "1048576"),
                ("Set-Cookie", "SIDCC=\(cookieSecret); Domain=.google.com; Path=/")
            ]),
            body: Data()
        )
    }

    private static func finalized() throws -> HTTPResponse {
        var metadata = UploadMetadata()
        metadata.attachmentToken = tokenSecret
        metadata.contentName = UploadProbeReport.fileName
        metadata.contentType = "image/png"
        let bytes: Data = try metadata.serializedBytes()
        return HTTPResponse(
            status: 200,
            headers: HTTPHeaders([("x-goog-upload-status", "final")]),
            body: Data(bytes.base64EncodedString().utf8)
        )
    }

    @Test func theProbesPictureIsAValidSixteenPixelPNG() {
        #expect(UploadProbeReport.png.count == 79)
        #expect(UploadProbeReport.png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test func aWorkingRungReportsBothExchangesAndTheMetadataByNumber() async throws {
        let (worked, report) = try await Self.run([Self.started(), Self.finalized()])
        #expect(worked)
        #expect(report.contains("POST chat.google.com/u/0/uploads ?group_id (cookie yes, xsrf yes)"))
        #expect(report.contains("upload-status active; chunk-granularity 1048576;"))
        #expect(report.contains("upload-url chat.google.com/uploads ?upload_id"))
        #expect(report.contains("PUT chat.google.com/uploads ?upload_id"))
        #expect(report.contains("body 0 bytes"))
        #expect(report.contains(", base64"))
        #expect(report.contains("UPLOADED. metadata fields: 1 3 4"))
        #expect(report.contains("attachment token: \(Self.tokenSecret.count) chars"))
        #expect(report.contains("content_name echoed: true"))
    }

    @Test func theReportNeverCarriesATokenAnIDOrACookie() async throws {
        let (_, report) = try await Self.run([Self.started(), Self.finalized()])
        for secret in [
            Self.tokenSecret,
            Self.uploadIDSecret,
            Self.cookieSecret,
            "lowercasedmidsecret",
            "lowercasexsrfsecret"
        ] {
            #expect(!report.contains(secret), "\(secret) leaked")
        }
    }

    @Test func aRefusedRungSaysWhyAndWhatItWasAnswered() async throws {
        let page = HTTPResponse(
            status: 200, headers: HTTPHeaders([("Content-Type", "text/html")]), body: Data("<html>".utf8)
        )
        let (worked, report) = try await Self.run([page])
        #expect(!worked)
        #expect(report.contains("FAILED: noUploadURL"))
        #expect(report.contains("answer: text/html, 6 bytes, headers content-type"))
    }

    @Test func aLongPathSegmentIsALength() throws {
        let url =
            try #require(
                URL(string: "https://chat.google.com/upload/\(String(repeating: "x", count: 40))?a=1&b=2")
            )
        #expect(UploadProbeTransport.describe(url) == "chat.google.com/upload/<40 chars> ?a,b")
    }

    @Test func aChangedNameIsShownEscaped() {
        #expect(UploadProbeReport.escaped("a%20b\u{202F}é.png") == "a%20b\\u{202F}\\u{E9}.png")
        #expect(UploadProbeReport.fileName.unicodeScalars.contains("\u{202F}"))
    }
}
