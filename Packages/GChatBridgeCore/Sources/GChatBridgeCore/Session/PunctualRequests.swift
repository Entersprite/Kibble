import Foundation

/// What a Punctual watch subscribes to.
///
/// Punctual is Google's push service, and it is **not** the Dynamite
/// WebChannel `ChannelRequests` speaks: a separate host path, its own session
/// (`gsessionid`), and subscriptions named by topic. Chat on the web watches
/// each person's availability on it, and never calls `get_user_presence`
/// (`findings.md` §46.6).
///
/// Only the one topic the probe needs is spelled. The capture also has
/// `user-targeted-changes`, `group-state-changes` (typing) and a `calendar`
/// topic on another host, none of which this client sends.
public struct PunctualTopic: Sendable, Hashable {
    let value: PBLiteValue

    /// `user-state-changes / state / user / <id> / availability`, exactly as
    /// the capture sends it, including the `[1]` that the
    /// `user-targeted-changes` topic writes as `[null,1]`.
    public static func availability(userID: String) -> PunctualTopic {
        PunctualTopic(value: [
            ["user-state-changes"],
            [1],
            [[["state"], ["user"], [.string(userID)], ["availability"]]]
        ])
    }

    /// The envelope around a topic, shared by `chooseServer` and a watch.
    /// `[9,5]` is constant in every request captured; what it means is
    /// `[Verify]`, and it is copied rather than interpreted.
    func envelope(trailing: [PBLiteValue]) -> PBLiteValue {
        .array([nil, nil, nil, [9, 5], nil, value] + trailing)
    }
}

/// One subscription, numbered.
///
/// `sequence` is the watch's own counter, 1 for the first. The capture's
/// numbers run 1, 2, 3 … across the channel's life, independent of `RID`.
public struct PunctualWatch: Sendable, Hashable {
    public let sequence: Int
    public let topic: PunctualTopic

    public init(sequence: Int, topic: PunctualTopic) {
        self.sequence = sequence
        self.topic = topic
    }

    /// `[[[<seq>,[…topic…,null,null,1],null,1]]]`, the form field's value.
    func json() throws -> String {
        let watch: PBLiteValue = [
            [
                [
                    .number(.integer(Int64(sequence))),
                    topic.envelope(trailing: [nil, nil, 1]),
                    nil,
                    1
                ]
            ]
        ]
        return try watch.jsonString()
    }
}

/// An open Punctual channel: the `gsessionid` `chooseServer` minted and the
/// SID the open answer carried. Both are credentials of a kind, and nothing
/// prints them.
public struct PunctualChannelID: Sendable, Hashable {
    public let gsessionID: String
    public let sid: String

    public init(gsessionID: String, sid: String) {
        self.gsessionID = gsessionID
        self.sid = sid
    }
}

/// The four requests a Punctual availability watch is made of, pure in the
/// way `ChannelRequests` is: every varying part is a parameter.
///
/// Every shape here is from Chat on the web's own traffic (`findings.md` §47),
/// not from a reference implementation, because neither reference speaks
/// Punctual at all.
public struct PunctualRequests: Sendable {
    public let endpoints: ChatEndpoints
    public let serverPath: String
    public let key: String

    /// The server path the captured client used. The page carries a longer
    /// `prod-dynamite-prod-09-us` in its config, so this is probably derived
    /// from that, `[Verify]`; configurable so a different region needs no
    /// rebuild.
    public static let observedServerPath = "prod-09-us"

    public init(endpoints: ChatEndpoints, serverPath: String = observedServerPath, key: String) {
        self.endpoints = endpoints
        self.serverPath = serverPath
        self.key = key
    }

    /// Asks which server to use, and mints the `gsessionid`.
    ///
    /// The web client asked with its `user-targeted-changes` topic, built from
    /// a token this client does not read. This sends an availability topic
    /// instead, which is a deviation from the capture and `[Verify]`.
    public func chooseServer(_ topic: PunctualTopic) throws -> HTTPRequest {
        let body: PBLiteValue = [topic.envelope(trailing: []), nil, nil, 0, 0]
        var components = URLComponents(url: base("v1/chooseServer"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query([("key", key)])
        return try HTTPRequest(
            method: .post,
            url: components.url!,
            headers: headers([("Content-Type", "application/json+protobuf")]),
            body: Data(body.jsonString().utf8),
            traceLabel: "punctual-choose-server"
        )
    }

    /// Opens the channel, carrying the first watch. The answer holds the SID.
    public func open(gsessionID: String, rid: Int, zx: String, watch: PunctualWatch) throws -> HTTPRequest {
        try forward(
            [
                ("VER", "8"), ("gsessionid", gsessionID), ("key", key), ("RID", String(rid)),
                ("CVER", "22"), ("zx", zx), ("t", "1")
            ],
            watches: [watch],
            ofs: 0,
            contentTypeHeader: true,
            traceLabel: "punctual-open"
        )
    }

    /// Adds watches to an open channel. `aid` is the highest back-channel
    /// array seen.
    ///
    /// `ofs` is the index of the first of these watches across the channel's
    /// life, which is its sequence number less one: 1 and 2, 2 and 3, 13 and
    /// 14 in the capture. Derived rather than passed, so the two cannot
    /// disagree.
    public func add(
        _ watches: [PunctualWatch],
        on channel: PunctualChannelID,
        rid: Int,
        aid: Int,
        zx: String
    ) throws -> HTTPRequest {
        try forward(
            [
                ("VER", "8"), ("gsessionid", channel.gsessionID), ("key", key), ("SID", channel.sid),
                ("RID", String(rid)), ("AID", String(aid)), ("zx", zx), ("t", "1")
            ],
            watches: watches,
            ofs: max(0, (watches.first?.sequence ?? 1) - 1),
            contentTypeHeader: false,
            traceLabel: "punctual-add"
        )
    }

    /// The back channel: a long-poll GET whose body carries the pushes.
    public func poll(on channel: PunctualChannelID, aid: Int, zx: String) -> HTTPRequest {
        var components = URLComponents(url: base("multi-watch/channel"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query([
            ("VER", "8"), ("gsessionid", channel.gsessionID), ("key", key), ("RID", "rpc"),
            ("SID", channel.sid),
            ("AID", String(aid)), ("CI", "0"), ("TYPE", "xmlhttp"), ("zx", zx), ("t", "1")
        ])
        return HTTPRequest(url: components.url!, headers: headers(), traceLabel: "punctual-poll")
    }

    // `contentTypeHeader`: the capture's open request carried
    // `X-WebChannel-Content-Type` and the later adds did not.
    private func forward(
        _ query: [(String, String)],
        watches: [PunctualWatch],
        ofs: Int,
        contentTypeHeader: Bool,
        traceLabel: String
    ) throws -> HTTPRequest {
        var form = [("count", String(watches.count)), ("ofs", String(ofs))]
        for (index, watch) in watches.enumerated() {
            try form.append(("req\(index)___data__", watch.json()))
        }
        var components = URLComponents(url: base("multi-watch/channel"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = QueryEncoding.query(query)
        var extra = [("Content-Type", "application/x-www-form-urlencoded")]
        if contentTypeHeader {
            extra.append(("X-WebChannel-Content-Type", "application/json+protobuf"))
        }
        return HTTPRequest(
            method: .post,
            url: components.url!,
            headers: headers(extra),
            body: Data(QueryEncoding.query(form).utf8),
            traceLabel: traceLabel
        )
    }

    /// On the host root: the capture's Punctual paths carry no `/u/N`, while
    /// `X-Goog-AuthUser` names the account instead.
    private func base(_ path: String) -> URL {
        endpoints.host
            .appendingPathComponent("punctual")
            .appendingPathComponent(serverPath)
            .appendingPathComponent(path)
    }

    private func headers(_ extra: [(String, String)] = []) -> HTTPHeaders {
        let index = switch endpoints.account {
        case let .index(index): index
        case .none: 0
        }
        return HTTPHeaders(
            [
                ("referer", ChannelRequests.channelReferer),
                ("Origin", "https://chat.google.com"),
                ("User-Agent", endpoints.userAgent),
                ("X-Goog-AuthUser", String(index))
            ] + extra
        )
    }
}

public enum PunctualAnswerError: Error, Hashable, CustomStringConvertible {
    case noSessionIdentifier

    public var description: String {
        switch self {
        case .noSessionIdentifier: "no session identifier in the answer"
        }
    }
}

/// Reading the two handshake answers.
public enum PunctualAnswers {
    /// `["<gsessionid>", 1, null, "<d16>", "<d16>"]`. What the other four
    /// elements mean is `[Verify]`.
    public static func gsessionID(inChooseServer body: Data) throws -> String {
        guard
            let value = try? PBLiteValue(json: body),
            let first = value.arrayValue?.first?.stringValue, !first.isEmpty
        else { throw PunctualAnswerError.noSessionIdentifier }
        return first
    }

    /// `[[0,["c","<SID>","",8,15,30000]]]`, the same `res[0][1][1]` the
    /// Dynamite channel's initial response has, framed with a length prefix
    /// or not.
    public static func sid(inOpen body: String) throws -> String {
        var payload = Substring(body)
        if let newline = payload.firstIndex(of: "\n"), payload[..<newline].allSatisfy(\.isNumber) {
            payload = payload[payload.index(after: newline)...]
        }
        guard
            let value = try? PBLiteValue(json: Data(payload.utf8)),
            let inner = value.arrayValue?.first?.arrayValue?.dropFirst().first?.arrayValue,
            inner.first?.stringValue == "c",
            inner.count >= 2, let sid = inner[1].stringValue, !sid.isEmpty
        else { throw PunctualAnswerError.noSessionIdentifier }
        return sid
    }
}
