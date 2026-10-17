import Foundation

/// The live credential for one session, shared by everything that talks to Chat.
///
/// ## Why this is an actor and not a value
///
/// `findings.md` §12.3 measured **13 rotations in 100 seconds**: the `*SIDCC`
/// family rotates on every long-poll cycle, and `COMPASS` grew from 823 to 1029
/// characters on `register`. A component holding its own copy of the jar is
/// therefore holding a credential that went stale seconds after it was handed
/// over.
///
/// The channel is no longer the only thing that needs cookies — the `/api/`
/// request family needs them too — so the mutable state lives here, in one
/// place both hold, rather than being copied and left to diverge.
///
/// `SessionCookies` remains the immutable snapshot a `CredentialStore` hands
/// out. This is what a live session carries, and `snapshot` is what should be
/// written back so the next launch starts from rotated values.
public actor SessionCredentials {
    private var jar: CookieJar
    private let onRotation: (@Sendable (SessionCookies) async -> Void)?
    private var persistence: Task<Void, Never>?

    public init(
        _ cookies: SessionCookies,
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil
    ) {
        jar = CookieJar(cookies)
        self.onRotation = onRotation
    }

    /// Every cookie in the jar, flat, for tests and diagnostics; never what a
    /// request sends - see `authorising(_:withholding:)`.
    func header() -> String {
        jar.headerValue
    }

    /// The current state, for persisting back to the credential store.
    public var snapshot: SessionCookies? {
        jar.snapshot
    }

    /// Whether any cookie predates kept domains (`findings.md` §52.9). Such a
    /// session sends the download host nothing, so a download is refused
    /// before it is tried (`LocalBridgeBackend.downloadAttachment`). A count
    /// of names would do as well; this says only yes or no.
    public var hasUnscopedCookies: Bool {
        jar.snapshot?.cookies.contains { $0.domain == nil } ?? false
    }

    /// How many rotations have been seen. Test and probe reporting only - it is
    /// a count, never a value.
    func rotationCount() -> Int {
        jar.rotations.count
    }

    /// Applies every `Set-Cookie` from one response from `url`, and reports a
    /// snapshot **only when something actually changed**.
    ///
    /// `url` is the host that answered: a cookie with no `Domain` is that
    /// host's alone, and one whose `Domain` it does not match is ignored
    /// (`CookieJar`, `findings.md` §52.9).
    ///
    /// Only when: the credential store is on disk, and rewriting an unchanged
    /// session once per poll cycle is a write per second for as long as the app
    /// runs.
    public func absorb(_ headers: HTTPHeaders, from url: URL) async {
        let before = jar.rotations.count
        jar.absorb(setCookie: headers.setCookies, from: url)
        guard jar.rotations.count > before, let snapshot = jar.snapshot else { return }
        await persist(snapshot)
    }

    /// Installs already verified host credentials without replacing other
    /// domains or racing older rotation writes to the credential store.
    public func replaceCookies(_ cookies: [SessionCookies.Cookie], forDomains domains: Set<String>) async {
        guard cookies.allSatisfy({ $0.domain.map(domains.contains) == true }),
              jar.snapshot != nil else { return }
        jar.replaceCookies(cookies, forDomains: domains)
        if let snapshot = jar.snapshot {
            await persist(snapshot)
        }
    }

    private func persist(_ snapshot: SessionCookies) async {
        guard let onRotation else { return }
        let prior = persistence
        let task = Task {
            await prior?.value
            await onRotation(snapshot)
        }
        persistence = task
        await task.value
    }

    /// Returns the request with the cookies its URL admits attached, as they
    /// stand **now**, and no `Cookie` field at all when none does.
    ///
    /// Lives here rather than on each caller because the credential is the
    /// thing that knows what authorising means - and because the channel is no
    /// longer the only caller. `withholding` names cookies left out of this one
    /// request (`AttachmentFetch.RequestStyle`, a probe's experiment).
    func authorising(_ request: HTTPRequest, withholding names: Set<String> = []) -> HTTPRequest {
        guard let value = jar.header(for: request.url, withholding: names) else { return request }
        var request = request
        request.headers = HTTPHeaders(fields:
            request.headers.fields + [HTTPHeaders.Field(name: "Cookie", value: value)]
        )
        return request
    }

    /// Cookie header and proof come from one actor-isolated snapshot, so a
    /// concurrent rotation cannot sign one cookie and send another.
    func authorising(
        _ request: HTTPRequest,
        authorization: @Sendable (SessionCookies, URL) -> String?
    ) -> HTTPRequest {
        var authorised = authorising(request)
        if let snapshot = jar.snapshot, let proof = authorization(snapshot, request.url) {
            authorised.headers = HTTPHeaders(fields:
                authorised.headers.fields + [HTTPHeaders.Field(name: "Authorization", value: proof)]
            )
        }
        return authorised
    }
}
