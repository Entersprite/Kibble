import Foundation

/// Safe receipt outcome only. The subsequent decline acknowledgement does
/// not prove that another client stopped ringing.
public enum MeetDeclineReceipt: Sendable {
    case skipped, acknowledged
    case unconfirmed(MeetCallClientError?)
}

/// One explicit decline. Its rolling token never escapes this request scope.
actor MeetDeclineSession {
    private let client: MeetCallClient
    private let validate: @Sendable () async throws -> Void
    private var token = MeetMeetingToken()

    init(
        client: MeetCallClient, token: String,
        validate: @escaping @Sendable () async throws -> Void
    ) throws {
        self.client = client
        self.validate = validate
        self.token.absorb(token)
        guard self.token.value != nil, token.utf8.allSatisfy({ (33 ... 126).contains($0) }) else {
            throw MeetCallClientError.missingMeetingToken
        }
    }

    func run(_ invitation: MeetIncomingInvitation, recordsReceipt: Bool) async throws -> MeetDeclineReceipt {
        let decline = try MeetInvitationWire.decline(invitation)
        var receipt = MeetDeclineReceipt.skipped
        if recordsReceipt {
            do {
                _ = try await send("LogEvent", body: MeetInvitationWire.received(invitation))
                receipt = .acknowledged
            } catch {
                // The browser does not await its receipt RPC before permitting
                // Decline. Preserve that independence without retrying either.
                receipt = .unconfirmed(error as? MeetCallClientError)
            }
        }
        _ = try await send("DeclineMeetingInvite", body: decline)
        return receipt
    }

    private func send(_ method: String, body: Data) async throws -> HTTPResponse {
        try Task.checkCancellation()
        try await validate()
        try Task.checkCancellation()
        guard let value = token.value else { throw MeetCallClientError.missingMeetingToken }
        var request = client.configuration.request(
            method: "MeetingInviteService/" + method, body: body, token: value
        )
        // The browser sends receipt without waiting. Bound this preparatory
        // step so a failed read does not consume the whole ringing window.
        if method == "LogEvent" {
            request.timeout = .seconds(3)
        }
        return try await client.send(request, received: { [weak self] response in
            await self?.absorb(response.headers["x-goog-meeting-token"])
        })
    }

    private func absorb(_ value: String?) {
        guard value.map({ $0.utf8.allSatisfy { (33 ... 126).contains($0) } }) ?? true else { return }
        token.absorb(value)
    }
}
