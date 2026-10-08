import Foundation

/// `GetAssistiveFeatures` on `peoplestack-pa`, a fourth Google host: the call
/// Chat on the web takes "In a meeting", presence and custom status from
/// (`findings.md` §62). It is polled, never pushed, and a request batches
/// people per feature.
///
/// The layout is the owner's capture's (§62.5), read as structure only. The
/// key is **not** the Punctual key: Chat's own is a literal in its JavaScript
/// (`PeopleStackKey`). **Probe only, `[Verify]`** until `--probe=people` has
/// run its calendar section.
public enum PeopleStackRequests {
    public static let getAssistiveFeaturesURL = URL(
        string: "https://peoplestack-pa.clients6.google.com/$rpc/"
            + "social.people.backend.service.intelligence.proto.PeopleStackIntelligenceService/"
            + "GetAssistiveFeatures"
    )!

    /// The features this client asks for (§62.5); the wire has more.
    public enum Feature: Int, Sendable {
        /// Out of office, in a meeting, busy, focus time: "waldo status".
        case calendarStatus = 1
        case presence = 4
        /// Custom status and do-not-disturb.
        case userStatus = 5
    }

    /// Whom an entry is about: `[type, value]` on the wire. Type 1 is an
    /// email, 2 a person id (a Chat user id); an answer may echo others.
    public struct Key: Hashable, Sendable {
        public let type: Int
        public let value: String

        public init(type: Int, value: String) {
            self.type = type
            self.value = value
        }

        public static func email(_ value: String) -> Key {
            Key(type: 1, value: value)
        }

        public static func personID(_ value: String) -> Key {
            Key(type: 2, value: value)
        }
    }

    /// One batch: these people, these features.
    public struct Query: Sendable {
        public let keys: [Key]
        public let features: [Feature]

        public init(keys: [Key], features: [Feature]) {
            self.keys = keys
            self.features = features
        }
    }

    /// `client` is the request header's first field: Chat's config says 1,
    /// and the capture's own calendar request sent 3 (§62.5).
    public static func getAssistiveFeatures(
        _ queries: [Query],
        client: Int,
        key: String,
        authorization: String?,
        endpoints: ChatEndpoints
    ) -> HTTPRequest {
        var headers: [(String, String)] = [
            ("Content-Type", "application/json+protobuf"),
            ("Origin", PeopleRequests.origin(of: endpoints)),
            ("X-Goog-Api-Key", key),
            ("X-User-Agent", "grpc-web-javascript/0.1"),
            ("X-Goog-AuthUser", PeopleRequests.authUser(of: endpoints)),
            ("User-Agent", endpoints.userAgent)
        ]
        if let authorization {
            headers.append(("Authorization", authorization))
        }
        return HTTPRequest(
            method: .post,
            url: getAssistiveFeaturesURL,
            headers: HTTPHeaders(headers),
            body: body(queries, client: client),
            traceLabel: "get_assistive_features"
        )
    }

    /// `[[client, "1"], [[[[type, value], …], [feature, …]], …]]`. The `"1"`
    /// is the config's default for a field the client's code leaves unset.
    static func body(_ queries: [Query], client: Int) -> Data {
        let batches: [Any] = queries.map { query in
            [query.keys.map { [$0.type, $0.value] as [Any] }, query.features.map(\.rawValue)] as [Any]
        }
        let fields: [Any] = [[client, "1"] as [Any], batches]
        let data = try? JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes])
        return data ?? Data()
    }
}
