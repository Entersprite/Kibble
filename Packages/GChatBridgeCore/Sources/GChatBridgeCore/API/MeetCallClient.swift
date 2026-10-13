import Foundation

/// The observed Meet RPC envelope for a Chat DM call. Values read from the
/// current Meet page are supplied by the caller; no captured key or URL is
/// compiled into Kibble.
public struct MeetCallConfiguration: Sendable {
    public let apiKey: String
    public let accountIndex: Int
    public let referer: URL
    public let userAgent: String
    /// Base64 client descriptor protobuf from the shell, not an opaque ID.
    public let rtcClientID: String
    public let debugID: String
    let streamApplication: UInt64?
    let streamClientVersion: String?

    public init?(
        apiKey: String,
        accountIndex: Int,
        referer: URL,
        userAgent: String,
        rtcClientID: String,
        debugID: String,
        streamApplication: UInt64? = nil,
        streamClientVersion: String? = nil
    ) {
        guard !apiKey.isEmpty, accountIndex >= 0,
              referer.scheme == "https", referer.host == "meet.google.com", referer.path == "/call",
              !userAgent.isEmpty, MeetCallRTCClient.isValid(rtcClientID), !debugID.isEmpty
        else { return nil }
        if streamApplication != nil || streamClientVersion != nil {
            guard let streamApplication, streamApplication <= UInt64(Int32.max),
                  let streamClientVersion, !streamClientVersion.isEmpty,
                  streamClientVersion.utf8.count <= 128,
                  streamClientVersion.utf8.allSatisfy({ (33 ... 126).contains($0) }) else { return nil }
        }
        self.apiKey = apiKey
        self.accountIndex = accountIndex
        self.referer = referer
        self.userAgent = userAgent
        self.rtcClientID = rtcClientID
        self.debugID = debugID
        self.streamApplication = streamApplication
        self.streamClientVersion = streamClientVersion
    }

    func request(method: String, body: Data, token: String? = nil) -> HTTPRequest {
        var fields = [
            ("Accept", "*/*"),
            ("Content-Type", "application/x-protobuf"),
            ("Origin", "https://meet.google.com"),
            ("Referer", referer.absoluteString),
            ("User-Agent", userAgent),
            ("x-goog-api-key", apiKey),
            ("x-goog-authuser", String(accountIndex)),
            ("x-goog-encode-response-if-executable", "base64"),
            ("x-goog-meeting-debugid", debugID),
            ("x-goog-meeting-rtcclient", rtcClientID)
        ]
        if let token {
            fields.append(("x-goog-meeting-token", token))
        }
        return HTTPRequest(
            method: .post,
            url: URL(string: "https://meet.google.com/$rpc/google.rtc.meetings.v1.\(method)")!,
            headers: HTTPHeaders(fields),
            body: body,
            timeout: .seconds(20),
            traceLabel: "meet-\(method)",
            followsRedirects: false,
            maxBodyBytes: 1_000_000
        )
    }
}

/// The token from Resolve is a credential for later Meet RPCs. Keep it in
/// memory and avoid putting it in a diagnostic report or a persisted model.
public struct MeetResolvedCall: Sendable {
    public let space: MeetCallWire.Space
    let token: String
    let incomingInvitation: MeetIncomingInvitation?
    private let incomingReference: String?

    init(space: MeetCallWire.Space, token: String, incomingInvitation: MeetIncomingInvitation? = nil) {
        self.space = space
        self.token = token
        self.incomingInvitation = incomingInvitation
        incomingReference = nil
    }

    fileprivate init(
        space: MeetCallWire.Space, token: String, invitation: MeetIncomingInvitation,
        resolvedReference: String
    ) {
        self.space = space
        self.token = token
        incomingInvitation = invitation
        incomingReference = resolvedReference
    }

    /// Only the offered-reference resolver can establish this binding. A DM
    /// resolve or a different notification cannot satisfy it, even if a code
    /// happens to equal the returned canonical space.
    public func resolvesIncomingReference(_ reference: String) -> Bool {
        incomingInvitation != nil && incomingReference == reference
    }
}

public enum MeetCallClientError: Error, Sendable, Equatable {
    case httpStatus(Int, refusal: MeetCallRefusal)
    case missingSessionProof
    case missingMeetingToken
    case inviteRejected
}

/// Only explicit calls to these methods send requests. Resolving a DM does
/// not ring; `invite` is the separate, visible ring action.
public struct MeetCallClient: Sendable {
    let transport: any HTTPTransport
    let credentials: SessionCredentials
    let configuration: MeetCallConfiguration
    let sha1: @Sendable (String) -> String
    let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport,
        credentials: SessionCredentials,
        configuration: MeetCallConfiguration,
        sha1: @escaping @Sendable (String) -> String,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.credentials = credentials
        self.configuration = configuration
        self.sha1 = sha1
        self.now = now
    }

    /// YNc's HNc layout: current shell application metadata when available,
    /// otherwise this native implementation's unspecified application/version.
    /// Instance identity is always fresh; account fields and capabilities are
    /// never copied. Registration, not header construction, confirms acceptance.
    public func streamControlHeader() throws -> Data {
        guard let descriptor = Data(base64Encoded: configuration.rtcClientID),
              MeetCallRTCClient.isValid(configuration.rtcClientID) else {
            throw MeetCallWire.WireError.invalidIdentifier
        }
        let client = MeetProto.string(1, configuration.streamClientVersion ?? "KibbleNative")
            + MeetProto.string(4, configuration.debugID)
        return MeetProto.bytes(1, MeetProto.number(1, configuration.streamApplication ?? 0)) + MeetProto
            .bytes(
                2,
                client
            )
            + MeetProto.string(4, "en") + MeetProto.bytes(7, descriptor)
    }

    public var streamHeaderSource: String {
        configuration.streamApplication == nil
            ? "native application metadata"
            : "current shell application metadata"
    }

    public func resolve(dmID: String) async throws -> MeetResolvedCall {
        let request = try configuration.request(
            method: "MeetingSpaceService/ResolveForHangoutsChat",
            body: MeetCallWire.resolve(dmID: dmID)
        )
        let response = try await send(request)
        let space = try MeetCallWire.resolvedSpace(from: response.body)
        guard let token = response.headers["x-goog-meeting-token"], !token.isEmpty else {
            throw MeetCallClientError.missingMeetingToken
        }
        return MeetResolvedCall(space: space, token: token, incomingInvitation: nil)
    }

    public func resolveIncoming(
        code: String,
        invitation: MeetIncomingInvitation
    ) async throws -> MeetResolvedCall {
        var request = try configuration.request(
            method: "MeetingSpaceService/ResolveMeetingSpace", body: MeetCallWire.resolveOffered(code: code)
        )
        request.headers = try HTTPHeaders(fields: request.headers.fields + [
            .init(name: "X-Goog-Meeting-Identifier", value: MeetCallWire.offeredIdentifier(code: code))
        ])
        let response = try await send(request)
        let space = try MeetCallWire.resolvedSpace(from: response.body)
        guard let token = response.headers["x-goog-meeting-token"], !token.isEmpty else {
            throw MeetCallClientError.missingMeetingToken
        }
        return MeetResolvedCall(space: space, token: token, invitation: invitation, resolvedReference: code)
    }

    public func invite(_ call: MeetResolvedCall, calleeID: String, requestID: UUID) async throws {
        let request = try configuration.request(
            method: "MeetingInviteService/CreateMeetingInvite",
            body: MeetCallWire.invite(
                spaceName: call.space.name, calleeID: calleeID, requestID: requestID
            ),
            token: call.token
        )
        let response = try await send(request)
        guard try MeetCallWire.acceptedInvite(from: response.body) else {
            throw MeetCallClientError.inviteRejected
        }
    }

    /// The explicit receiver action uses the notification's credential and
    /// the browser's receipt-before-decline sequence, without media or lookup.
    public func decline(
        _ invitation: MeetIncomingInvitation, meetingToken: String, recordsReceipt: Bool = true,
        validate: @escaping @Sendable () async throws -> Void = {}
    ) async throws -> MeetDeclineReceipt {
        let session = try MeetDeclineSession(client: self, token: meetingToken, validate: validate)
        return try await session.run(invitation, recordsReceipt: recordsReceipt)
    }

    /// Media bootstrap is exempt from the space token interceptor in the web
    /// source. The native converter supplies structured config, never raw SDP.
    public func createMediaSession(clientConfiguration: Data) async throws -> MeetMediaSessionWire.Session {
        let request = try configuration.request(
            method: "MediaSessionService/CreateMediaSession",
            body: MeetMediaSessionWire.create(clientConfiguration: clientConfiguration)
        )
        let response = try await send(request)
        return try MeetMediaSessionWire.session(from: response.body)
    }

    func send(
        _ request: HTTPRequest,
        received: @Sendable (HTTPResponse) async -> Void = { _ in }
    ) async throws -> HTTPResponse {
        let authorised = await credentials.authorising(request) { cookies, url in
            SAPISIDHash.browserAuthorization(for: .init(
                cookies: cookies.cookies, url: url, origin: "https://meet.google.com",
                timestamp: Int(now().timeIntervalSince1970)
            ), sha1: sha1)
        }
        guard authorised.headers["Authorization"] != nil
        else { throw MeetCallClientError.missingSessionProof }
        let response = try await transport.send(authorised)
        await credentials.absorb(response.headers, from: request.url)
        await received(response)
        guard response.status == 200 else {
            throw MeetCallClientError.httpStatus(
                response.status,
                refusal: MeetCallRefusal(body: response.body)
            )
        }
        return response
    }
}
