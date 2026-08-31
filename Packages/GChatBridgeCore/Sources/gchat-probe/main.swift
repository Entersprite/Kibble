import Foundation
import GChatBridgeCore
import URLSessionTransport

/// Phase 0's probe, in Swift: does *this* implementation reach Google and get a
/// signed-in app shell?
///
/// It answers exactly one question — the same one `probe.py` answered for
/// criterion 1 — and it answers it with the real package rather than a script,
/// which is the only way to learn that the Swift stack works.
///
/// **It prints no cookie values, no tokens and no message content**, only
/// counts, lengths and names. It also calls nothing but the bootstrap: no
/// `register`, so it cannot rotate `COMPASS` and cannot disturb a browser
/// session the way a channel registration can.
@main
enum Probe {
    /// Where the captured header lives.
    ///
    /// `GCHAT_COOKIE_HEADER_PATH` overrides it — needed because
    /// `homeDirectoryForCurrentUser` reads the passwd entry and **ignores
    /// `HOME`**, so there is otherwise no way to point this at a scratch file
    /// (which makes it impossible to exercise without a real session).
    static var headerPath: URL {
        if let override = ProcessInfo.processInfo.environment["GCHAT_COOKIE_HEADER_PATH"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gchat-probe-cookie-header.txt")
    }

    static func main() async {
        print("gchat-probe — bootstrap only, no register\n")

        guard let cookies = loadCookies() else { exit(2) }
        print("cookie header: \(cookies.count) cookies, \(cookies.byteCount) bytes")
        reportCookieFamilies(cookies)

        // A wrong account index fails identically to bad credentials, so try the
        // shapes rather than making the user guess. Bootstrap is read-only, so
        // trying twice costs nothing.
        let candidates: [ChatEndpoints.Account] = accountOverride().map { [$0] } ?? [.index(0), .none]
        let transport = URLSessionTransport()

        for account in candidates {
            let endpoints = ChatEndpoints(account: account)
            print("\n--- \(label(account)) ---")
            do {
                let wiz = try await Bootstrap(transport: transport)
                    .run(cookies: cookies, endpoints: endpoints)
                print("  \(wiz)")
                if wiz.isSignedIn {
                    print("\nSIGNED IN — the Swift stack reached Chat and was accepted.")
                    print("criterion 1 (bootstrap) in Swift: PASS")
                    exit(0)
                }
                print("  not signed in (qwAQke = \(wiz.appName ?? "absent"))")
            } catch {
                print("  failed: \(error)")
            }
        }

        print("""

        NOT SIGNED IN under any account shape tried.

        Two causes look identical here, and the second is not a credential
        problem at all:
          - the captured header is stale        -> re-capture, see
                                                  docs/protocol/cookie-capture.md
          - the account index is wrong          -> set GCHAT_ACCOUNT_INDEX=1 (etc)
        """)
        exit(1)
    }

    // MARK: - Input

    static func loadCookies() -> SessionCookies? {
        guard let raw = try? String(contentsOf: headerPath, encoding: .utf8) else {
            print("""
            No cookie header at \(headerPath.path)

            Capture one first — docs/protocol/cookie-capture.md. Short version:
            a separate browser profile, DevTools > Network > a completed request
            to chat.google.com > Request Headers > copy the `cookie:` line, then

                umask 077 && pbpaste > ~/.gchat-probe-cookie-header.txt
            """)
            return nil
        }
        // The runbook allows a leading `cookie:`, since that is what copying the
        // header line gives you.
        var header = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if header.lowercased().hasPrefix("cookie:") {
            header = String(header.dropFirst("cookie:".count))
                .trimmingCharacters(in: .whitespaces)
        }
        guard let cookies = SessionCookies(header: header) else {
            print("The file at \(headerPath.path) held no usable cookies.")
            return nil
        }
        return cookies
    }

    /// Names, never values. The absence of the `__Secure-*PSID*` family is the
    /// single best predictor of a capture that will not authenticate: the
    /// reference implementation's five-cookie list omits it entirely.
    static func reportCookieFamilies(_ cookies: SessionCookies) {
        let names = cookies.cookies.map(\.name)
        let modern = names.filter {
            $0.contains("PSID") || $0.contains("SAPISID") || $0.contains("APISID")
        }
        print(
            "  modern-auth cookies: \(modern.isEmpty ? "NONE (suspicious)" : modern.joined(separator: ", "))"
        )
    }

    static func accountOverride() -> ChatEndpoints.Account? {
        guard let raw = ProcessInfo.processInfo.environment["GCHAT_ACCOUNT_INDEX"] else {
            return nil
        }
        if raw.lowercased() == "none" {
            return ChatEndpoints.Account.none
        }
        return Int(raw).map { ChatEndpoints.Account.index($0) }
    }

    static func label(_ account: ChatEndpoints.Account) -> String {
        switch account {
        case let .index(index): "account index /u/\(index)"
        case .none: "no account index"
        }
    }
}
