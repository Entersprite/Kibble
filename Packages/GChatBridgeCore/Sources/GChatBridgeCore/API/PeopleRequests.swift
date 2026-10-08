import Foundation

/// The directory search Chat on the web runs while `@` is typed
/// (`findings.md` §56.4): `ListAutocompletions` on `people-pa`, a third Google
/// host, as `application/json+protobuf`.
///
/// The shape is copied from the owner's capture: the query, the client name
/// `DYNAMITE_WEB` twice, a page of 40. The key is the Punctual key
/// (`WizGlobalData.punctualKey`, `Tzliq`): the capture carried the same key
/// on both. **Probe only, `[Verify]`** until `--probe=people` has run.
public enum PeopleRequests {
    public static let listAutocompletionsURL = URL(
        string: "https://people-pa.clients6.google.com/$rpc/"
            + "google.internal.people.v2.minimal.PeopleApiAutocompleteMinimalService/ListAutocompletions"
    )!
    public static let clientName = "DYNAMITE_WEB"

    /// `authorization` is a `SAPISIDHASH` header (`SAPISIDHash`), or `nil`
    /// for none: the probe's control rung.
    public static func listAutocompletions(
        query: String,
        key: String,
        authorization: String?,
        endpoints: ChatEndpoints
    ) -> HTTPRequest {
        var headers: [(String, String)] = [
            ("Content-Type", "application/json+protobuf"),
            ("Origin", origin(of: endpoints)),
            ("X-Goog-Api-Key", key),
            ("X-User-Agent", "grpc-web-javascript/0.1"),
            ("X-Goog-AuthUser", authUser(of: endpoints)),
            ("User-Agent", endpoints.userAgent)
        ]
        if let authorization {
            headers.append(("Authorization", authorization))
        }
        return HTTPRequest(
            method: .post,
            url: listAutocompletionsURL,
            headers: HTTPHeaders(headers),
            body: body(query: query),
            traceLabel: "list_autocompletions"
        )
    }

    /// `[query, null, null, [client], 40, null, null, [null, null, [null, 2]], [client, null, 2]]`,
    /// field for field the capture's (§56.4).
    static func body(query: String) -> Data {
        let fields: [Any] = [
            query, NSNull(), NSNull(), [clientName], 40, NSNull(), NSNull(),
            [NSNull(), NSNull(), [NSNull(), 2]], [clientName, NSNull(), 2]
        ]
        return (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
    }

    /// The page's origin: the chat host, without the `/u/N` account path.
    public static func origin(of endpoints: ChatEndpoints) -> String {
        let scheme = endpoints.host.scheme ?? "https"
        let host = endpoints.host.host ?? "chat.google.com"
        return "\(scheme)://\(host)"
    }

    /// `X-Goog-AuthUser`: the account index, `0` without one. Shared with
    /// `PeopleStackRequests`.
    static func authUser(of endpoints: ChatEndpoints) -> String {
        if case let .index(index) = endpoints.account {
            return String(index)
        }
        return "0"
    }

    /// One `PERSON` from a `ListAutocompletions` answer (`findings.md` §57.3).
    public struct Person: Hashable, Sendable {
        public let id: String
        public let name: String
        public let email: String
        public let photoURL: URL?
    }

    /// The answer's people: `PERSON` results with a 21-digit id and a name.
    /// Mailing lists and contact groups are not people a mention can name.
    /// The name's position is `[Verify]` (§57.3).
    public static func people(from body: Data) -> [Person] {
        var text = String(decoding: body, as: UTF8.self)
        if text.hasPrefix(")]}'") {
            text = String(text.dropFirst(4))
        }
        guard let top = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              let results = top.first as? [Any] else { return [] }
        return results.compactMap { item in
            guard let result = item as? [Any], result.count > 3, result[2] as? String == "PERSON",
                  let person = result[3] as? [Any],
                  let id = person.first as? String, id.count == 21, id.allSatisfy(\.isNumber),
                  let name = nested(person, 2, 0, 1) as? String, !name.isEmpty
            else { return nil }
            let photo = (nested(person, 3, 0, 1) as? String).flatMap(URL.init(string:))
            return Person(id: id, name: name, email: result.first as? String ?? "", photoURL: photo)
        }
    }

    private static func nested(_ value: Any, _ path: Int...) -> Any? {
        path.reduce(Optional(value)) { current, index in
            guard let array = current as? [Any], array.indices.contains(index) else { return nil }
            return array[index]
        }
    }
}
