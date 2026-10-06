import ChatKit
import CryptoKit
import Foundation
import GChatBridgeCore
import URLSessionTransport

/// `--probe=people`: can this client search the directory the way Chat on the
/// web does while `@` is typed (`findings.md` §56.4, §57)?
///
/// One `ListAutocompletions` per rung: a control with no `Authorization`, then
/// each `SAPISIDHash.Variant`. All are reads. Then, for the first rung that
/// returns people, whether their ids are Chat user ids: up to five go through
/// `get_members`, and the emails are compared by equality.
///
/// **Counts and lengths, never a value**, the api probe's rule. The query is
/// the owner's and is reported by length.
public enum PeopleProbeReport {
    public static let defaultQuery = "a"

    /// Every parameter defaults, so `MacHost` names no core type.
    ///
    /// `flush` gets the report so far after every step, the Punctual probe's
    /// way, so a run that hangs leaves a file ending where it hung.
    public static func run(
        store: KeychainCredentialStore = KeychainCredentialStore(),
        transport: any HTTPTransport = URLSessionTransport(),
        endpoints: ChatEndpoints = ChatEndpoints(),
        query: String = defaultQuery,
        flush: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> String {
        var lines = header()
        func done() -> String {
            let text = lines.joined(separator: "\n")
            flush(text)
            return text
        }
        flush(lines.joined(separator: "\n"))
        guard let cookies = await APIProbeReport.appendCredential(store: store, lines: &lines) else {
            return done()
        }
        flush(lines.joined(separator: "\n"))
        guard let bootstrapped = await APIProbeReport.appendBootstrap(
            cookies: cookies, store: store, transport: transport, endpoints: endpoints, lines: &lines
        ) else { return done() }
        flush(lines.joined(separator: "\n"))
        let api = ProtoAPIClient(
            transport: transport,
            endpoints: endpoints,
            credentials: bootstrapped.credentials,
            xsrfToken: bootstrapped.wiz.xsrfToken
        )
        var selfUserID: String?
        guard await APIProbeReport.appendVerifiedCall(client: api, selfUserID: &selfUserID, lines: &lines)
        else { return done() }
        lines.append("")
        flush(lines.joined(separator: "\n"))

        // Cookies scoped per host, exactly as for Punctual: `PunctualClient`
        // is a plain scoped sender, whatever its name.
        let client = PunctualClient(transport: transport, credentials: bootstrapped.credentials)
        guard let key = await key(bootstrapped.wiz, client: client, endpoints: endpoints, lines: &lines)
        else {
            return done()
        }
        let jar = await bootstrapped.credentials.snapshot?.cookies ?? []
        lines.append(contentsOf: cookieLines(jar))
        lines.append("")

        lines.append("ListAutocompletions (query of \(query.count) characters):")
        flush(lines.joined(separator: "\n"))
        let search = Search(query: query, key: key, endpoints: endpoints)
        let people = await appendRungs(search, jar: jar, client: client, lines: &lines, flush: flush)
        lines.append("")
        lines.append("ids against get_members (up to 5 people from the first rung that returned any):")
        if let people {
            await appendMappingCheck(people, api: api, lines: &lines)
        } else {
            lines.append("  no rung returned a person with an id")
        }
        return done()
    }

    /// The config row `CLAUDE.md` asks every trace for.
    static func header() -> [String] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return [
            "gchat people probe",
            "config: build \(version) (\(build)), variants "
                + SAPISIDHash.Variant.allCases.map(\.rawValue).joined(separator: ","),
            ""
        ]
    }

    /// The Punctual key: `/app/home` first, where the capture found it, then
    /// the mole shell. The directory's key was the same one (§57).
    private static func key(
        _ wiz: WizGlobalData,
        client: PunctualClient,
        endpoints: ChatEndpoints,
        lines: inout [String]
    ) async -> String? {
        if let home = await PunctualProbeReport.appHomeKey(
            client: client,
            endpoints: endpoints,
            lines: &lines
        ) {
            lines.append("key: app/home, \(home.count) chars")
            return home
        }
        if let mole = wiz.punctualKey {
            lines.append("key: mole shell, \(mole.count) chars")
            return mole
        }
        lines.append("Stopping: no key (Tzliq) in /app/home or the mole shell.")
        return nil
    }

    /// Which hashed cookies this session holds for the people host: names
    /// and lengths.
    static func cookieLines(_ jar: [SessionCookies.Cookie]) -> [String] {
        ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"].map { name in
            let value = SAPISIDHash.value(of: name, in: jar, for: PeopleRequests.listAutocompletionsURL)
            return "cookie \(name) for the people host: " +
                (value.map { "present, \($0.count) chars" } ?? "absent")
        }
    }

    private struct Search {
        let query: String
        let key: String
        let endpoints: ChatEndpoints
    }

    /// One request. The control sends no header on purpose; a variant whose
    /// cookie is absent is skipped rather than sent unsigned.
    private struct Rung {
        let name: String
        let authorization: String?
        let available: Bool
    }

    /// Every rung, in order. Returns the first rung's people that came back
    /// with ids, as (id, email) pairs.
    private static func appendRungs(
        _ search: Search,
        jar: [SessionCookies.Cookie],
        client: PunctualClient,
        lines: inout [String],
        flush: (String) -> Void
    ) async -> [(id: String, email: String)]? {
        let (query, key, endpoints) = (search.query, search.key, search.endpoints)
        let input = SAPISIDHash.Input(
            cookies: jar, url: PeopleRequests.listAutocompletionsURL,
            origin: PeopleRequests.origin(of: endpoints), timestamp: Int(Date().timeIntervalSince1970)
        )
        var rungs = [Rung(name: "control, no Authorization", authorization: nil, available: true)]
        for variant in SAPISIDHash.Variant.allCases {
            let header = SAPISIDHash.authorization(variant, for: input, sha1: sha1Hex)
            rungs.append(Rung(name: variant.rawValue, authorization: header, available: header != nil))
        }
        var found: [(id: String, email: String)]?
        for rung in rungs {
            let name = rung.name
            guard rung.available else {
                lines.append("  rung \(name): skipped, a cookie it hashes is absent")
                continue
            }
            let request = PeopleRequests.listAutocompletions(
                query: query, key: key, authorization: rung.authorization, endpoints: endpoints
            )
            do {
                let response = try await client.send(request)
                var line = "  rung \(name): status \(response.status), \(response.body.count) bytes"
                if let shapes = shapes(of: response.body) {
                    lines.append(line)
                    lines.append(contentsOf: Self.lines(for: shapes).map { "    " + $0 })
                    if found == nil, !shapes.personIDs.isEmpty {
                        found = Array(zip(shapes.personIDs, shapes.personEmails))
                            .map { (id: $0.0, email: $0.1) }
                    }
                } else {
                    line += ", " + (errorSummary(response.body).map { "error \($0)" } ?? "not an answer")
                    lines.append(line)
                }
            } catch {
                lines.append("  rung \(name): FAILED \(APIProbeReport.safeDescription(of: error))")
            }
            flush(lines.joined(separator: "\n"))
        }
        return found
    }

    /// Whether the directory's ids are Chat user ids: `get_members` should
    /// name them, with the same email.
    private static func appendMappingCheck(
        _ people: [(id: String, email: String)],
        api: ProtoAPIClient,
        lines: inout [String]
    ) async {
        let sample = Array(people.prefix(5))
        do {
            let response = try await api.call(
                .getMembers, LocalBridgeBackend.getMembersRequest(sample.map { ChatKit.Member.ID($0.id) })
            )
            let members = MemberMapping.map(response).members
            let byID = Dictionary(
                members.map { ($0.id.rawValue, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let resolved = sample.filter { byID[$0.id] != nil }
            let sameEmail = resolved.filter { person in
                byID[person.id]?.email?.lowercased() == person.email.lowercased() && !person.email.isEmpty
            }
            lines.append("  asked \(sample.count), resolved \(resolved.count), same email \(sameEmail.count)")
        } catch {
            lines.append("  FAILED: \(APIProbeReport.safeDescription(of: error))")
        }
    }

    // MARK: - Pure

    struct Shapes: Equatable {
        var results = 0
        var kinds: [String: Int] = [:]
        /// `PERSON` results carrying a 21-digit id at `[3][0]`, in order.
        var personIDs: [String] = []
        /// The same people's emails, from `[0]`, aligned with `personIDs`.
        var personEmails: [String] = []
    }

    /// A `ListAutocompletions` answer: `[[result, …], …]`, each result
    /// `[email, _, kind, person, group, …]` (§57). `nil` for anything else.
    static func shapes(of body: Data) -> Shapes? {
        var text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix(")]}'") {
            text = String(text.dropFirst(4))
        }
        guard let top = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              let results = top.first as? [Any]
        else { return nil }
        var shapes = Shapes(results: results.count)
        for case let result as [Any] in results {
            let kind = result.count > 2 ? (result[2] as? String) ?? "-" : "-"
            shapes.kinds[kind, default: 0] += 1
            guard kind == "PERSON", result.count > 3, let person = result[3] as? [Any],
                  let id = person.first as? String, id.count == 21, id.allSatisfy(\.isNumber)
            else { continue }
            shapes.personIDs.append(id)
            shapes.personEmails.append(result.first as? String ?? "")
        }
        return shapes
    }

    static func lines(for shapes: Shapes) -> [String] {
        let kinds = shapes.kinds.sorted { $0.key < $1.key }.map { key, count in
            let readable = key.range(of: "^[A-Z_]{1,40}$", options: .regularExpression) != nil
            let name = readable ? key : "<\(key.count)>"
            return "\(name) \(count)"
        }
        return [
            "results \(shapes.results): " + kinds.joined(separator: ", "),
            "PERSON with a 21-digit id \(shapes.personIDs.count)"
        ]
    }

    /// Google's `json+protobuf` error, `[code, "message", …]`, or the JSON
    /// form `{"error": {"code", "message"}}`. The message is printed only when
    /// it reads as a fixed sentence: no address, nothing but plain characters.
    static func errorSummary(_ body: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: body)
        let pair: (Int, String)? = if let array = object as? [Any], let code = array.first as? Int {
            (code, array.count > 1 ? array[1] as? String ?? "" : "")
        } else if let error = (object as? [String: Any])?["error"] as? [String: Any],
                  let code = error["code"] as? Int {
            (code, error["message"] as? String ?? "")
        } else {
            nil
        }
        guard let (code, message) = pair else { return nil }
        let plain = !message.contains("@")
            && message.range(of: "^[A-Za-z0-9 .,:;'()/_-]{1,200}$", options: .regularExpression) != nil
        return plain ? "\(code) \(message)" : "\(code) (message withheld, \(message.count) chars)"
    }

    static func sha1Hex(_ input: String) -> String {
        Insecure.SHA1.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
