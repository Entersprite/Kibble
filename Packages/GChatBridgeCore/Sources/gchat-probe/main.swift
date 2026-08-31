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
        reportCaptureAge()
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

        print("")
        print("NOT SIGNED IN under any account shape tried.")
        print("")
        print("If the report above says 'redirected to accounts.google.com', the")
        print("cookies are not usable at all - which for a header that worked")
        print("minutes ago means it went stale, not that it was captured wrong.")
        print("")
        print("Most likely cause: the browser profile you captured from still has")
        print("Chat open, and is rotating SIDCC / __Secure-1PSIDCC /")
        print("__Secure-3PSIDCC server-side on every poll. Close the Chat tab in")
        print("that profile (stay signed in), re-capture, and run this within a")
        print("minute. See docs/protocol/cookie-capture.md step 5.")
        print("")
        print("If it says 'no shell markers', the response was not an app shell")
        print("and the title above says what it actually was. If it says THE")
        print("PARSER IS AT FAULT, the capture is fine and this code is wrong.")
        print("")
        print("A wrong account index fails identically to bad credentials:")
        print("try GCHAT_ACCOUNT_INDEX=1 (or =none).")
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
        let names = Set(cookies.cookies.map(\.name))
        let modern = names.filter {
            $0.contains("PSID") || $0.contains("SAPISID") || $0.contains("APISID")
        }
        print(
            "  modern-auth cookies: "
                + (modern.isEmpty ? "NONE (suspicious)" : modern.sorted().joined(separator: ", "))
        )

        // COMPASS in particular is set by Chat ITSELF, so a profile that signed
        // in but never fully loaded Chat has every other cookie and not that one.
        let missing = ["SID", "SSID", "HSID", "OSID", "COMPASS"].filter { !names.contains($0) }
        if missing.isEmpty {
            print("  classic five: all present")
            return
        }
        print("  classic five: MISSING \(missing.joined(separator: ", "))")
        guard missing.contains("COMPASS") else { return }
        print("    COMPASS is set by Chat itself. If it is absent, the capture was")
        print("    probably taken before Chat finished loading, or from a request to")
        print("    a different Google host. Open chat.google.com, wait for the roster")
        print("    to render, then re-copy from a chat.google.com request.")
    }

    /// How old the capture is.
    ///
    /// Captured headers have a shelf life measured in minutes: `SIDCC`,
    /// `__Secure-1PSIDCC` and `__Secure-3PSIDCC` rotate on every long-poll
    /// reopen, so a browser still running Chat keeps invalidating the copy on
    /// disk. Age is therefore the first thing worth knowing when a header that
    /// looked fine stops working.
    static func reportCaptureAge() {
        guard
            let modified = try? FileManager.default
            .attributesOfItem(atPath: headerPath.path)[.modificationDate] as? Date
        else { return }
        let age = Int(Date().timeIntervalSince(modified))
        let rendered = age < 60 ? "\(age)s" : "\(age / 60)m \(age % 60)s"
        print("  captured: \(rendered) ago")
        guard age > 120 else { return }
        print("    Older than two minutes. If this fails, re-capture before")
        print("    concluding anything: a live browser session rotates the *SIDCC")
        print("    cookies server-side and the copy on disk goes stale.")
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
