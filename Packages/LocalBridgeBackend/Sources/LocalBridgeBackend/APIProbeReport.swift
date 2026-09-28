import ChatKit
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
    /// `conversationIndexOverride` is `--probe-conversation=N` in `MacHost`'s
    /// `LaunchProbes.swift` - parsed there, not here, so this package keeps
    /// reading no `CommandLine` state and the containment lint's shape is
    /// undisturbed. `nil` keeps the default: the most recently active
    /// conversation, per `APIProbeReport+History.swift`'s own doc comment.
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        conversationIndexOverride: Int? = nil
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
            cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
        ) else {
            return lines.joined(separator: "\n")
        }

        let client = ProtoAPIClient(
            transport: transport,
            endpoints: endpoints,
            credentials: bootstrapped.credentials,
            xsrfToken: bootstrapped.wiz.xsrfToken
        )
        // `selfUserID` is this account's own id, string-compared later against
        // `ReadReceipt.user` to label a receipt `self`/`other` - never
        // printed itself. `nil` when the verified call fails outright (in
        // which case the whole report already stops below) or, in principle,
        // if a future response ever carried an empty id.
        var selfUserID: String?
        guard await appendVerifiedCall(client: client, selfUserID: &selfUserID, lines: &lines) else {
            return lines.joined(separator: "\n")
        }
        await appendLadder(
            client: client,
            selfUserID: selfUserID,
            conversationIndexOverride: conversationIndexOverride,
            lines: &lines
        )
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
        store: KeychainCredentialStore,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        lines: inout [String]
    ) async -> (wiz: WizGlobalData, credentials: SessionCredentials)? {
        // Same convention as `LocalBridgeBackend.using(_:transport:)` in
        // `SessionHandoff.swift`: the six live requests this probe makes rotate
        // the `*SIDCC` family on essentially every one of them (`findings.md`
        // §12.3), and a rotation not written back leaves the Keychain holding a
        // staler credential than the one the probe started with. `capturedAt`
        // and `expiresAt` are not refreshed - a rotation is the same session
        // continuing, not a new sign-in, and refreshing them would make the
        // nine-day `COMPASS` fuse look like it never burned down.
        let credentials = SessionCredentials(cookies, onRotation: { rotated in
            try? await store.replaceCredential(with: rotated)
        })
        let wiz: WizGlobalData
        do {
            wiz = try await Bootstrap(transport: transport).run(
                cookies: cookies,
                endpoints: endpoints
            )
        } catch {
            lines.append("bootstrap failed: \(safeDescription(of: error))")
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
    ///
    /// Also the only place this account's own id is ever read, so it can
    /// resolve a read receipt to `self`/`other` further down the report -
    /// `selfUserID` is set on success and left `nil` otherwise, never printed.
    private static func appendVerifiedCall(
        client: ProtoAPIClient,
        selfUserID: inout String?,
        lines: inout [String]
    ) async -> Bool {
        lines.append("")
        lines.append("get_self_user_status (the one verified call):")
        do {
            let response = try await client.call(.getSelfUserStatus, GetSelfUserStatusRequest())
            let encoding = await client.lastEncoding?.rawValue ?? "-"
            lines.append("  OK - encoding \(encoding), "
                + "user id \(response.userStatus.userID.id.count) chars")
            let id = response.userStatus.userID.id
            selfUserID = id.isEmpty ? nil : id
            return true
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            lines.append("")
            lines.append("Stopping: the machinery is what failed, not a request shape.")
            return false
        }
    }

    /// A description safe for a report a human pastes into `findings.md`.
    ///
    /// `\(error)` interpolates whatever `description` the concrete error type
    /// happens to have, and nothing here can vouch for that staying free of
    /// request content — `Bootstrap.run`'s `transport.send` in particular is
    /// unguarded, so a live transport failure arrives as whatever type
    /// `URLSessionTransport` (or a future transport) throws, not as a type
    /// this package controls. `BootstrapFailure`'s own cases are already
    /// scrubbed to counts, statuses and a capped title (`Bootstrap.swift`),
    /// so those print verbatim; `APIFailure` uses its own `safeDescription`
    /// for the same reason; anything else is reduced to its type name, which
    /// cannot carry a cookie or a token the way an arbitrary `description` is
    /// free to.
    /// Not `private`: `APIProbeReport+History.swift`'s topics-ladder section
    /// needs the same scrubbing rule for its own `/api/` calls, the same
    /// reason `appendMappingSummary` below is not `private` either.
    static func safeDescription(of error: any Error) -> String {
        if let failure = error as? BootstrapFailure {
            return String(describing: failure)
        }
        if let failure = error as? APIFailure {
            return failure.safeDescription
        }
        return String(describing: type(of: error))
    }

    private static func appendLadder(
        client: ProtoAPIClient,
        selfUserID: String?,
        conversationIndexOverride: Int?,
        lines: inout [String]
    ) async {
        lines.append("")
        lines.append("paginated_world ladder:")
        let results = await WorldRequestLadder.run(WorldRequestLadder.rungs, with: client)
        lines.append(WorldRequestLadder.report(results))
        lines.append("")
        lines.append(verdict(for: results))
        lines.append("")
        appendNestedItemShapes(results, lines: &lines)
        lines.append("")
        let mapping = await appendMappingSummary(client: client, lines: &lines)
        lines.append("")
        // The topics ladder - step 6 of this slice - runs against one of the
        // conversations the world call already produced, rather than a
        // second `paginated_world` round trip just to get one to probe.
        await appendTopicsLadderSection(
            client: client,
            mapping: mapping,
            selfUserID: selfUserID,
            conversationIndexOverride: conversationIndexOverride,
            lines: &lines
        )
    }

    /// §20.4's `[Verify]`: the ladder's own scan is top-level only, so which
    /// `WorldItemLite` fields are actually populated has never been observed.
    /// Field numbers, wire types and byte counts - the same vocabulary the
    /// top-level report already uses, never a value.
    private static func appendNestedItemShapes(_ results: [WorldRungResult], lines: inout [String]) {
        lines.append("world_item nested shape (field numbers inside each field-4 entry):")
        var any = false
        for result in results {
            guard !result.worldItemFields.isEmpty else { continue }
            any = true
            lines.append("  \(result.label):")
            for (index, fields) in result.worldItemFields.enumerated() {
                let rendered = fields
                    .map { "\($0.number):w\($0.wireType)=\($0.byteCount)B" }
                    .joined(separator: " ")
                lines.append("    item \(index + 1): \(rendered.isEmpty ? "(none)" : rendered)")
            }
        }
        if !any {
            lines.append("  no world_items in any rung")
        }
    }

    /// Runs `WorldMapping` over rung 2 - the shape `findings.md` §20.1 proved
    /// works, and the one `LocalBridgeBackend.loadConversations()` actually
    /// sends. **Counts only** - never a room name, a member id, a title or
    /// any other value the mapping produced. A second `/api/` call rather than
    /// reusing the ladder's own rung-2 bytes: the ladder deliberately never
    /// keeps a typed message or raw bytes around (`WorldRungResult`'s whole
    /// contract), and this is the one place in the probe that needs one.
    ///
    /// Not `private`, and returns the mapped conversations alongside the raw
    /// `world_items` they came from: `appendLadder` hands both to
    /// `APIProbeReport+History.swift`'s topics-ladder section, which needs
    /// one real conversation's `GroupId` to probe, and (since session 29's
    /// read-position diagnosis) the matching item's own `read_state` to
    /// report the probed conversation's own read-position figures against.
    /// `([], [])` on failure, the same "nothing to report further" the
    /// empty-array return already implied before this had a caller outside
    /// this file.
    static func appendMappingSummary(
        client: ProtoAPIClient,
        lines: inout [String]
    ) async -> (conversations: [Conversation], worldItems: [WorldItemLite]) {
        lines.append("world mapping summary (rung 2):")
        let rung = WorldRequestLadder.minimumViable
        let response: PaginatedWorldResponse
        do {
            response = try await client.call(.paginatedWorld, rung.request)
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return ([], [])
        }
        let mapped = WorldMapping.map(response)
        let conversations = mapped.conversations
        let spaces = conversations.count(where: { $0.kind == .space })
        lines.append("  conversations: \(conversations.count), skipped: \(mapped.skipped)")
        lines.append("  spaces: \(spaces), DMs: \(conversations.count - spaces)")
        lines.append(
            "  with title: \(conversations.count(where: { $0.title != nil })), "
                + "with avatar: \(conversations.count(where: { $0.avatarURL != nil }))"
        )
        lines.append(threadingAndUnreadLine(conversations))
        lines.append(
            "  total members across all conversations: \(conversations.reduce(0) { $0 + $1.members.count })"
        )
        appendFieldPresenceCounts(response.worldItems, lines: &lines)
        lines.append(contentsOf: membershipCountLines(response.worldItems, conversations: conversations))
        await appendMemberResolutionSummary(conversations: conversations, client: client, lines: &lines)
        return (conversations, response.worldItems)
    }

    /// One `get_members` call over the union of every rung-2 conversation's
    /// members - the same request `LocalBridgeBackend.resolveAndEmitMembers`
    /// sends. **Counts only** - never a name, an email, an avatar URL or a
    /// member id; `MemberMapping`'s own doc comment carries the same posture
    /// `WorldMapping`'s does toward `WorldItemLite`, and `get_members` has
    /// never been sent by this implementation before this call, so this is
    /// this call's first live evidence, not a confirmed shape.
    private static func appendMemberResolutionSummary(
        conversations: [Conversation],
        client: ProtoAPIClient,
        lines: inout [String]
    ) async {
        lines.append("member resolution summary (get_members):")
        let ids = Array(Set(conversations.flatMap(\.members)))
        lines.append("  member ids collected: \(ids.count)")
        guard !ids.isEmpty else { return }

        var request = GetMembersRequest()
        request.requestHeader = APIRequestHeader.make()
        request.memberIds = ids.map { id in
            var userID = UserId()
            userID.id = id.rawValue
            var memberID = MemberId()
            memberID.userID = userID
            return memberID
        }

        let response: GetMembersResponse
        do {
            response = try await client.call(.getMembers, request)
        } catch {
            lines.append("  FAILED: \(safeDescription(of: error))")
            return
        }
        lines.append("  members returned: \(response.members.count)")
        let mapped = MemberMapping.map(response)
        lines.append(
            "  resolved with a name: \(mapped.members.count(where: { $0.displayName != nil })), "
                + "app: \(mapped.members.count(where: { $0.kind == .app })), "
                + "skipped (empty id): \(mapped.skipped)"
        )
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
