import Foundation

public enum MeetDeviceSessionError: Error, Sendable, Equatable {
    case busy, closed, deviceExists, noDevice, mediaNotConnected, notJoined, leaveUnconfirmed
    case invitationCancellationUnconfirmed, captureLockUnsupported, conferenceEnded
}

/// One native caller's device and rolling token. The provider adapter must
/// confirm its actual peer connection before joining; resolving is insufficient.
/// No automatic retry of mutations, including an ambiguous ring or leave.
public actor MeetDeviceSession {
    private enum Registration { case unattempted, attempted, refused }

    private let client: MeetCallClient
    let space: MeetCallWire.Space
    private let incomingInvitation: MeetIncomingInvitation?
    private var presentation = false
    private var expectedPrimary: String?
    private var token = MeetMeetingToken()
    var device: MeetDeviceWire.Device?
    private var mediaSession: String?
    var busy = false
    var closed = false
    var mediaConnected = false
    var acknowledgedAdmissionTypes: Set<UInt64> = []
    var waitingAdmissionVersion: UInt64?
    private var didInvite = false
    private var additionalInvites: [String] = []
    private var participantInvitationVersion: UInt64?
    private var registration = Registration.unattempted
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

    public var publicJoinURL: URL {
        space.url
    }

    public func publicDialIn(preferredRegion: String?) -> MeetDialIn? {
        publicDialInDetails(preferredRegion: preferredRegion)?.numbers.first
    }

    public func publicDialInDetails(preferredRegion: String?) -> (numbers: [MeetDialIn], directory: URL?)? {
        guard !closed, !presentation, device?.joinState == 1, device?.isDeleted == false else { return nil }
        var numbers = space.dialIn
        if let index = numbers.firstIndex(where: { $0.region != nil && $0.region == preferredRegion }),
           index != 0 {
            let preferred = numbers.remove(at: index)
            numbers.insert(preferred, at: 0)
        }
        return (numbers, space.phoneDirectory)
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

    public func collections(timeout: Duration? = nil) async throws -> MeetCallCollectionsWire.Snapshot {
        try begin()
        defer { busy = false }
        let response = try await requestCallCollections(timeout: timeout)
        var snapshot = try MeetCallCollectionsWire.snapshot(from: response.body, in: space.name)
        reconcileParticipantInvitations(snapshot.invitations)
        if let devices = snapshot.devices, devices.version < (waitingAdmissionVersion ?? 0) {
            snapshot.devices = nil
        }
        if let name = device?.name {
            snapshot.activities?.devices = snapshot.devices
            snapshot.activities?.hostAccess = snapshot.devices?.hostAccess(for: name)
        }
        return snapshot
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

    public func register(mediaSession: String, supportsWaitingRoom: Bool = false) async throws {
        try begin()
        defer { busy = false }
        guard registration == .unattempted else { throw MeetDeviceSessionError.deviceExists }
        let body = try MeetDeviceWire.create(
            space: space.name, mediaSession: mediaSession, incomingInvitation: incomingInvitation,
            supportsWaitingRoom: supportsWaitingRoom && !presentation
        )
        registration = .attempted
        let response = try await requestRegistration(body)
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
                presentation: presentation,
                joinAlongside: device.transfer == 3
            )
        )
        let joined = try MeetDeviceWire.device(from: response.body, in: space.name)
        try acceptAdmissionDevice(joined)
        let etagVersion = response.headers["etag"]?
            .split(separator: "-", omittingEmptySubsequences: false).first
        if [3, 13].contains(joined.joinState), !joined.isDeleted,
           let prefix = etagVersion,
           let revision = UInt64(prefix), revision <= UInt64(Int64.max) {
            waitingAdmissionVersion = max(waitingAdmissionVersion ?? 0, revision)
        }
        guard joined.joinState == 1, !joined.isDeleted else { throw MeetDeviceSessionError.notJoined }
    }

    func acceptAdmissionDevice(_ value: MeetDeviceWire.Device) throws {
        guard value.name == device?.name else { throw MeetCallWire.WireError.malformedResponse }
        device = value
        guard !presentation || (value.primaryDevice == expectedPrimary && value.captureType == 2)
        else { throw MeetCallWire.WireError.malformedResponse }
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

    public func inviteParticipant(calleeID: String) async throws {
        try begin()
        defer { busy = false }
        guard !presentation, mediaConnected,
              device?.joinState == 1 else { throw MeetDeviceSessionError.notJoined }
        guard additionalInvites.count < 64 else { throw MeetDeviceSessionError.busy }
        let response = try await send(
            "MeetingInviteService/CreateMeetingInvite",
            body: MeetCallWire.invite(spaceName: space.name, calleeID: calleeID, requestID: UUID())
        )
        try additionalInvites.append(MeetInvitationWire.invitationID(from: response.body))
    }

    public func cancelParticipantInvitations() async throws {
        try begin()
        defer { busy = false }
        guard !additionalInvites.isEmpty else { return }
        let deadline = ContinuousClock.now + .seconds(20)
        // A final read covers an answer that arrived before the next normal poll.
        // A failed read leaves the invitation pending and eligible for one cancel.
        try? await refreshParticipantInvitations()
        let ids = additionalInvites
        additionalInvites = []
        var unconfirmed = false
        for id in ids {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { unconfirmed = true; break }
            do { _ = try await send(
                "MeetingInviteService/CancelMeetingInvite",
                body: MeetInvitationWire.cancel(id: id),
                timeout: remaining
            ) } catch { unconfirmed = true }
        }
        if unconfirmed {
            throw MeetDeviceSessionError.invitationCancellationUnconfirmed
        }
    }

    /// Called after the adapter has settled any in-flight join/registration.
    /// Refuses while busy rather than dropping a late registered device.
    public func leave() async throws {
        guard !busy else { throw MeetDeviceSessionError.busy }
        closed = true
        mediaConnected = false
        guard let device else {
            guard registration != .attempted else { throw MeetDeviceSessionError.leaveUnconfirmed }
            return
        }
        // An exact DENIED or DENIED_FULL admission result already settled the registration.
        if !presentation, [4, 11].contains(device.joinState) {
            settleDevice()
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
        settleDevice()
    }

    public func endConference() async throws {
        try begin()
        defer { busy = false }
        guard !presentation, mediaConnected, device?.joinState == 1
        else { throw MeetDeviceSessionError.notJoined }
        let response = try await send(
            "MeetingSpaceService/EndConference", body: MeetActivityWire.endConferenceBody(space: space.name)
        )
        guard try MeetProto.decode(response.body).isEmpty
        else { throw MeetCallWire.WireError.malformedResponse }
        settleDevice()
    }

    public func observeRemovedDevice(_ observed: MeetDeviceWire.Device) {
        guard observed.name == device?.name, observed.confirmsRegistrationEnded else { return }
        settleDevice()
    }

    public func settleIncompatibleAdmission() -> Bool {
        guard !closed, device?.wasRejectedAsIncompatible == true else { return false }
        settleDevice()
        return true
    }

    private func settleDevice() {
        device = nil
        mediaSession = nil
        registration = .unattempted
        mediaConnected = false
    }

    func begin() throws {
        guard !closed else { throw MeetDeviceSessionError.closed }
        guard !busy else { throw MeetDeviceSessionError.busy }
        busy = true
    }

    private func request(_ method: String, body: Data) async throws -> HTTPResponse {
        try await send("MeetingDeviceService/" + method, body: body, isDevice: true)
    }

    func send(
        _ method: String, body: Data, isDevice: Bool = false, timeout: Duration? = nil
    ) async throws -> HTTPResponse {
        guard let value = token.value else { throw MeetCallClientError.missingMeetingToken }
        var request = client.configuration.request(method: method, body: body, token: value)
        if let timeout {
            request.timeout = timeout
        }
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

private extension MeetDeviceSession {
    func requestCallCollections(timeout: Duration?) async throws -> HTTPResponse {
        do {
            return try await send(
                "MeetingSpaceService/SyncMeetingSpaceCollections",
                body: MeetCallCollectionsWire.sync(space: space.name), timeout: timeout
            )
        } catch let MeetCallClientError.httpStatus(400, refusal)
            where refusal.isEndedConference && !presentation && device?.joinState == 1 {
            settleDevice()
            throw MeetDeviceSessionError.conferenceEnded
        }
    }

    func requestRegistration(_ body: Data) async throws -> HTTPResponse {
        do {
            return try await request("CreateMeetingDevice", body: body)
        } catch let MeetCallClientError.httpStatus(403, refusal) where refusal.isUnsupportedCaptureLock {
            registration = .refused
            throw MeetDeviceSessionError.captureLockUnsupported
        }
    }
}

private extension MeetDeviceSession {
    func refreshParticipantInvitations() async throws {
        let response = try await send(
            "MeetingSpaceService/SyncMeetingSpaceCollections",
            body: MeetProto.string(1, space.name) + MeetProto.bytes(12, Data()),
            timeout: .seconds(2)
        )
        let snapshot = try MeetCallCollectionsWire.snapshot(from: response.body, in: space.name)
        reconcileParticipantInvitations(snapshot.invitations)
    }

    func reconcileParticipantInvitations(_ invitations: MeetCallCollectionsWire.Invitations?) {
        guard let invitations, participantInvitationVersion.map({ invitations.version > $0 }) ?? true
        else { return }
        participantInvitationVersion = invitations.version
        guard !additionalInvites.isEmpty else { return }
        // Status 5 is answered and 7 is declined. Match each retained ID because
        // another invitee joining does not settle anyone else's invitation.
        let settled = Set(invitations.values.filter { [5, 7].contains($0.status) }.map(\.id))
        additionalInvites.removeAll { settled.contains($0) }
    }
}
