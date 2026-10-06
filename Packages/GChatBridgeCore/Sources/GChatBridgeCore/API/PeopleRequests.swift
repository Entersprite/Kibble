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

    private static func authUser(of endpoints: ChatEndpoints) -> String {
        if case let .index(index) = endpoints.account {
            return String(index)
        }
        return "0"
    }
}
