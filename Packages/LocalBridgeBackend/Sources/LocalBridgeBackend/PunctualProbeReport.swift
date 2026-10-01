import ChatKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// `--probe=punctual`: watches the availability of everyone the presence poll
/// asks about, on Punctual, for a fixed time, and reports every push as its
/// shape (`findings.md` §47).
///
/// Chat on the web gets "In a meeting" from somewhere that is neither status
/// call (§46.4), and it watches each person's `availability` on Punctual
/// instead of polling (§46.6). No push has been seen, so this exists to see
/// one.
///
/// **Counts, lengths and shapes. Never a value**, the api probe's rule. The
/// log is rewritten after every line through `flush`, so a run that is killed
/// keeps what it saw.
public enum PunctualProbeReport {
    public static let defaultDuration: Duration = .seconds(600)

    /// Every parameter but `flush` defaults, so `MacHost` names no core type.
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        serverPath: String? = nil,
        duration: Duration = defaultDuration,
        flush: @escaping @Sendable (String) -> Void
    ) async -> String {
        let log = PunctualProbeLog(flush: flush)
        let server = serverPath ?? PunctualRequests.observedServerPath
        // On disk before the first request (review finding 8).
        for line in header(server: server, duration: duration) {
            await log.append(line)
        }
        var lines: [String] = []
        let prepared = await prepare(store: store, transport: transport, endpoints: endpoints, lines: &lines)
        for line in lines {
            await log.append(line)
        }
        guard let prepared else {
            return await log.lines.joined(separator: "\n")
        }
        await PunctualWatchRun.run(
            people: prepared.people,
            requests: PunctualRequests(endpoints: endpoints, serverPath: server, key: prepared.key),
            client: prepared.client,
            settings: PunctualWatchRun.Settings(
                duration: duration,
                firstRID: Int.random(in: 10000 ... 99999),
                zx: { randomZX() },
                now: { Date() },
                reopenGap: .seconds(1),
                maximumEmptyPolls: 20,
                sleep: { try? await Task.sleep(for: $0) }
            ),
            log: log
        )
        return await log.lines.joined(separator: "\n")
    }

    /// The config row `CLAUDE.md` asks every trace for, so a report says which
    /// build and settings produced it.
    static func header(server: String, duration: Duration) -> [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return [
            "gchat Punctual probe",
            "config: build \(version) (\(build)), server path \(server), "
                + "choose server topic: availability, duration \(duration.components.seconds)s, "
                + "started \(ISO8601DateFormatter().string(from: Date()))",
            "Strings print as their length (s<n>, or w<n> for a lowercase word), people as numbers, "
                + "times relative to now. Read it before pasting it anywhere all the same.",
            ""
        ]
    }

    private struct Prepared {
        let client: PunctualClient
        let key: String
        let people: [PunctualWatchRun.Person]
    }

    /// The api probe's own opening, then the key and the people. `nil` once
    /// the reason to stop has been appended.
    private static func prepare(
        store: KeychainCredentialStore,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        lines: inout [String]
    ) async -> Prepared? {
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines),
              let bootstrapped = await APIProbeReport.appendBootstrap(
                  cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
              )
        else { return nil }
        let api = ProtoAPIClient(
            transport: transport,
            endpoints: endpoints,
            credentials: bootstrapped.credentials,
            xsrfToken: bootstrapped.wiz.xsrfToken
        )
        let punctual = PunctualClient(transport: transport, credentials: bootstrapped.credentials)
        var selfUserID: String?
        guard await APIProbeReport.appendVerifiedCall(client: api, selfUserID: &selfUserID, lines: &lines)
        else { return nil }

        lines.append("")
        lines.append("mole shell: \(bootstrapped.wiz)")
        let key: String
        if let home = await appHomeKey(client: punctual, endpoints: endpoints, lines: &lines) {
            key = home
            lines.append("key source: app/home")
        } else if let mole = bootstrapped.wiz.punctualKey {
            key = mole
            lines.append("key source: mole shell")
        } else {
            lines.append("Stopping: no Punctual key (Tzliq) in /app/home or the mole shell.")
            return nil
        }
        lines.append("")
        let people = await people(client: api, selfUserID: selfUserID, lines: &lines)
        guard !people.isEmpty else {
            lines.append("Stopping: nobody to watch.")
            return nil
        }
        lines.append("")
        return Prepared(client: punctual, key: key, people: people)
    }

    /// `/app/home` is the page the capture found `Tzliq` on.
    private static func appHomeKey(
        client: PunctualClient,
        endpoints: ChatEndpoints,
        lines: inout [String]
    ) async -> String? {
        let request = HTTPRequest(
            url: endpoints.base.appendingPathComponent("app").appendingPathComponent("home"),
            headers: HTTPHeaders([("User-Agent", endpoints.userAgent)]),
            traceLabel: "app-home"
        )
        do {
            let response = try await client.send(request)
            let wiz = WizGlobalData(html: String(decoding: response.body, as: UTF8.self))
            lines.append("app/home: status \(response.status), \(response.body.count) bytes, "
                + (wiz.map { "\($0)" } ?? "no WIZ blob"))
            return wiz?.punctualKey
        } catch {
            lines.append("app/home failed: \(APIProbeReport.safeDescription(of: error))")
            return nil
        }
    }

    /// The people the app's presence poll asks about: the world load's
    /// members, named by `get_members`, humans only. Numbered in answer
    /// order, never by id, with the local user labelled `self`.
    private static func people(
        client: ProtoAPIClient,
        selfUserID: String?,
        lines: inout [String]
    ) async -> [PunctualWatchRun.Person] {
        let world: PaginatedWorldResponse
        do {
            world = try await client.call(.paginatedWorld, WorldRequestLadder.minimumViable.request)
        } catch {
            lines.append("paginated_world failed: \(APIProbeReport.safeDescription(of: error))")
            return []
        }
        let conversations = WorldMapping.map(world).conversations
        let members = await APIProbeReport.appendMemberResolutionSummary(
            conversations: conversations, client: client, lines: &lines
        )
        let people = ordered(
            LocalBridgeBackend.presenceTargets(from: members).map(\.rawValue), selfUserID: selfUserID
        )
        let others = people.count(where: { $0.label != "self" })
        lines
            .append("watching: \(people.count) (\(others) others" +
                (people.count > others ? " and self)" : ")"))
        return people
    }

    /// `self` first: the owner can change their own state on demand, and the
    /// first watch is the one on the channel even if an add is refused. The
    /// others are numbered in the order given, never by id.
    static func ordered(_ ids: [String], selfUserID: String?) -> [PunctualWatchRun.Person] {
        let me = ids.filter { $0 == selfUserID }.prefix(1)
            .map { PunctualWatchRun.Person(id: $0, label: "self") }
        let others = ids.filter { $0 != selfUserID }.enumerated().map { index, id in
            PunctualWatchRun.Person(id: id, label: "person \(index + 1)")
        }
        return me + others
    }

    /// The capture's `zx` values are 12 lowercase letters and digits.
    private static func randomZX() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< 12).map { _ in alphabet.randomElement()! })
    }
}
