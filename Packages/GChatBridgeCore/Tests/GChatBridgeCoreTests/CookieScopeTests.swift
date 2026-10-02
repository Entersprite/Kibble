import Testing
@testable import GChatBridgeCore

/// Which cookies a capture may replay to Chat.
///
/// The cases are drawn from the real inventory in `findings.md` §17.2/§17.3 —
/// a login capture holds cookies for several Google hosts, and sending them all
/// to one of them is not what a browser does.
struct CookieScopeTests {
    // MARK: - Domain matching

    @Test func aCookieOnTheExactHostIsAdmitted() {
        #expect(CookieScope.chat.admits(domain: "chat.google.com", path: "/", isSecure: true))
    }

    @Test func aCookieOnTheParentDomainIsAdmitted() {
        // The whole __Secure-*PSID* family rides on .google.com.
        #expect(CookieScope.chat.admits(domain: ".google.com", path: "/", isSecure: true))
    }

    @Test func aParentDomainWithALeadingDotIsAdmitted() {
        // Before `findings.md` §52.9 this fixture read "google.com" (no dot)
        // and still matched: the two spellings were treated as equivalent.
        // They are not — a leading dot is what makes this a domain cookie
        // rather than host-only, so the dot stays in the fixture.
        #expect(CookieScope.chat.admits(domain: ".google.com", path: "/", isSecure: true))
    }

    @Test func aSiblingHostIsRefused() {
        // LSID, SMSV, ACCOUNT_CHOOSER. A browser never sends these to Chat.
        #expect(!CookieScope.chat.admits(domain: "accounts.google.com", path: "/", isSecure: true))
    }

    @Test func anotherSiblingHostIsRefused() {
        // __utma, __utmz, _ga — analytics that swelled the header by 42 cookies.
        #expect(!CookieScope.chat.admits(domain: "workspace.google.com", path: "/", isSecure: true))
    }

    /// The reason matching cannot be `hasSuffix`.
    ///
    /// `"chat.google.com".hasSuffix("oogle.com")` is true, and a scope built on
    /// that would hand credentials to whoever registered the wrong domain. The
    /// suffix has to begin at a label boundary.
    @Test func aSuffixThatDoesNotBreakOnALabelBoundaryIsRefused() {
        #expect(!CookieScope.chat.admits(domain: "oogle.com", path: "/", isSecure: true))
    }

    @Test func anUnrelatedDomainIsRefused() {
        #expect(!CookieScope.chat.admits(domain: "example.com", path: "/", isSecure: true))
    }

    @Test func domainMatchingIgnoresCase() {
        #expect(CookieScope.chat.admits(domain: "Chat.Google.COM", path: "/", isSecure: true))
    }

    @Test func anEmptyDomainIsRefused() {
        #expect(!CookieScope.chat.admits(domain: "", path: "/", isSecure: true))
    }

    /// A host is not a subdomain of itself with a dot in front of the whole
    /// thing — but `.chat.google.com` is how a store may spell a domain-wide
    /// cookie set by that host, and it does match.
    @Test func theHostSpelledWithALeadingDotIsAdmitted() {
        #expect(CookieScope.chat.admits(domain: ".chat.google.com", path: "/", isSecure: true))
    }

    // MARK: - Path matching

    @Test func aCookieOnADeeperPathIsRefused() {
        #expect(!CookieScope.chat.admits(domain: ".google.com", path: "/mail", isSecure: true))
    }

    @Test func aCookieOnTheRootPathIsAdmittedForADeeperRequest() {
        let scope = CookieScope(host: "chat.google.com", path: "/u/0/mole/world", isSecure: true)
        #expect(scope.admits(domain: "chat.google.com", path: "/", isSecure: true))
    }

    @Test func aPathPrefixMustBreakOnASeparator() {
        // "/u/0" is not inside "/underscore" even though it is a string prefix.
        let scope = CookieScope(host: "chat.google.com", path: "/underscore", isSecure: true)
        #expect(!scope.admits(domain: "chat.google.com", path: "/u", isSecure: true))
    }

    @Test func anExactPathMatchIsAdmitted() {
        let scope = CookieScope(host: "chat.google.com", path: "/u/0", isSecure: true)
        #expect(scope.admits(domain: "chat.google.com", path: "/u/0", isSecure: true))
    }

    @Test func aTrailingSlashOnTheCookiePathIsAdmittedForADeeperRequest() {
        let scope = CookieScope(host: "chat.google.com", path: "/u/0/mole", isSecure: true)
        #expect(scope.admits(domain: "chat.google.com", path: "/u/", isSecure: true))
    }

    @Test func anEmptyCookiePathIsTreatedAsRoot() {
        #expect(CookieScope.chat.admits(domain: "chat.google.com", path: "", isSecure: true))
    }

    // MARK: - Secure

    @Test func aSecureCookieIsRefusedOverAnInsecureScope() {
        let scope = CookieScope(host: "chat.google.com", path: "/", isSecure: false)
        #expect(!scope.admits(domain: "chat.google.com", path: "/", isSecure: true))
    }

    @Test func anInsecureCookieIsAdmittedOverASecureScope() {
        #expect(CookieScope.chat.admits(domain: "chat.google.com", path: "/", isSecure: false))
    }

    // MARK: - The scope Chat is reached through

    @Test func theChatScopeIsTheHostTheProtocolActuallyTalksTo() {
        #expect(CookieScope.chat.host == "chat.google.com")
        #expect(CookieScope.chat.isSecure)
    }

    /// The capture defect from `findings.md` §17.3, as one assertion.
    ///
    /// These eight names are all real, from one real login. Five of them were
    /// being replayed to Chat and should never have been.
    @Test func theRealCaptureIsPartitionedTheWayABrowserWouldPartitionIt() {
        let captured: [(String, String)] = [
            ("COMPASS", "chat.google.com"),
            ("OSID", "chat.google.com"),
            ("__Secure-1PSID", ".google.com"),
            ("SAPISID", ".google.com"),
            ("LSID", "accounts.google.com"),
            ("__Host-GAPS", "accounts.google.com"),
            ("__Host-1PLSID", "accounts.google.com"),
            ("_ga", "workspace.google.com")
        ]
        let admitted = captured
            .filter { CookieScope.chat.admits(domain: $0.1, path: "/", isSecure: true) }
            .map(\.0)
        #expect(admitted == ["COMPASS", "OSID", "__Secure-1PSID", "SAPISID"])
    }

    // MARK: - Host-only cookies (findings.md §52.9)

    @Test("a domain without a leading dot is host-only: that host, and no subdomain")
    func hostOnly() {
        let chat = CookieScope(host: "chat.google.com", path: "/", isSecure: true)
        let deeper = CookieScope(host: "x.chat.google.com", path: "/", isSecure: true)
        #expect(chat.admits(domain: "chat.google.com", path: "/", isSecure: true))
        #expect(!deeper.admits(domain: "chat.google.com", path: "/", isSecure: true))
    }

    @Test("a leading dot covers the domain and every subdomain, at a label boundary")
    func domainCookie() {
        func admits(_ host: String) -> Bool {
            CookieScope(host: host, path: "/", isSecure: true).admits(
                domain: ".google.com",
                path: "/",
                isSecure: true
            )
        }
        #expect(admits("google.com"))
        #expect(admits("chat.usercontent.google.com"))
        #expect(!admits("oogle.com"))
        #expect(!admits("notgoogle.com"))
    }

    @Test("hosts compare without case")
    func caseInsensitive() {
        #expect(CookieScope(host: "Chat.Google.com", path: "/", isSecure: true)
            .admits(domain: "chat.google.com", path: "/", isSecure: true))
    }
}
