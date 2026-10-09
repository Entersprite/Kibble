import ChatKit
import Foundation
import GChatBridgeCore

/// `--probe=people`'s calendar section: `GetAssistiveFeatures` on
/// `peoplestack-pa`, the call Chat on the web takes "In a meeting" from
/// (`findings.md` §62).
///
/// First the key and the signature, with the capture's own request: the
/// Punctual key (`Tzliq`) unsigned, then signed, then each key literal in
/// the module that holds Chat's PeopleStack config, fetched without
/// credentials. Then, with whichever was accepted, the questions §62.8
/// leaves open: the local user by id, and DM partners by id and by email,
/// with either client value. The answer covers the whole day, so a run
/// needs no meeting in progress.
///
/// **Shapes, member numbers and times relative to the run**, never a value:
/// people are labelled, keys are counted.
extension PeopleProbeReport {
    /// At most this many bundle keys are tried.
    static let bundleKeyLimit = 6

    // MARK: - The run

    /// One request of the section, named for the report.
    private struct Question {
        let name: String
        let queries: [PeopleStackRequests.Query]
        let client: Int
        /// Whether the answer's whole shape prints. Only the local user's: a
        /// colleague's day is summarised, never laid out interval by interval.
        var printsShape = false
    }

    /// A key and a signature to try. `variant` `nil` is the unsigned control.
    private struct Rung {
        let keyName: String
        let key: String
        let variant: SAPISIDHash.Variant?
    }

    /// Everything the section is given.
    struct CalendarSection {
        var people: CalendarProbePeople
        /// The Punctual key, tried first.
        let tzliq: String
        /// `/app/home`, for the bundle's address. Never printed.
        let page: String?
        let credentials: SessionCredentials
        let transport: any HTTPTransport
        let endpoints: ChatEndpoints
        let now: Date
        /// The time each `SAPISIDHASH` is stamped with, in seconds: the wall
        /// clock. A test pins it, or a second boundary between two requests
        /// makes one variant's signatures differ (session 58).
        var signingTime: @Sendable () -> Date = { Date() }
    }

    static func appendCalendarStatus(
        _ section: CalendarSection,
        lines: inout [String],
        flush: (String) -> Void
    ) async {
        let (people, tzliq, endpoints) = (section.people, section.tzliq, section.endpoints)
        let questions = Self.questions(people)
        guard let ladder = questions.first else {
            lines.append("  nobody to ask about")
            return
        }
        lines.append("  key and signature, asking \(ladder.name):")
        let client = PunctualClient(transport: section.transport, credentials: section.credentials)
        let jar = await section.credentials.snapshot?.cookies ?? []
        let context = Context(
            people: people,
            client: client,
            jar: jar,
            endpoints: endpoints,
            now: section.now,
            signingTime: section.signingTime
        )

        var rungs = [Rung(keyName: "Tzliq (\(tzliq.count) chars)", key: tzliq, variant: nil)]
        rungs += signedRungs(keyName: "Tzliq (\(tzliq.count) chars)", key: tzliq)
        var winner = await firstAccepted(rungs, asking: ladder, context: context, lines: &lines, flush: flush)
        if winner == nil {
            let keys = await bundleKeys(
                page: section.page, transport: section.transport, endpoints: endpoints, lines: &lines
            ).filter { $0 != tzliq }
            let bundleRungs = keys.enumerated().flatMap { index, key in
                signedRungs(keyName: "bundle key \(index + 1) (\(key.count) chars)", key: key)
            }
            winner = await firstAccepted(
                bundleRungs,
                asking: ladder,
                context: context,
                lines: &lines,
                flush: flush
            )
        }
        guard let winner else {
            lines.append("  no key and signature was accepted; the calendar section stops here")
            return
        }
        lines.append("  with \(winner.keyName), \(winner.variant?.rawValue ?? "no Authorization"):")
        for question in questions.dropFirst() {
            await ask(question, rung: winner, context: context, lines: &lines)
            flush(lines.joined(separator: "\n"))
        }
    }

    /// The capture's own request first (the local user by email, client 3),
    /// so the ladder is decided on a request Chat on the web is known to
    /// make. Then everything §62.8 leaves open.
    private static func questions(_ people: CalendarProbePeople) -> [Question] {
        var questions: [Question] = []
        let calendar: [PeopleStackRequests.Feature] = [.calendarStatus]
        if let me = people.me {
            if let email = me.email {
                questions.append(Question(
                    name: "self by email, client 3",
                    queries: [.init(keys: [.email(email.lowercased())], features: calendar)], client: 3,
                    printsShape: true
                ))
            }
            questions.append(Question(
                name: "self by id, client 1",
                queries: [.init(keys: [.personID(me.id)], features: calendar)], client: 1, printsShape: true
            ))
        }
        let ids = people.partners.map { PeopleStackRequests.Key.personID($0.id) }
        let emails = people.partners
            .compactMap { $0.email.map { PeopleStackRequests.Key.email($0.lowercased()) } }
        guard !ids.isEmpty else { return questions }
        questions.append(Question(
            name: "partners by id, client 1", queries: [.init(keys: ids, features: calendar)], client: 1
        ))
        if !emails.isEmpty {
            questions.append(Question(
                name: "partners by email, client 3", queries: [.init(keys: emails, features: calendar)],
                client: 3
            ))
        }
        questions.append(Question(
            name: "partners by id, client 3", queries: [.init(keys: ids, features: calendar)], client: 3
        ))
        questions.append(Question(
            name: "partners' presence and custom status by id, client 1",
            queries: [.init(keys: ids, features: [.presence]), .init(keys: ids, features: [.userStatus])],
            client: 1
        ))
        return questions
    }

    /// The SAPISID hash alone, then the web client's three.
    private static func signedRungs(keyName: String, key: String) -> [Rung] {
        [.sapisidOnly, .firstAndThirdParty].map { Rung(keyName: keyName, key: key, variant: $0) }
    }

    /// What every request of the section shares.
    private struct Context {
        let people: CalendarProbePeople
        let client: PunctualClient
        let jar: [SessionCookies.Cookie]
        let endpoints: ChatEndpoints
        let now: Date
        let signingTime: @Sendable () -> Date
    }

    /// The first rung answered with a 200 that reads as an answer.
    private static func firstAccepted(
        _ rungs: [Rung],
        asking question: Question,
        context: Context,
        lines: inout [String],
        flush: (String) -> Void
    ) async -> Rung? {
        for rung in rungs {
            let signature = rung.variant?.rawValue ?? "control without Authorization"
            let accepted = await ask(
                question, rung: rung, context: context, lines: &lines,
                prefix: "  rung \(rung.keyName), \(signature): "
            )
            flush(lines.joined(separator: "\n"))
            // An answered control is recorded, never chosen: an anonymous
            // caller may be told "not found" for everyone.
            if accepted, rung.variant != nil {
                return rung
            }
        }
        return nil
    }

    /// Sends one question and appends what came back. `true` for an answer.
    @discardableResult
    private static func ask(
        _ question: Question,
        rung: Rung,
        context: Context,
        lines: inout [String],
        prefix: String? = nil
    ) async -> Bool {
        let prefix = prefix ?? "  \(question.name): "
        var authorization: String?
        if let variant = rung.variant {
            let input = SAPISIDHash.Input(
                cookies: context.jar, url: PeopleStackRequests.getAssistiveFeaturesURL,
                origin: PeopleRequests.origin(of: context.endpoints),
                timestamp: Int(context.signingTime().timeIntervalSince1970)
            )
            authorization = SAPISIDHash.authorization(variant, for: input, sha1: SHA1.hex)
            if authorization == nil {
                lines.append(prefix + "skipped, a cookie it hashes is absent")
                return false
            }
        }
        let request = PeopleStackRequests.getAssistiveFeatures(
            question.queries, client: question.client, key: rung.key, authorization: authorization,
            endpoints: context.endpoints
        )
        do {
            let response = try await context.client.send(request)
            var line = prefix + "status \(response.status), \(response.body.count) bytes"
            guard response.status == 200, let answer = PeopleStackAnswer(response.body) else {
                if let error = errorSummary(response.body) {
                    line += ", error \(error)"
                } else {
                    line += ", not an answer"
                        +
                        (response
                            .status == 200 ? ", shape " + maskedShape(response.body, now: context.now) : "")
                }
                lines.append(line)
                return false
            }
            lines.append(line)
            let indent = "    "
            lines += answerLines(answer, people: context.people, now: context.now).map { indent + $0 }
            if question.printsShape {
                lines.append(indent + "shape: " + maskedShape(response.body, now: context.now))
            }
            return true
        } catch {
            lines.append(prefix + "FAILED \(APIProbeReport.safeDescription(of: error))")
            return false
        }
    }

    /// The key literals in the module holding Chat's PeopleStack config,
    /// fetched from the page's own build with no cookie and no header but
    /// the user agent: static code, the same for everyone.
    private static func bundleKeys(
        page: String?,
        transport: any HTTPTransport,
        endpoints: ChatEndpoints,
        lines: inout [String]
    ) async -> [String] {
        let module = PeopleStackKey.configModule
        guard let page, let url = PeopleStackKey.moduleURL(
            inPage: page, module: module, origin: PeopleRequests.origin(of: endpoints)
        ) else {
            lines.append("  bundle: no bundle address on app/home")
            return []
        }
        let request = HTTPRequest(
            url: url, headers: HTTPHeaders([("User-Agent", endpoints.userAgent)]), traceLabel: "bundle-module"
        )
        do {
            let response = try await transport.send(request)
            let text = String(decoding: response.body, as: UTF8.self)
            let keys = response.status == 200 ? PeopleStackKey.candidates(inBundle: text) : []
            let configured = PeopleStackKey.configKey(inBundle: text) == nil ? "no" : "yes"
            let plural = keys.count == 1 ? "" : "s"
            lines.append(
                "  bundle: module \(module), status \(response.status), \(response.body.count) bytes, "
                    + "\(keys.count) key literal\(plural), config literal \(configured)"
            )
            return Array(keys.prefix(bundleKeyLimit))
        } catch {
            lines.append("  bundle: FAILED \(APIProbeReport.safeDescription(of: error))")
            return []
        }
    }
}
