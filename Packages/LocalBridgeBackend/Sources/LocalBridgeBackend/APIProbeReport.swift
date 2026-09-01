import Foundation
import GChatBridgeCore
import URLSessionTransport

/// The `/api/` probe, driven by the Keychain credential the login window stored.
///
/// This is the friendly half of the pair. `gchat-probe --api` needs a hand-made
/// devtools capture; this needs a sign-in the app already supports, which is the
/// credential path session 7 actually built.
///
/// It lives here rather than in the app because the app target is a shell, and
/// here rather than in the core because only this package may hold both the
/// Keychain and the protocol.
///
/// **Counts, lengths, statuses and field numbers. Never a value.** The report
/// this produces is pasted by a human into `findings.md`, and a world response
/// carries real colleagues' names and message snippets.
public enum APIProbeReport {
    /// The first line of a report: what the credential looked like before any
    /// request went out. A pure function so `theReportNeverCarriesACookieValueOrToken`
    /// can pin the wording without standing up a transport or a Keychain.
    public static func header(cookieCount: Int, byteCount: Int, hasToken: Bool) -> String {
        "session: \(cookieCount) cookies, \(byteCount) bytes; "
            + "xsrf token \(hasToken ? "present" : "absent")"
    }

    /// Every parameter defaults, so the app can call this with no arguments and
    /// therefore names no core type - which is what the containment lint checks
    /// for. Same shape as `LocalBridgeBackend.using(_:transport:)` in
    /// `SessionHandoff.swift`.
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints()
    ) async -> String {
        // Broken into one append-or-stop step per stage of the connect
        // sequence, each a function of its own, rather than one long body -
        // `swiftlint`'s `function_body_length` is a real signal here: this
        // function reads top to bottom as the sequence itself, and a stage
        // that grows a paragraph belongs in its own function anyway.
        var lines = ["gchat /api/ probe", ""]

        guard let cookies = await appendCredential(store: store, lines: &lines) else {
            return lines.joined(separator: "\n")
        }
        guard let bootstrapped = await appendBootstrap(
            cookies: cookies, transport: transport, endpoints: endpoints, lines: &lines
        ) else {
            return lines.joined(separator: "\n")
        }

        let client = ProtoAPIClient(
            transport: transport,
            endpoints: endpoints,
            credentials: bootstrapped.credentials,
            xsrfToken: bootstrapped.wiz.xsrfToken
        )
        guard await appendVerifiedCall(client: client, lines: &lines) else {
            return lines.joined(separator: "\n")
        }
        await appendLadder(client: client, lines: &lines)
        return lines.joined(separator: "\n")
    }

    /// The credential, or `nil` once the reason it is unusable has been
    /// appended - a Keychain that refuses is not the same as no session, and
    /// the two get different sentences.
    private static func appendCredential(
        store: KeychainCredentialStore,
        lines: inout [String]
    ) async -> SessionCookies? {
        let stored: StoredSession?
        do {
            stored = try await store.currentSession()
        } catch {
            lines.append("Keychain refused: \(KeychainDiagnosis.explain(error))")
            return nil
        }
        guard let stored else {
            lines.append("No session in the Keychain. Sign in through the login window.")
            return nil
        }
        // `StoredSession.credential` - not `.cookies`. Confirmed against
        // Auth/StoredSession.swift:35.
        return stored.credential
    }

    /// The bootstrap is what mints the xsrf token every `/api/` call needs, and
    /// it is also the only thing that can say whether the session still
    /// authenticates - an `/api/` failure with a dead credential would be
    /// uninterpretable. `nil` once "not signed in" or "bootstrap failed" has
    /// been appended.
    private static func appendBootstrap(
        cookies: SessionCookies,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        lines: inout [String]
    ) async -> (wiz: WizGlobalData, credentials: SessionCredentials)? {
        let credentials = SessionCredentials(cookies)
        let wiz: WizGlobalData
        do {
            wiz = try await Bootstrap(transport: transport).run(
                cookies: cookies,
                endpoints: endpoints
            )
        } catch {
            lines.append("bootstrap failed: \(error)")
            return nil
        }
        lines.append(header(
            cookieCount: cookies.count,
            byteCount: cookies.byteCount,
            hasToken: wiz.xsrfToken != nil
        ))
        guard wiz.isSignedIn else {
            lines.append("")
            lines.append("NOT SIGNED IN - the ladder would be meaningless. Sign in again.")
            return nil
        }
        return (wiz, credentials)
    }

    /// The one call §3.6 verified. `false` once "FAILED" has been appended -
    /// if this fails, nothing below it is evidence about request shapes, it is
    /// evidence about the machinery, so the ladder must not run.
    private static func appendVerifiedCall(
        client: ProtoAPIClient,
        lines: inout [String]
    ) async -> Bool {
        lines.append("")
        lines.append("get_self_user_status (the one verified call):")
        do {
            let response = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
            let encoding = await client.lastEncoding?.rawValue ?? "-"
            lines.append("  OK - encoding \(encoding), "
                + "user id \(response.userStatus.userID.id.count) chars")
            return true
        } catch {
            lines.append("  FAILED: \(error)")
            lines.append("")
            lines.append("Stopping: the machinery is what failed, not a request shape.")
            return false
        }
    }

    private static func appendLadder(client: ProtoAPIClient, lines: inout [String]) async {
        lines.append("")
        lines.append("paginated_world ladder:")
        let results = await WorldRequestLadder.run(WorldRequestLadder.rungs, with: client)
        lines.append(WorldRequestLadder.report(results))
        lines.append("")
        lines.append(verdict(for: results))
    }

    /// Rung 1 is expected to answer with field 11 and nothing else. A rung that
    /// returns materially more than the control is the answer §3.6 asked for.
    private static func verdict(for results: [WorldRungResult]) -> String {
        let control = results.first
        let controlFields = Set((control?.fields ?? []).map(\.number))
        let winners = results.dropFirst().filter { result in
            result.failure == nil && !Set(result.fields.map(\.number)).subtracting(controlFields).isEmpty
        }
        guard let first = winners.first else {
            return "No rung returned more than the control. "
                + "The answer is in neither reference - the next step is capturing "
                + "what Chat's own web client sends."
        }
        return "First rung to return more than the control: \(first.label)"
    }
}
