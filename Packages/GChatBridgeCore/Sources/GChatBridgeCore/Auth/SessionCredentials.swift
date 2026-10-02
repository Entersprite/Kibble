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

    public init(
        _ cookies: SessionCookies,
        onRotation: (@Sendable (SessionCookies) async -> Void)? = nil
    ) {
        jar = CookieJar(cookies)
        self.onRotation = onRotation
    }

    /// The `Cookie` header value as it stands **now**, not as it was captured.
    public func header() -> String {
        jar.headerValue
    }

    /// The current state, for persisting back to the credential store.
    public var snapshot: SessionCookies? {
        jar.snapshot
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
        await onRotation?(snapshot)
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
}
