import Foundation

public enum MeetDeviceSessionError: Error, Sendable, Equatable {
    case busy, closed, deviceExists, noDevice, mediaNotConnected, notJoined, leaveUnconfirmed
    case invitationCancellationUnconfirmed
}

/// One native caller's device and rolling token. The provider adapter must
/// confirm its actual peer connection before joining; resolving is insufficient.
/// No automatic retry of mutations, including an ambiguous ring or leave.
public actor MeetDeviceSession {
    private let client: MeetCallClient
    private let space: MeetCallWire.Space
    private let incomingInvitation: MeetIncomingInvitation?
    private var presentation = false
    private var expectedPrimary: String?
    private var token = MeetMeetingToken()
    private var device: MeetDeviceWire.Device?
    private var mediaSession: String?
    private var busy = false
    private var closed = false
    private var mediaConnected = false
    private var didInvite = false
    private var didRegister = false
    private var invitationID: String?
    private var cancellationAttempted = false
    private var invitationCompleted = false
    public private(set) var conferenceID: String?

    public var outgoingInvitationID: String? {
        invitationID
    }

    public var localDeviceName: String? {
        device?.name
    }

    public func cancelInvitation() async throws {
        guard !busy else { throw MeetDeviceSessionError.busy }
        guard !invitationCompleted else { return }
        if cancellationAttempted {
            if invitationID != nil {
                throw MeetDeviceSessionError.invitationCancellationUnconfirmed
            }
            return
        }
        guard let invitationID else {
            if didInvite {
                throw MeetDeviceSessionError.invitationCancellationUnconfirmed
            }
            return
        }
        busy = true
        cancellationAttempted = true
        defer { busy = false }
        _ = try await send(
            "MeetingInviteService/CancelMeetingInvite", body: MeetInvitationWire.cancel(id: invitationID)
        )
        self.invitationID = nil
    }

    /// An observed peer join completes the ringing lifecycle, independently
    /// of the lifetime of either media device.
    public func completeInvitation() {
        invitationCompleted = true
        invitationID = nil
    }

    public func collections() async throws -> MeetCallCollectionsWire.Snapshot {
        try begin()
        defer { busy = false }
        let response = try await send(
            "MeetingSpaceService/SyncMeetingSpaceCollections",
            body: MeetCallCollectionsWire.sync(space: space.name)
        )
        return try MeetCallCollectionsWire.snapshot(from: response.body, in: space.name)
    }

    public init(client: MeetCallClient, call: MeetResolvedCall) {
        self.client = client
        space = call.space
        incomingInvitation = call.incomingInvitation
        token.absorb(call.token)
    }

    /// Mint a secondary credential from this joined device. It remains separate
    /// from parent token rotation and carries no incoming invitation or ring.
    public func makePresenter() async throws -> MeetDeviceSession {
        try Task.checkCancellation()
        try begin()
        defer { busy = false }
        guard !presentation, mediaConnected, let device, device.joinState == 1 else {
            throw MeetDeviceSessionError.notJoined
        }
        let response = try await send(
            "MeetingDeviceService/CreateTokenForSecondary",
            body: MeetDeviceWire.secondaryTokenRequest(space: space.name)
        )
        let secondaryToken = try MeetDeviceWire.secondaryToken(from: response.body)
        try Task.checkCancellation()
        guard !closed, mediaConnected else { throw MeetDeviceSessionError.closed }
        let call = MeetResolvedCall(space: space, token: secondaryToken)
        return MeetDeviceSession(client: client, call: call, primary: device.name)
    }

    private init(client: MeetCallClient, call: MeetResolvedCall, primary: String) {
        self.client = client; space = call.space; incomingInvitation = nil
        token.absorb(call.token); presentation = true; expectedPrimary = primary
    }

    public func register(mediaSession: String) async throws {
        try begin()
        defer { busy = false }
        guard !didRegister else { throw MeetDeviceSessionError.deviceExists }
        let body = try MeetDeviceWire.create(
            space: space.name, mediaSession: mediaSession, incomingInvitation: incomingInvitation
        )
        didRegister = true
        let response = try await request("CreateMeetingDevice", body: body)
        // Keep the device before checking cancellation, so the adapter can leave
        // after an accepted registration finishes during window closure.
        let registered = try MeetDeviceWire.device(from: response.body, in: space.name)
        guard registered.name != expectedPrimary else { throw MeetCallWire.WireError.malformedResponse }
        device = registered
        self.mediaSession = mediaSession
        if presentation, registered.primaryDevice != expectedPrimary {
            throw MeetCallWire.WireError.malformedResponse
        }
    }

    public func setMediaConnected(_ connected: Bool) {
        mediaConnected = connected && !closed
    }

    public func join() async throws {
        try begin()
        defer { busy = false }
        guard let device, let mediaSession else { throw MeetDeviceSessionError.noDevice }
        guard mediaConnected else { throw MeetDeviceSessionError.mediaNotConnected }
        let response = try await request(
            "UpdateMeetingDevice", body: MeetDeviceWire.join(
                device: device.name,
                mediaSession: mediaSession,
                presentation: presentation
            )
        )
        let joined = try MeetDeviceWire.device(from: response.body, in: space.name)
        guard joined.name == device.name else { throw MeetCallWire.WireError.malformedResponse }
        self.device = joined
        guard !presentation || (joined.primaryDevice == expectedPrimary && joined.captureType == 2)
        else { throw MeetCallWire.WireError.malformedResponse }
        guard joined.joinState == 1, !joined.isDeleted else { throw MeetDeviceSessionError.notJoined }
    }

    public func invite(calleeID: String, requestID: UUID) async throws {
        try begin()
        defer { busy = false }
        guard !presentation, incomingInvitation == nil, mediaConnected, device?.joinState == 1,
              !didInvite else {
            throw MeetDeviceSessionError.notJoined
        }
        let body = try MeetCallWire.invite(spaceName: space.name, calleeID: calleeID, requestID: requestID)
        didInvite = true
        let response = try await send("MeetingInviteService/CreateMeetingInvite", body: body)
        do {
            invitationID = try MeetInvitationWire.invitationID(from: response.body)
        } catch {
            throw MeetCallClientError.inviteRejected
        }
    }

    /// Called after the adapter has settled any in-flight join/registration.
    /// Refuses while busy rather than dropping a late registered device.
    public func leave() async throws {
        guard !busy else { throw MeetDeviceSessionError.busy }
        closed = true
        mediaConnected = false
        guard let device else {
            guard !didRegister else { throw MeetDeviceSessionError.leaveUnconfirmed }
            return
        }
        busy = true
        defer { busy = false }
        let response = try await request(
            "UpdateMeetingDevice", body: MeetDeviceWire.leave(device: device.name)
        )
        let left = try MeetDeviceWire.device(from: response.body, in: space.name)
        guard left.name == device.name, left.joinState == 6 else {
            throw MeetDeviceSessionError.leaveUnconfirmed
        }
        self.device = nil
        mediaSession = nil
        didRegister = false
    }

    private func begin() throws {
        guard !closed else { throw MeetDeviceSessionError.closed }
        guard !busy else { throw MeetDeviceSessionError.busy }
        busy = true
    }

    private func request(_ method: String, body: Data) async throws -> HTTPResponse {
        try await send("MeetingDeviceService/" + method, body: body, isDevice: true)
    }

    private func send(_ method: String, body: Data, isDevice: Bool = false) async throws -> HTTPResponse {
        guard let value = token.value else { throw MeetCallClientError.missingMeetingToken }
        var request = client.configuration.request(method: method, body: body, token: value)
        if isDevice {
            request.headers = HTTPHeaders(fields: request.headers.fields + [
                .init(name: "x-goog-ext-174067345-bin", value: MeetDeviceWire.clientExtension)
            ])
        }
        return try await client.send(request, received: { [weak self] response in
            await self?.absorb(response.headers)
        })
    }

    private func absorb(_ headers: HTTPHeaders) {
        token.absorb(headers["x-goog-meeting-token"])
        if let value = headers["x-goog-meeting-debugid"], !value.isEmpty,
           value.utf8.count <= 128, value.utf8.allSatisfy({ (33 ... 126).contains($0) }) {
            conferenceID = value
        }
    }
}
