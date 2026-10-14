import Foundation
import GChatBridgeCore
import Testing
@testable import LocalBridgeBackend

struct MeetWebCallSignInTests {
    private struct Setup {
        let store: KeychainCredentialStore
        let capture: CookieCapture
        let cookies: [CapturedCookie]
        let transport: ScriptedTransport
        let original: StoredSession
    }

    private final class Storage: SecretStorage, @unchecked Sendable {
        var items: [String: Data] = [:]
        func read(account: String) throws -> Data? {
            items[account]
        }

        func write(_ data: Data, account: String) throws {
            items[account] = data
        }

        func delete(account: String) throws {
            items[account] = nil
        }
    }

    private func cookie(_ name: String, domain: String, expiresAt: Date? = nil) -> CapturedCookie {
        CapturedCookie(
            name: name,
            value: "fresh-" + name,
            domain: domain,
            path: "/",
            isSecure: true,
            isHTTPOnly: true,
            expiresAt: expiresAt
        )
    }

    private func setup(
        _ shell: Result<HTTPResponse, any Error>,
        capturedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date? = nil
    ) async throws -> Setup {
        var status = GetSelfUserStatusResponse()
        status.userStatus.userID.id = "same-account"
        let identity = try HTTPResponse(status: 200, headers: HTTPHeaders([]), body: status.serializedBytes())
        let transport = ScriptedTransport([
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")), .success(identity),
            ScriptedTransport.ok(LocalBridgeBackendTests.shell(app: "DynamiteWebUi")), .success(identity),
            shell
        ])
        let capture = CookieCapture(
            cookies: [cookie("SID", domain: ".google.com", expiresAt: expiresAt)],
            capturedAt: capturedAt,
            pageURL: "https://chat.google.com/", pageTitle: "Google Chat"
        )
        let store = KeychainCredentialStore(storage: Storage(), account: "call-sign-in")
        #expect(try await capture.save(to: store))
        return try await Setup(
            store: store, capture: capture,
            cookies: [cookie("SID", domain: ".google.com"), cookie("OTZ", domain: "meet.google.com")],
            transport: transport, original: #require(store.currentSession())
        )
    }

    @Test(arguments: [false, true])
    func aPreferenceCookieCannotCompleteCallingSignInWithoutAnAuthenticatedShell(
        redirects: Bool
    ) async throws {
        let shell = HTTPResponse(
            status: redirects ? 302 : 200,
            headers: HTTPHeaders([(
                "Location",
                "https://accounts.google.com/signin?secret=private-sentinel"
            )]),
            body: Data("Guest or consent page".utf8)
        )
        let setup = try await setup(.success(shell))
        await #expect(throws: MeetWebCaptureError.callSignInVerificationFailed) {
            try await MeetWebCredentials.save(
                captured: setup.cookies, to: setup.store, expectedCapture: setup.capture,
                validatesCallSignIn: true, transport: setup.transport
            )
        }
        #expect(try await setup.store.currentSession() == setup.original)
        let sent = await setup.transport.sent
        #expect(sent.count == 5)
        #expect(sent.last?.url.host == "meet.google.com")
        #expect(sent.last?.url.path == "/call")
        #expect(sent.last?.followsRedirects == false)
        #expect(sent.allSatisfy { !$0.url.path.contains("Create") && !$0.url.path.contains("Resolve") })
        #expect(MeetWebCaptureError.callSignInVerificationFailed.verificationDescription
            == "Calling sign-in could not be verified.")
    }

    @Test func acceptedCallingShellSavesFreshMeetCookiesAndAcceptedHostRotation() async throws {
        var shell = try MeetDMCallTrialTests().preparingResponses()[0].get()
        shell.headers = HTTPHeaders([("Set-Cookie", "MOSID=shell-rotation; Domain=meet.google.com; Path=/")])
        let setup = try await setup(.success(shell))
        #expect(try await MeetWebCredentials.save(
            captured: setup.cookies, to: setup.store, expectedCapture: setup.capture,
            validatesCallSignIn: true, transport: setup.transport
        ) == 2)
        let stored = try #require(try await setup.store.currentSession())
        #expect(stored.credential["SID"] == setup.original.credential["SID"])
        #expect(stored.credential.cookies.map(\.name) == ["SID", "OTZ", "MOSID"])
        #expect(stored.credential["MOSID"] == "shell-rotation")
        #expect(stored.capturedAt == setup.original.capturedAt)
        #expect(stored.expiresAt == setup.original.expiresAt)
        let request = try #require(await setup.transport.sent.last)
        #expect(request.headers["Cookie"]?.contains("OTZ=fresh-OTZ") == true)
        #expect(request.headers["Cookie"]?.contains("SID=fresh-SID") == true)
    }

    @Test(arguments: [false, true])
    func fractionalCaptureSurvivesKeychainDateEncodingDuringCallSetup(expiry: Bool) async throws {
        // Adding the Unix epoch offset loses one bit at current capture dates.
        let fractional = Date(timeIntervalSinceReferenceDate: 813_683_184.0000001)
        let setup = try await setup(
            MeetDMCallTrialTests().preparingResponses()[0],
            capturedAt: expiry ? Date(timeIntervalSinceReferenceDate: 813_683_184) : fractional,
            expiresAt: expiry ? fractional : nil
        )
        let originalCapture = try #require(setup.capture.session)
        if expiry {
            #expect(originalCapture.expiresAt != setup.original.expiresAt)
        } else {
            #expect(originalCapture.capturedAt != setup.original.capturedAt)
        }
        #expect(originalCapture.capturedAt.timeIntervalSince1970
            == setup.original.capturedAt.timeIntervalSince1970)
        #expect(originalCapture.expiresAt?.timeIntervalSince1970
            == setup.original.expiresAt?.timeIntervalSince1970)
        let count = try await MeetWebCredentials.save(
            captured: setup.cookies, to: setup.store, expectedCapture: setup.capture,
            validatesCallSignIn: true, transport: setup.transport
        )
        #expect(count == 1)
        #expect(await setup.transport.sent.count == 5)
        let stored = try #require(try await setup.store.currentSession())
        #expect(stored.capturedAt == setup.original.capturedAt)
        #expect(stored.credential["OTZ"] == "fresh-OTZ")
    }

    @Test(arguments: [false, true])
    func distinctStoredMetadataStillRejectsCallCookiesBeforeVerification(expiry: Bool) async throws {
        let date = Date(timeIntervalSinceReferenceDate: 813_683_184)
        let setup = try await setup(
            MeetDMCallTrialTests().preparingResponses()[0], capturedAt: date, expiresAt: date
        )
        let replacement = StoredSession(
            credential: setup.original.credential,
            capturedAt: expiry ? date : date.addingTimeInterval(0.000001),
            expiresAt: expiry ? date.addingTimeInterval(0.000001) : date
        )
        try await setup.store.store(replacement)
        await #expect(throws: MeetWebCaptureError.sessionChangedDuringVerification) {
            try await MeetWebCredentials.save(
                captured: setup.cookies, to: setup.store, expectedCapture: setup.capture,
                validatesCallSignIn: true, transport: setup.transport
            )
        }
        #expect(await setup.transport.sent.isEmpty)
        #expect(try await setup.store.currentSession() == replacement)
    }

    @Test func anotherLoginDuringCallingShellValidationCannotReceiveVerifiedCookies() async throws {
        let setup = try await setup(MeetDMCallTrialTests().preparingResponses()[0])
        let replacement = StoredSession(
            credential: setup.original.credential,
            capturedAt: setup.original.capturedAt.addingTimeInterval(1), expiresAt: nil
        )
        let transport = ReplacingShellTransport(
            base: setup.transport,
            store: setup.store,
            replacement: replacement
        )
        await #expect(throws: MeetWebCaptureError.sessionChangedDuringVerification) {
            try await MeetWebCredentials.save(
                captured: setup.cookies, to: setup.store, expectedCapture: setup.capture,
                validatesCallSignIn: true, transport: transport
            )
        }
        #expect(try await setup.store.currentSession() == replacement)
        #expect(await setup.transport.sent.count == 5)
    }

    private actor ReplacingShellTransport: HTTPTransport {
        let base: ScriptedTransport
        let store: KeychainCredentialStore
        let replacement: StoredSession

        init(base: ScriptedTransport, store: KeychainCredentialStore, replacement: StoredSession) {
            self.base = base
            self.store = store
            self.replacement = replacement
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let response = try await base.send(request)
            if request.url.path == "/call" {
                try await store.store(replacement)
            }
            return response
        }

        func stream(_ request: HTTPRequest) async throws -> HTTPStream {
            try await base.stream(request)
        }
    }
}
