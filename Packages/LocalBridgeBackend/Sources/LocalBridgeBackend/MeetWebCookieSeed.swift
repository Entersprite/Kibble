import Foundation
import GChatBridgeCore
import URLSessionTransport

/// A cookie Kibble may seed into a temporary Meet web view. Values stay in
/// memory and are never written to a report.
public struct MeetWebCookieSeed: Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String

    public init(name: String, value: String, domain: String, path: String) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
    }
}

public enum MeetWebCaptureError: Error, Sendable, Equatable {
    case accountVerificationFailed(source: VerificationSource, issue: VerificationIssue)
    case accountMismatch
    case sessionChangedDuringVerification
    case callSignInVerificationFailed

    public enum VerificationSource: String, Sendable {
        case storedChat = "Stored Chat"
        case capturedBrowser = "Temporary browser"
    }

    public enum VerificationIssue: Sendable, Equatable {
        case missingCookies
        case signedOut
        case signInRedirect
        case unsupportedClient
        case shellHTTP(Int)
        case unrecognizedShell
        case shellTransport
        case identityHTTP(Int)
        case identityResponse
        case identityTransport
        case missingIdentity

        var description: String {
            switch self {
            case .missingCookies: "no Chat-scoped cookies"
            case .signedOut: "Chat shell is signed out"
            case .signInRedirect: "Chat redirected to Google sign-in"
            case .unsupportedClient: "Chat rejected the browser"
            case let .shellHTTP(status): "Chat shell returned HTTP \(status)"
            case .unrecognizedShell: "Chat shell was not recognized"
            case .shellTransport: "Chat shell request failed"
            case let .identityHTTP(status): "account request returned HTTP \(status)"
            case .identityResponse: "account response could not be decoded"
            case .identityTransport: "account request failed"
            case .missingIdentity: "account response had no user ID"
            }
        }
    }

    /// Fixed descriptions and status numbers only. Underlying errors may carry
    /// credential-bearing URLs, so they never become part of this text.
    public var verificationDescription: String? {
        if self == .callSignInVerificationFailed {
            return "Calling sign-in could not be verified."
        }
        guard case let .accountVerificationFailed(source, issue) = self else { return nil }
        return "\(source.rawValue): \(issue.description)."
    }
}

public enum MeetWebCredentials {
    /// A Meet-only cookie remains tied to this device's Chat session. A fresh
    /// Chat login replaces the whole stored session and discards it.
    static func isMeetSpecific(domain: String?) -> Bool {
        guard let domain else { return false }
        return domain.lowercased() == "meet.google.com" || domain.lowercased() == ".meet.google.com"
    }

    public static func meetCookies(from captured: [CapturedCookie]) -> [SessionCookies.Cookie] {
        captured.compactMap { cookie in
            guard isMeetSpecific(domain: cookie.domain), cookie.path.hasPrefix("/") else { return nil }
            return SessionCookies.Cookie(
                name: cookie.name, value: cookie.value,
                domain: cookie.domain.lowercased(), path: cookie.path
            )
        }
    }

    /// Saves only Meet-host cookies. Shared Google cookies still come from the
    /// Chat session, so a temporary WebKit sign-in cannot replace that account.
    /// Normal login pins the exact preceding Chat capture; cookie rotations
    /// may continue, but another login must not adopt this browser's cookies.
    public static func save(
        captured: [CapturedCookie],
        to store: KeychainCredentialStore,
        expectedCapture: CookieCapture? = nil,
        validatesCallSignIn: Bool = false,
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints()
    ) async throws -> Int {
        var selected = meetCookies(from: captured)
        guard !selected.isEmpty else { return 0 }
        guard let existing = try await store.currentSession() else { return 0 }
        if let expectedCapture {
            // Compare the Unix seconds actually encoded by the Keychain store.
            // Converting Date's reference epoch to Unix seconds can round away
            // one bit; a raw Date comparison would reject the same saved login.
            guard let expected = expectedCapture.session,
                  expected.capturedAt.timeIntervalSince1970 == existing.capturedAt.timeIntervalSince1970,
                  expected.expiresAt?.timeIntervalSince1970 == existing.expiresAt?.timeIntervalSince1970
            else { throw MeetWebCaptureError.sessionChangedDuringVerification }
        }
        guard let candidate = chatCookies(from: captured) else {
            throw MeetWebCaptureError.accountVerificationFailed(
                source: .capturedBrowser, issue: .missingCookies
            )
        }
        let currentID = try await accountID(
            for: existing.credential,
            source: .storedChat,
            transport: transport,
            endpoints: endpoints
        )
        let candidateID = try await accountID(
            for: candidate, source: .capturedBrowser, transport: transport, endpoints: endpoints
        )
        guard currentID == candidateID else { throw MeetWebCaptureError.accountMismatch }
        if validatesCallSignIn {
            selected = try await validatedCallCookies(
                selected, expected: existing, store: store, transport: transport, endpoints: endpoints
            )
        }
        return try await store.mergeMeetCookies(selected, expectedStored: existing) ? selected.count : 0
    }

    static func chatCookies(from captured: [CapturedCookie]) -> SessionCookies? {
        SessionCookies(cookies: captured.compactMap { cookie in
            guard CookieScope.chat.admits(
                domain: cookie.domain, path: cookie.path, isSecure: cookie.isSecure
            ) else { return nil }
            return SessionCookies.Cookie(
                name: cookie.name, value: cookie.value,
                domain: cookie.domain.lowercased(), path: cookie.path
            )
        })
    }

    private static func accountID(
        for cookies: SessionCookies,
        source: MeetWebCaptureError.VerificationSource,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints
    ) async throws -> String {
        let wiz: WizGlobalData
        do {
            wiz = try await Bootstrap(transport: transport).run(cookies: cookies, endpoints: endpoints)
        } catch let error as BootstrapFailure {
            throw MeetWebCaptureError.accountVerificationFailed(source: source, issue: shellIssue(for: error))
        } catch {
            throw MeetWebCaptureError.accountVerificationFailed(source: source, issue: .shellTransport)
        }
        guard wiz.isSignedIn else {
            throw MeetWebCaptureError.accountVerificationFailed(source: source, issue: .signedOut)
        }
        let response: GetSelfUserStatusResponse
        do {
            response = try await ProtoAPIClient(
                transport: transport, endpoints: endpoints,
                credentials: SessionCredentials(cookies), xsrfToken: wiz.xsrfToken
            ).call(.getSelfUserStatus, GetSelfUserStatusRequest())
        } catch let error as APIFailure {
            throw MeetWebCaptureError.accountVerificationFailed(
                source: source,
                issue: identityIssue(for: error)
            )
        } catch {
            throw MeetWebCaptureError.accountVerificationFailed(source: source, issue: .identityTransport)
        }
        let id = response.userStatus.userID.id
        guard !id.isEmpty else {
            throw MeetWebCaptureError.accountVerificationFailed(source: source, issue: .missingIdentity)
        }
        return id
    }

    private static func shellIssue(for error: BootstrapFailure) -> MeetWebCaptureError.VerificationIssue {
        switch error {
        case let .unexpectedStatus(status): .shellHTTP(status)
        case .noGlobalData: .unrecognizedShell
        case .unsupportedClient: .unsupportedClient
        case .signInRedirect: .signInRedirect
        }
    }

    private static func identityIssue(for error: APIFailure) -> MeetWebCaptureError.VerificationIssue {
        switch error {
        case let .httpStatus(status): .identityHTTP(status)
        case .transport: .identityTransport
        case .emptyBody, .undecodable: .identityResponse
        }
    }

    static func preservingMeetCookies(
        from stored: SessionCookies, in rotated: SessionCookies
    ) -> SessionCookies {
        let missing = stored.cookies.filter { prior in
            isMeetSpecific(domain: prior.domain) && !rotated.cookies.contains { current in
                current.name == prior.name && current.domain == prior.domain && current.path == prior.path
            }
        }
        return SessionCookies(cookies: rotated.cookies + missing)!
    }

    /// Reuse only cookies that a browser would send to Meet. Chat-host-only
    /// cookies cannot authenticate Meet and must not be copied to it.
    public static func seeds(from store: any CredentialStore) async throws -> [MeetWebCookieSeed] {
        guard let session = try await store.currentSession(),
              !session.isExpired(at: .now),
              let meet = URL(string: "https://meet.google.com/")
        else { return [] }
        return session.credential.cookies.compactMap { cookie in
            guard cookie.isSent(to: meet), let domain = cookie.domain else { return nil }
            return MeetWebCookieSeed(
                name: cookie.name, value: cookie.value, domain: domain,
                path: cookie.path ?? "/"
            )
        }
    }
}
